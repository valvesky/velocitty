//! Stage timings: IO → lines → runs → VT → draw fill → glyph LRU. `zig build bench`

const std = @import("std");
const CircBuffer = @import("circbuffer.zig").CircBuffer;
const Line = @import("circbuffer.zig").Line;
const VtState = @import("vt.zig").VtState;
const Draw = @import("draw.zig");
const Type = @import("type.zig");
const EastAsian = @import("type/eastasian.zig");

const ring_cap: usize = 64 * 1024;
const firehose_bytes: usize = 256 * 1024 * 1024;
const cols: u16 = 80;
const rows: u16 = 24;
const hz: u32 = 60;
const size_px: f32 = 16;
const parse_iters: u32 = 1000;
const refresh_iters: u32 = 60;
const micro_iters: u32 = 200;
const line_w: usize = 81; // 80 printable + '\n'

const font_paths = [_][]const u8{
    "/usr/share/fonts/iosevka-term/IosevkaTermNerdFontMono-Regular.ttf",
    "/usr/share/fonts/iosevka-term/IosevkaTermNerdFont-Regular.ttf",
    "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
};

var log_buf: std.Io.Writer.Allocating = undefined;

fn out(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
    log_buf.writer.print(fmt, args) catch {};
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    log_buf = .init(gpa);
    defer log_buf.deinit();

    const stamp = utcStamp(io);
    const git = try gitRev(gpa, io);
    defer gpa.free(git.hash);

    var buf = try CircBuffer.create(gpa, ring_cap);
    defer buf.destroy();

    var term = try VtState.init(gpa, cols, rows, 1000, buf.storage);
    defer term.deinit();

    const payload = try makePayload(gpa, ring_cap, cols);
    defer gpa.free(payload);

    ingest(&buf, payload);

    out("utc  {s}\n", .{stamp.iso});
    out("git  {s}{s}\n", .{ git.hash, if (git.dirty) " dirty" else "" });
    out(
        "velocitty pipeline bench  ring {d} KiB  screen {d}x{d}  mapped={s}  firehose {d} MiB\n",
        .{
            ring_cap / 1024,
            cols,
            rows,
            if (buf.mapped) "yes" else "heap",
            firehose_bytes / (1024 * 1024),
        },
    );
    out("  16.67 ms = {d} Hz budget\n\n", .{hz});

    try benchIo(&buf, payload);
    try benchParse(&buf, payload);
    try benchVt(&buf, &term, payload);
    try benchUnicode(gpa);

    const font_bytes = loadFont(gpa) catch null;
    defer if (font_bytes) |b| gpa.free(b);

    var type_ctx: ?Type.Context = null;
    defer if (type_ctx) |*ctx| ctx.deinit();
    var cell_w: u32 = 8;
    var cell_h: u32 = 16;
    if (font_bytes) |bytes| {
        var ctx = try Type.Context.init(gpa, .{});
        _ = try ctx.addFont(bytes, .{});
        if (ctx.metrics(size_px)) |m| {
            const h = m.ascender - m.descender + m.line_gap;
            cell_h = @max(1, @as(u32, @intFromFloat(@ceil(h))));
        } else |_| {}
        if (ctx.glyph('M', size_px)) |g| {
            cell_w = @max(1, @as(u32, @intFromFloat(@ceil(g.advance))));
        } else |_| {}
        ctx.stats = .{};
        type_ctx = ctx;
    } else {
        out("font  (none found; draw/glyph LRU skipped)\n\n", .{});
    }

    if (type_ctx) |*ctx| {
        var frame = try Draw.Frame.init(gpa, @as(u32, cols) * cell_w, @as(u32, rows) * cell_h);
        defer frame.deinit();
        fillAsciiScreen(&term);
        const px = frame.width * frame.height;
        out(
            "draw  cell {d}x{d}  fb {d}x{d} ({d} px, {d} KiB)  {d} cells\n",
            .{
                cell_w,
                cell_h,
                frame.width,
                frame.height,
                px,
                px * 4 / 1024,
                occupiedCells(&term),
            },
        );
        try benchDraw(&frame, &term, ctx, cell_w, cell_h);
        try benchGlyphs(ctx, &term);
        try benchRasterAtlas(gpa, ctx);
        try benchPresentCopy(&frame);
        try benchLarge(gpa, ctx, cell_w, cell_h);
    }

    saveLog(io, stamp.file, git.hash, git.dirty);
}

fn benchIo(buf: *CircBuffer, payload: []const u8) !void {
    out("IO  (circbuffer ingest, truncates to ring)\n", .{});
    var chunk: [ring_cap]u8 = undefined;
    fillLines(&chunk);

    var scratch = try CircBuffer.create(std.heap.page_allocator, ring_cap);
    defer scratch.destroy();

    var t0 = nowNs();
    var off: usize = 0;
    while (off < firehose_bytes) {
        ingest(&scratch, &chunk);
        off += chunk.len;
    }
    row("firehose into ring", nowNs() - t0, firehose_bytes);
    out("  retained {d} B  (cap {d}; truncated={s})\n", .{
        retainedBytes(&scratch),
        ring_cap,
        if (retainedBytes(&scratch) <= ring_cap) "yes" else "NO",
    });

    t0 = nowNs();
    var i: u32 = 0;
    while (i < parse_iters) : (i += 1) {
        ingest(&scratch, payload);
    }
    row("ring fill payload x1000", nowNs() - t0, @as(usize, parse_iters) * payload.len);
    out("\n", .{});

    // Restore the shared ring for later stages.
    rewindPending(buf);
    ingest(buf, payload);
}

fn benchParse(buf: *CircBuffer, payload: []const u8) !void {
    out("parse  ({d} iters on {d} B ring)\n", .{ parse_iters, payload.len });

    var line_ns: i128 = 0;
    var run_ns: i128 = 0;
    var last_run_bytes: usize = 0;
    var i: u32 = 0;
    while (i < parse_iters) : (i += 1) {
        rewindPending(buf);
        var t = nowNs();
        buf.consumeAndPreparse();
        line_ns += nowNs() - t;
        const lines = buf.getLastNLines(rows);
        t = nowNs();
        buf.splitIntoRuns(lines);
        run_ns += nowNs() - t;
        last_run_bytes = runBytes(buf);
        std.mem.doNotOptimizeAway(buf.runs.items.len);
    }
    // Line split always scans the pending ring; last-N only shrinks run split.
    row("lines last 24 (scan ring)", line_ns, ring_cap * parse_iters);
    row("runs last 24 (DESIGN)", run_ns, last_run_bytes * parse_iters);

    line_ns = 0;
    run_ns = 0;
    var all_line_bytes: usize = 0;
    var all_run_bytes: usize = 0;
    i = 0;
    while (i < parse_iters) : (i += 1) {
        rewindPending(buf);
        var t = nowNs();
        buf.consumeAndPreparse();
        line_ns += nowNs() - t;
        all_line_bytes = lineBytes(buf.lines.items);
        t = nowNs();
        buf.splitIntoRuns(buf.lines.items);
        run_ns += nowNs() - t;
        all_run_bytes = runBytes(buf);
        std.mem.doNotOptimizeAway(buf.runs.items.len);
    }
    row("lines all ring", line_ns, all_line_bytes * parse_iters);
    row("runs all ring", run_ns, all_run_bytes * parse_iters);

    var combined_ns: i128 = 0;
    i = 0;
    while (i < parse_iters) : (i += 1) {
        rewindPending(buf);
        const t = nowNs();
        _ = buf.consumeAndGetRuns(rows);
        combined_ns += nowNs() - t;
    }
    row("lines+runs last 24", combined_ns, last_run_bytes * parse_iters);

    combined_ns = 0;
    i = 0;
    while (i < parse_iters) : (i += 1) {
        rewindPending(buf);
        const t = nowNs();
        _ = buf.consumeAndGetRuns(std.math.maxInt(usize));
        combined_ns += nowNs() - t;
    }
    row("lines+runs all ring", combined_ns, all_run_bytes * parse_iters);
    out("\n", .{});
}

fn benchVt(buf: *CircBuffer, term: *VtState, payload: []const u8) !void {
    out("vt  (feedRuns / state update, {d} iters)\n", .{ parse_iters });

    rewindPending(buf);
    ingest(buf, payload);

    var last_bytes: usize = 0;
    var ns: i128 = 0;
    var i: u32 = 0;
    while (i < parse_iters) : (i += 1) {
        rewindPending(buf);
        const runs = buf.consumeAndGetRuns(rows);
        last_bytes = runBytes(buf);
        term.reset();
        const t = nowNs();
        if (runs.len != 0) term.feedRuns(runs);
        ns += nowNs() - t;
    }
    row("feedRuns last 24", ns, last_bytes * parse_iters);

    var all_bytes: usize = 0;
    ns = 0;
    i = 0;
    while (i < parse_iters) : (i += 1) {
        rewindPending(buf);
        const runs = buf.consumeAndGetRuns(std.math.maxInt(usize));
        all_bytes = runBytes(buf);
        term.reset();
        const t = nowNs();
        if (runs.len != 0) term.feedRuns(runs);
        ns += nowNs() - t;
    }
    row("feedRuns all ring", ns, all_bytes * parse_iters);

    ns = 0;
    i = 0;
    while (i < parse_iters) : (i += 1) {
        rewindPending(buf);
        term.reset();
        const t = nowNs();
        const runs = buf.consumeAndGetRuns(rows);
        if (runs.len != 0) term.feedRuns(runs);
        ns += nowNs() - t;
    }
    row("pipeline last 24", ns, last_bytes * parse_iters);

    ns = 0;
    i = 0;
    while (i < parse_iters) : (i += 1) {
        rewindPending(buf);
        term.reset();
        const t = nowNs();
        const runs = buf.consumeAndGetRuns(std.math.maxInt(usize));
        if (runs.len != 0) term.feedRuns(runs);
        ns += nowNs() - t;
    }
    row("pipeline all ring", ns, all_bytes * parse_iters);
    out("\n", .{});
}

fn benchUnicode(gpa: std.mem.Allocator) !void {
    out("unicode  (width tables / utf8 runs+term, {d} iters)\n", .{micro_iters});
    var acc: u64 = 0;
    var t = nowNs();
    var n: u32 = 0;
    while (n < micro_iters) : (n += 1) {
        var cp: u21 = 0;
        while (cp < 0x80) : (cp += 1) acc += EastAsian.cellWidth(cp);
    }
    row("cellWidth ASCII x200", nowNs() - t, @as(usize, micro_iters) * 0x80);

    t = nowNs();
    n = 0;
    while (n < micro_iters) : (n += 1) {
        var cp: u21 = 0;
        while (cp < 0x3000) : (cp += 1) acc += EastAsian.cellWidth(cp);
    }
    row("cellWidth 0..U+2FFF x200", nowNs() - t, @as(usize, micro_iters) * 0x3000);

    t = nowNs();
    n = 0;
    while (n < micro_iters) : (n += 1) {
        var cp: u21 = 0x4E00;
        while (cp < 0x4E00 + 4096) : (cp += 1) acc += EastAsian.cellWidth(cp);
    }
    row("cellWidth CJK U+4E00 x200", nowNs() - t, @as(usize, micro_iters) * 4096);
    std.mem.doNotOptimizeAway(acc);

    const cjk = try makeCjkPayload(gpa, ring_cap, cols);
    defer gpa.free(cjk);
    var cjk_buf = try CircBuffer.create(gpa, ring_cap);
    defer cjk_buf.destroy();
    var screen = try VtState.init(gpa, cols, rows, 1000, cjk_buf.storage);
    defer screen.deinit();
    ingest(&cjk_buf, cjk);

    var pre_ns: i128 = 0;
    var runs_ns: i128 = 0;
    var term_ns: i128 = 0;
    var bytes: usize = 0;
    var i: u32 = 0;
    while (i < refresh_iters) : (i += 1) {
        rewindPending(&cjk_buf);
        var tt = nowNs();
        cjk_buf.consumeAndPreparse();
        pre_ns += nowNs() - tt;
        tt = nowNs();
        cjk_buf.splitIntoRuns(cjk_buf.lines.items);
        runs_ns += nowNs() - tt;
        bytes = runBytes(&cjk_buf);
        screen.reset();
        tt = nowNs();
        if (cjk_buf.runs.items.len != 0) screen.feedRuns(cjk_buf.runs.items);
        term_ns += nowNs() - tt;
    }
    row("preparse CJK utf8", pre_ns, bytes * refresh_iters);
    row("runs.split CJK utf8", runs_ns, bytes * refresh_iters);
    row("term.feedRuns CJK", term_ns, bytes * refresh_iters);
    out("\n", .{});
}

fn benchDraw(frame: *Draw.Frame, term: *VtState, type_ctx: *Type.Context, cell_w: u32, cell_h: u32) !void {
    const fb_bytes = frame.pixels.len * @sizeOf(u32);

    type_ctx.clearAtlas();
    type_ctx.stats = .{};
    frame.invalidate();
    term.markDirtyAll();
    const t_cold = nowNs();
    frame.render(term, cell_w, cell_h, type_ctx, size_px);
    const cold_ns = nowNs() - t_cold;
    const cold_stats = type_ctx.stats;
    row("render COLD", cold_ns, fb_bytes);
    out(
        "    fill {d:.3} ms   glyphs {d:.3} ms   raster {d:.3} ms   atlas {d:.3} ms   miss {d} hit {d}\n",
        .{
            nsMs(frame.last_fill_ns),
            nsMs(frame.last_glyph_ns),
            nsMs(cold_stats.raster_ns),
            nsMs(cold_stats.atlas_ns),
            cold_stats.misses,
            cold_stats.hits,
        },
    );

    type_ctx.stats = .{};
    var fill_ns: u64 = 0;
    var glyph_ns: u64 = 0;
    term.clearDirty();
    const t_hot = nowNs();
    var i: u32 = 0;
    while (i < refresh_iters) : (i += 1) {
        frame.render(term, cell_w, cell_h, type_ctx, size_px);
        fill_ns += frame.last_fill_ns;
        glyph_ns += frame.last_glyph_ns;
    }
    row("render HOT skip x60", nowNs() - t_hot, fb_bytes * refresh_iters);
    out(
        "    fill {d:.3} ms ({d:.3} ms/f)   glyphs {d:.3} ms ({d:.3} ms/f)   raster {d:.3} ms   atlas {d:.3} ms   miss {d} hit {d}\n",
        .{
            nsMs(fill_ns),
            nsMs(fill_ns) / @as(f64, refresh_iters),
            nsMs(glyph_ns),
            nsMs(glyph_ns) / @as(f64, refresh_iters),
            nsMs(type_ctx.stats.raster_ns),
            nsMs(type_ctx.stats.atlas_ns),
            type_ctx.stats.misses,
            type_ctx.stats.hits,
        },
    );

    fill_ns = 0;
    glyph_ns = 0;
    i = 0;
    const t_full = nowNs();
    while (i < refresh_iters) : (i += 1) {
        frame.invalidate();
        term.markDirtyAll();
        frame.render(term, cell_w, cell_h, type_ctx, size_px);
        fill_ns += frame.last_fill_ns;
        glyph_ns += frame.last_glyph_ns;
    }
    rowFrame("draw.render FULL x60", nowNs() - t_full, refresh_iters, fb_bytes);
    out(
        "    fillRect {d:.3} ms ({d:.3} ms/f)   blit+lookup {d:.3} ms ({d:.3} ms/f)\n",
        .{
            nsMs(fill_ns),
            nsMs(fill_ns) / @as(f64, refresh_iters),
            nsMs(glyph_ns),
            nsMs(glyph_ns) / @as(f64, refresh_iters),
        },
    );

    frame.render(term, cell_w, cell_h, type_ctx, size_px);
    term.clearDirty();
    fill_ns = 0;
    glyph_ns = 0;
    i = 0;
    const t_skip = nowNs();
    while (i < refresh_iters) : (i += 1) {
        frame.render(term, cell_w, cell_h, type_ctx, size_px);
        fill_ns += frame.last_fill_ns;
        glyph_ns += frame.last_glyph_ns;
    }
    rowFrame("draw.render skip x60", nowNs() - t_skip, refresh_iters, fb_bytes);
    out(
        "    fillRect {d:.3} ms ({d:.3} ms/f)   blit+lookup {d:.3} ms ({d:.3} ms/f)\n",
        .{
            nsMs(fill_ns),
            nsMs(fill_ns) / @as(f64, refresh_iters),
            nsMs(glyph_ns),
            nsMs(glyph_ns) / @as(f64, refresh_iters),
        },
    );

    const t_memset = nowNs();
    i = 0;
    while (i < refresh_iters) : (i += 1) {
        @memset(frame.pixels, 0);
    }
    rowFrame("fb memset x60", nowNs() - t_memset, refresh_iters, fb_bytes);
    out("\n", .{});
}

fn benchGlyphs(type_ctx: *Type.Context, term: *VtState) !void {
    out("glyphs / LRU  (hot screen {d} cells)\n", .{@as(u32, cols) * rows});

    type_ctx.stats = .{};
    const t_lookup = nowNs();
    var r: u16 = 0;
    var lookups: usize = 0;
    var cover_bytes: usize = 0;
    while (r < term.rows) : (r += 1) {
        var c: u16 = 0;
        while (c < term.cols) : (c += 1) {
            const cp = term.cell(r, c).codepoint;
            if (cp == ' ' or cp == 0) continue;
            const g = type_ctx.glyph(cp, size_px) catch continue;
            lookups += 1;
            cover_bytes += @as(usize, g.width) * g.height;
        }
    }
    row("type.glyph HOT lookups", nowNs() - t_lookup, cover_bytes);
    out("    hits {d} misses {d}  lookups {d}\n", .{
        type_ctx.stats.hits,
        type_ctx.stats.misses,
        lookups,
    });
    if (lookups == 0) out("    INVALID empty screen\n", .{});
    out("\n", .{});
}

fn benchRasterAtlas(gpa: std.mem.Allocator, type_ctx: *Type.Context) !void {
    out("rasterize / atlas / LRU  (isolated)\n", .{});
    const face = type_ctx.faces.items[0];
    const font = face.font;

    type_ctx.clearAtlas();
    type_ctx.ascii_size = 0;
    type_ctx.ascii = @splat(null);
    type_ctx.replacement = null;
    type_ctx.stats = .{};
    var cover: usize = 0;
    const t_miss = nowNs();
    var cp: u21 = 32;
    while (cp < 127) : (cp += 1) {
        const g = try type_ctx.glyph(cp, size_px);
        cover += @as(usize, g.width) * g.height;
    }
    row("glyph() COLD 95 ascii", nowNs() - t_miss, cover);
    out(
        "    raster {d:.3} ms   atlas+metrics {d:.3} ms   miss {d} hit {d}\n",
        .{
            nsMs(type_ctx.stats.raster_ns),
            nsMs(type_ctx.stats.atlas_ns),
            type_ctx.stats.misses,
            type_ctx.stats.hits,
        },
    );

    type_ctx.stats = .{};
    cover = 0;
    const t_hit = nowNs();
    var n: u32 = 0;
    while (n < micro_iters) : (n += 1) {
        cp = 32;
        while (cp < 127) : (cp += 1) {
            const g = try type_ctx.glyph(cp, size_px);
            cover += @as(usize, g.width) * g.height;
        }
    }
    row("glyph() HOT 95 ascii x200", nowNs() - t_hit, cover);
    out("    hits {d} misses {d}  (ascii table, not LRU)\n", .{
        type_ctx.stats.hits,
        type_ctx.stats.misses,
    });

    // Non-ASCII goes through the LRU. U+00A9 COPYRIGHT SIGN is in most Latin fonts.
    type_ctx.clearAtlas();
    type_ctx.stats = .{};
    const lru_cps = [_]u21{ 0x00A9, 0x00AE, 0x00B0, 0x00B1, 0x00D7, 0x00F7, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x20AC, 0x2190, 0x2191, 0x2192 };
    cover = 0;
    const t_lru_miss = nowNs();
    for (lru_cps) |c| {
        const g = type_ctx.glyph(c, size_px) catch continue;
        cover += @as(usize, g.width) * g.height;
    }
    row("glyph() COLD LRU latin-1", nowNs() - t_lru_miss, cover);
    out(
        "    raster {d:.3} ms   atlas {d:.3} ms   miss {d} hit {d}\n",
        .{
            nsMs(type_ctx.stats.raster_ns),
            nsMs(type_ctx.stats.atlas_ns),
            type_ctx.stats.misses,
            type_ctx.stats.hits,
        },
    );

    type_ctx.stats = .{};
    cover = 0;
    const t_lru_hit = nowNs();
    n = 0;
    while (n < micro_iters) : (n += 1) {
        for (lru_cps) |c| {
            const g = type_ctx.glyph(c, size_px) catch continue;
            cover += @as(usize, g.width) * g.height;
        }
    }
    row("glyph() HOT LRU x200", nowNs() - t_lru_hit, cover);
    out("    hits {d} misses {d}\n", .{ type_ctx.stats.hits, type_ctx.stats.misses });

    type_ctx.stats = .{};
    cover = 0;
    const t_peek = nowNs();
    n = 0;
    while (n < micro_iters) : (n += 1) {
        for (lru_cps) |c| {
            if (type_ctx.peekGlyph(c, size_px)) |g| {
                cover += @as(usize, g.width) * g.height;
            }
        }
    }
    row("peekGlyph HOT LRU x200", nowNs() - t_peek, cover);

    const gid = (try font.glyphIndex('A')) orelse 0;
    var ras_bytes: usize = 0;
    const t_ras = nowNs();
    n = 0;
    while (n < micro_iters) : (n += 1) {
        const bmp = try font.rasterize(gpa, gid, size_px);
        ras_bytes += bmp.pixels.len;
        gpa.free(bmp.pixels);
    }
    row("truetype.rasterize A x200", nowNs() - t_ras, ras_bytes);

    const bmp = try font.rasterize(gpa, gid, size_px);
    defer gpa.free(bmp.pixels);
    var atlas = try Type.Atlas.init(gpa, 1024, 1024);
    defer atlas.deinit();
    var packed_n: u32 = 0;
    var packed_bytes: usize = 0;
    const t_at = nowNs();
    n = 0;
    while (n < micro_iters) : (n += 1) {
        const rect = atlas.pack(bmp.width, bmp.height) orelse blk: {
            atlas.clear();
            break :blk atlas.pack(bmp.width, bmp.height) orelse continue;
        };
        atlas.blit(rect, bmp.pixels);
        packed_n += 1;
        packed_bytes += bmp.pixels.len;
    }
    row("atlas.pack+blit x200", nowNs() - t_at, packed_bytes);
    out("    packed {d}\n\n", .{packed_n});
}

fn benchPresentCopy(frame: *Draw.Frame) !void {
    out("present-shaped memcpy  (no X11)\n", .{});
    const bytes = frame.pixels.len * @sizeOf(u32);
    const tmp = try frame.allocator.alloc(u32, frame.pixels.len);
    defer frame.allocator.free(tmp);
    var i: u32 = 0;
    const t0 = nowNs();
    while (i < refresh_iters) : (i += 1) {
        @memcpy(tmp, frame.pixels);
    }
    rowFrame("fb memcpy x60", nowNs() - t0, refresh_iters, bytes);
    out("    fb {d} B\n\n", .{bytes});
}

fn benchLarge(gpa: std.mem.Allocator, type_ctx: *Type.Context, cell_w: u32, cell_h: u32) !void {
    const sizes = [_][2]u16{
        .{ 220, 60 },
        .{ @intCast(@max(1, 3840 / cell_w)), @intCast(@max(1, 2160 / cell_h)) },
    };

    for (sizes) |wh| {
        const scols = wh[0];
        const srows = wh[1];
        var dummy: [1]u8 = .{0};
        var term = try VtState.init(gpa, scols, srows, srows, dummy[0..]);
        defer term.deinit();
        fillAsciiScreen(&term);

        var frame = try Draw.Frame.init(gpa, @as(u32, scols) * cell_w, @as(u32, srows) * cell_h);
        defer frame.deinit();
        const fb_bytes = frame.pixels.len * @sizeOf(u32);
        const px = frame.width * frame.height;
        out(
            "large  {d}x{d}  fb {d}x{d} ({d} px, {d} KiB)\n",
            .{ scols, srows, frame.width, frame.height, px, fb_bytes / 1024 },
        );

        type_ctx.stats = .{};
        var fill_ns: u64 = 0;
        var glyph_ns: u64 = 0;
        var i: u32 = 0;
        const t_serial = nowNs();
        while (i < refresh_iters) : (i += 1) {
            frame.invalidate();
            term.markDirtyAll();
            frame.render(&term, cell_w, cell_h, type_ctx, size_px);
            fill_ns += frame.last_fill_ns;
            glyph_ns += frame.last_glyph_ns;
        }
        rowFrame("draw.render FULL x60", nowNs() - t_serial, refresh_iters, fb_bytes);
        out(
            "    fillRect {d:.3} ms ({d:.3} ms/f)   blit+lookup {d:.3} ms ({d:.3} ms/f)\n",
            .{
                nsMs(fill_ns),
                nsMs(fill_ns) / @as(f64, refresh_iters),
                nsMs(glyph_ns),
                nsMs(glyph_ns) / @as(f64, refresh_iters),
            },
        );
        out("\n", .{});
    }
}

fn fillAsciiScreen(term: *VtState) void {
    term.reset();
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789  ";
    var ch: usize = 0;
    var n: u32 = 0;
    const total: u32 = @as(u32, term.cols) * term.rows;
    while (n < total) : (n += 1) {
        term.printCodepoint(alphabet[ch % alphabet.len]);
        ch += 1;
    }
}

fn occupiedCells(term: *const VtState) u32 {
    var n: u32 = 0;
    var r: u16 = 0;
    while (r < term.rows) : (r += 1) {
        var c: u16 = 0;
        while (c < term.cols) : (c += 1) {
            const cp = term.cell(r, c).codepoint;
            if (cp != 0 and cp != ' ') n += 1;
        }
    }
    return n;
}

fn makePayload(gpa: std.mem.Allocator, nbytes: usize, width: u16) ![]u8 {
    const buf = try gpa.alloc(u8, nbytes);
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789  ";
    var i: usize = 0;
    var col: u16 = 0;
    var ch: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (col + 1 == width) {
            buf[i] = '\n';
            col = 0;
        } else {
            buf[i] = alphabet[ch % alphabet.len];
            ch += 1;
            col += 1;
        }
    }
    return buf;
}

fn makeCjkPayload(gpa: std.mem.Allocator, nbytes: usize, width: u16) ![]u8 {
    const buf = try gpa.alloc(u8, nbytes);
    const han = "汉字测试あア한";
    var i: usize = 0;
    var col: u16 = 0;
    var ch: usize = 0;
    while (i + 4 < buf.len) {
        if (col + 2 > width) {
            buf[i] = '\n';
            i += 1;
            col = 0;
            continue;
        }
        const cp_i = ch % (han.len / 3);
        const slice = han[cp_i * 3 ..][0..3];
        @memcpy(buf[i..][0..3], slice);
        i += 3;
        ch += 1;
        col += 2;
    }
    while (i < buf.len) : (i += 1) buf[i] = '\n';
    return buf;
}

fn loadFont(gpa: std.mem.Allocator) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    for (font_paths) |path| {
        if (loadFontPath(io, gpa, path)) |bytes| return bytes else |_| {}
    }
    return error.InvalidFont;
}

fn loadFontPath(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const n = try file.length(io);
    const bytes = try gpa.alloc(u8, n);
    errdefer gpa.free(bytes);
    const got = try file.readPositionalAll(io, bytes, 0);
    if (got != n) return error.InvalidFont;
    return bytes;
}

fn fillLines(dest: []u8) void {
    var i: usize = 0;
    while (i < dest.len) {
        const n = @min(line_w, dest.len - i);
        @memset(dest[i .. i + n], 'x');
        dest[i + n - 1] = '\n';
        i += n;
    }
}

fn ingest(buf: *CircBuffer, src: []const u8) void {
    const cap = buf.capacity;
    const mask = cap - 1;
    var rest = src;
    while (rest.len != 0) {
        const off: usize = @intCast(buf.head & mask);
        const dest = buf.storage[off..][0..cap];
        const n = @min(dest.len, rest.len);
        @memcpy(dest[0..n], rest[0..n]);
        if (!buf.mapped and n != 0) {
            const a = buf.storage;
            const first = @min(n, cap - off);
            if (first != 0) @memcpy(a[off + cap ..][0..first], a[off..][0..first]);
            const extra = n - first;
            if (extra != 0) @memcpy(a[0..extra], a[cap..][0..extra]);
        }
        buf.head += n;
        rest = rest[n..];
    }
}

fn rewindPending(buf: *CircBuffer) void {
    buf.tail = if (buf.head > buf.capacity) buf.head - buf.capacity else 0;
    buf.hold_at_head = 0;
}

fn retainedBytes(buf: *const CircBuffer) u64 {
    const live = buf.head - buf.tail;
    return if (live > buf.capacity) buf.capacity else live;
}

fn lineBytes(lines: []const Line) usize {
    var n: usize = 0;
    for (lines) |l| n += l.len;
    return n;
}

fn runBytes(buf: *const CircBuffer) usize {
    var n: usize = 0;
    for (buf.runs.items) |r| n += r.len;
    return n;
}

fn nowNs() i128 {
    return @intCast(std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds);
}

fn nsMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn row(name: []const u8, elapsed_ns: i128, bytes: usize) void {
    const ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const mib_s = if (sec > 0) @as(f64, @floatFromInt(bytes)) / sec / (1024.0 * 1024.0) else 0;
    out("  {s:<28} {d:10.3} ms  {d:10.1} MiB/s\n", .{ name, ms, mib_s });
}

fn rowFrame(name: []const u8, elapsed_ns: i128, frames: u32, fb_bytes: usize) void {
    const ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const total = fb_bytes * frames;
    const mib_s = if (sec > 0) @as(f64, @floatFromInt(total)) / sec / (1024.0 * 1024.0) else 0;
    const per = if (frames == 0) 0 else ms / @as(f64, @floatFromInt(frames));
    out(
        "  {s:<28} {d:10.3} ms  {d:10.1} MiB/s  {d:7.3} ms/f  {d:5.1} Hz  {d:5.1}% of 16.7ms\n",
        .{
            name,
            ms,
            mib_s,
            per,
            if (per > 0) 1000.0 / per else 0,
            per / 16.666666 * 100.0,
        },
    );
}

const Stamp = struct {
    iso: [20]u8,
    file: [16]u8,
};

fn utcStamp(io: std.Io) Stamp {
    const ts = std.Io.Timestamp.now(io, .real);
    const secs: u64 = if (ts.nanoseconds <= 0) 0 else @intCast(@divTrunc(ts.nanoseconds, 1_000_000_000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    var iso: [20]u8 = undefined;
    var file: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&iso, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        @as(u8, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
    _ = std.fmt.bufPrint(&file, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        @as(u8, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
    return .{ .iso = iso, .file = file };
}

const Git = struct { hash: []u8, dirty: bool };

fn gitUnknown(gpa: std.mem.Allocator) !Git {
    return .{ .hash = try gpa.dupe(u8, "unknown"), .dirty = false };
}

fn gitRev(gpa: std.mem.Allocator, io: std.Io) !Git {
    const hash_res = std.process.run(gpa, io, .{
        .argv = &.{ "git", "rev-parse", "--short=12", "HEAD" },
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(256),
    }) catch return gitUnknown(gpa);
    defer gpa.free(hash_res.stdout);
    defer gpa.free(hash_res.stderr);
    switch (hash_res.term) {
        .exited => |code| if (code != 0) return gitUnknown(gpa),
        else => return gitUnknown(gpa),
    }
    const trimmed = std.mem.trim(u8, hash_res.stdout, " \t\r\n");
    if (trimmed.len == 0) return gitUnknown(gpa);
    const hash = try gpa.dupe(u8, trimmed);

    const st = std.process.run(gpa, io, .{
        .argv = &.{ "git", "status", "--porcelain" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(256),
    }) catch return .{ .hash = hash, .dirty = false };
    defer gpa.free(st.stdout);
    defer gpa.free(st.stderr);
    const dirty = switch (st.term) {
        .exited => |code| code == 0 and std.mem.trim(u8, st.stdout, " \t\r\n").len != 0,
        else => false,
    };
    return .{ .hash = hash, .dirty = dirty };
}

fn saveLog(io: std.Io, file_stamp: [16]u8, hash: []const u8, dirty: bool) void {
    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "bench") catch {
        std.debug.print("bench: could not create bench/\n", .{});
        return;
    };
    var name_buf: [128]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "bench/{s}-{s}{s}.txt", .{
        file_stamp,
        hash,
        if (dirty) "-dirty" else "",
    }) catch return;
    const data = log_buf.writer.buffered();
    dir.writeFile(io, .{ .sub_path = name, .data = data }) catch {
        std.debug.print("bench: could not write {s}\n", .{name});
        return;
    };
    dir.writeFile(io, .{ .sub_path = "last_bench", .data = data }) catch {};
    std.debug.print("saved {s}\n", .{name});
}
