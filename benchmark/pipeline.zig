//! Stage timings: IO → lines → runs → term → draw fill → glyphs / atlas.

const std = @import("std");
const zt = @import("ZT");

const firehose_bytes: usize = 1 << 30;
const ring_cap: usize = 1 << 12;
const cols: u16 = 80;
const rows: u16 = 24;
const hz: u32 = 60;
const size_px: f32 = 16;
const refresh_iters: u32 = 60;
const micro_iters: u32 = 200;

const font_paths = [_][]const u8{
    "/usr/share/fonts/iosevka-term/IosevkaTermNerdFontMono-Regular.ttf",
    "/usr/share/fonts/iosevka-term/IosevkaTermNerdFont-Regular.ttf",
    "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const font_bytes = try loadFont(io, gpa);
    defer gpa.free(font_bytes);

    var type_ctx = try zt.Type.Context.init(gpa, .{});
    defer type_ctx.deinit();
    _ = try type_ctx.addFont(font_bytes, .{});

    var cell_w: u32 = 8;
    var cell_h: u32 = 16;
    if (type_ctx.metrics(size_px)) |m| {
        const h = m.ascender - m.descender + m.line_gap;
        cell_h = @max(1, @as(u32, @intFromFloat(@ceil(h))));
    } else |_| {}
    if (type_ctx.glyph('M', size_px)) |g| {
        cell_w = @max(1, @as(u32, @intFromFloat(@ceil(g.advance))));
    } else |_| {}
    type_ctx.stats = .{};

    const payload = try makePayload(gpa, ring_cap, cols);
    defer gpa.free(payload);

    var engine = try zt.Engine.init(gpa, .{
        .cols = cols,
        .rows = rows,
        .buf_cap = ring_cap,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .size_px = size_px,
        .hz = hz,
    });
    defer engine.deinit();
    engine.type_ctx = &type_ctx;
    engine.ingest(payload);
    try engine.refresh();

    const px = engine.frame.width * engine.frame.height;
    std.debug.print(
        "ZT pipeline bench  screen {d}x{d}  cell {d}x{d}  fb {d}x{d} ({d} px)  payload {d} B  {d} cells\n",
        .{
            cols,
            rows,
            cell_w,
            cell_h,
            engine.frame.width,
            engine.frame.height,
            px,
            payload.len,
            occupiedCells(&engine.screen),
        },
    );
    std.debug.print("  16.67 ms = 60 Hz budget\n\n", .{});

    try benchIo(gpa);
    try benchStages(gpa, &engine, payload);
    try benchUnicode(gpa);
    try benchRefresh(&engine, &type_ctx, payload);
    try benchGlyphs(gpa, &type_ctx, &engine);
    try benchRasterAtlas(gpa, &type_ctx);
    try benchPresentCopy(&engine);
    try benchLarge(gpa, &type_ctx, cell_w, cell_h);
}

fn benchIo(gpa: std.mem.Allocator) !void {
    std.debug.print("IO  (circbuffer spare+commit, truncates to 4 KiB)\n", .{});
    var buf = try zt.CircBuffer.init(gpa, ring_cap);
    defer buf.deinit();
    const mapped: []const u8 = if (buf.mapped) "mmap" else "heap";
    std.debug.print("  ring {s}\n", .{mapped});
    const t0 = nowNs();
    var off: usize = 0;
    while (off < firehose_bytes) {
        const dest = buf.spare();
        @memset(dest, 'x');
        buf.commit(dest.len);
        off += dest.len;
    }
    const firehose_ns = nowNs() - t0;
    row("firehose 1 GiB / spare", firehose_ns, firehose_bytes, "B");

    buf.clear();
    var chunk: [4096]u8 = @splat('x');
    const t1 = nowNs();
    var i: u32 = 0;
    while (i < micro_iters) : (i += 1) {
        var k: u32 = 0;
        while (k < 4) : (k += 1) {
            const dest = buf.spare();
            @memcpy(dest[0..chunk.len], &chunk);
            buf.commit(chunk.len);
        }
    }
    const small_ns = nowNs() - t1;
    const small_bytes: usize = @as(usize, micro_iters) * 4 * chunk.len;
    row("ring 4x4 KiB x200", small_ns, small_bytes, "B");
    std.debug.print("\n", .{});
}

fn benchStages(gpa: std.mem.Allocator, engine: *zt.Engine, payload: []const u8) !void {
    std.debug.print("parse / emulate  ({d} refresh-shaped iters on {d} B ring)\n", .{ refresh_iters, payload.len });
    var pre_ns: i128 = 0;
    var runs_ns: i128 = 0;
    var term_ns: i128 = 0;
    var i: u32 = 0;
    while (i < refresh_iters) : (i += 1) {
        engine.rewindInput();
        engine.buffer.write(payload);
        engine.screen.clear();
        var t = nowNs();
        _ = zt.Preparse.consume(&engine.buffer, engine.whitelist);
        pre_ns += nowNs() - t;
        const peek = engine.buffer.peek();
        const view = engine.buffer.lastLines(engine.screen.cap);
        var li: u32 = 0;
        while (li < view.n) : (li += 1) {
            const line = view.get(li);
            const off: usize = @intCast(line.off - engine.buffer.rd);
            const slice = peek[off .. off + line.len];
            engine.runs.clearRetainingCapacity();
            t = nowNs();
            try zt.Runs.split(gpa, slice, &engine.runs);
            runs_ns += nowNs() - t;
            t = nowNs();
            engine.screen.feed(engine.runs.items, slice);
            if (li + 1 < view.n) engine.screen.lineFeed();
            term_ns += nowNs() - t;
        }
    }
    row("runs.splitAvailable", runs_ns, @as(usize, refresh_iters) * payload.len, "B");
    row("preparse.consume lines", pre_ns, @as(usize, refresh_iters) * payload.len, "B");
    row("term.feedPlain", term_ns, @as(usize, refresh_iters), "frames");

    const dense = try gpa.alloc(u8, ring_cap);
    defer gpa.free(dense);
    @memset(dense, 'x');
    var dense_lines: std.ArrayList(zt.Preparse.Line) = .empty;
    defer dense_lines.deinit(gpa);
    var dense_ns: i128 = 0;
    var d: u32 = 0;
    while (d < refresh_iters) : (d += 1) {
        dense_lines.clearRetainingCapacity();
        const t = nowNs();
        _ = try zt.Preparse.scan(gpa, dense, cols, &dense_lines);
        dense_ns += nowNs() - t;
    }
    row("preparse dense ASCII", dense_ns, @as(usize, refresh_iters) * dense.len, "B");
    std.debug.print("\n", .{});
}

fn benchUnicode(gpa: std.mem.Allocator) !void {
    std.debug.print("unicode  (width tables / utf8 runs+term, {d} iters)\n", .{refresh_iters});
    const EastAsian = zt.Type.EastAsian;

    var acc: u64 = 0;
    var t = nowNs();
    var n: u32 = 0;
    while (n < micro_iters) : (n += 1) {
        var cp: u21 = 0;
        while (cp < 0x80) : (cp += 1) acc += EastAsian.cellWidth(cp);
    }
    row("cellWidth ASCII x200", nowNs() - t, @as(usize, micro_iters) * 0x80, "glyphs");

    t = nowNs();
    n = 0;
    while (n < micro_iters) : (n += 1) {
        var cp: u21 = 0;
        while (cp < 0x3000) : (cp += 1) acc += EastAsian.cellWidth(cp);
    }
    row("cellWidth 0..U+2FFF x200", nowNs() - t, @as(usize, micro_iters) * 0x3000, "glyphs");

    t = nowNs();
    n = 0;
    while (n < micro_iters) : (n += 1) {
        var cp: u21 = 0x4E00;
        while (cp < 0x4E00 + 4096) : (cp += 1) acc += EastAsian.cellWidth(cp);
    }
    row("cellWidth CJK U+4E00 x200", nowNs() - t, @as(usize, micro_iters) * 4096, "glyphs");

    t = nowNs();
    n = 0;
    while (n < micro_iters) : (n += 1) {
        var cp: u21 = 0x1F300;
        while (cp < 0x1F600) : (cp += 1) acc += EastAsian.cellWidth(cp);
    }
    row("cellWidth emoji U+1F300 x200", nowNs() - t, @as(usize, micro_iters) * 0x300, "glyphs");
    std.mem.doNotOptimizeAway(acc);

    const cjk = try makeCjkPayload(gpa, ring_cap, cols);
    defer gpa.free(cjk);
    var runs_ns: i128 = 0;
    var term_ns: i128 = 0;
    var pre_ns: i128 = 0;
    var screen = try zt.Term.Screen.init(gpa, cols, rows);
    defer screen.deinit();
    var runs: std.ArrayList(zt.Runs.Run) = .empty;
    defer runs.deinit(gpa);
    var lines: std.ArrayList(zt.Preparse.Line) = .empty;
    defer lines.deinit(gpa);
    var i: u32 = 0;
    while (i < refresh_iters) : (i += 1) {
        lines.clearRetainingCapacity();
        t = nowNs();
        _ = try zt.Preparse.scan(gpa, cjk, cols, &lines);
        pre_ns += nowNs() - t;
    }
    i = 0;
    while (i < refresh_iters) : (i += 1) {
        runs.clearRetainingCapacity();
        t = nowNs();
        try zt.Runs.split(gpa, cjk, &runs);
        runs_ns += nowNs() - t;
        screen.clear();
        t = nowNs();
        screen.feed(runs.items, cjk);
        term_ns += nowNs() - t;
    }
    row("preparse CJK utf8", pre_ns, @as(usize, refresh_iters) * cjk.len, "B");
    row("runs.split CJK utf8", runs_ns, @as(usize, refresh_iters) * cjk.len, "B");
    row("term.feedUtf8 CJK", term_ns, @as(usize, refresh_iters) * cjk.len, "B");
    std.debug.print("\n", .{});
}

fn benchRefresh(engine: *zt.Engine, type_ctx: *zt.Type.Context, payload: []const u8) !void {
    std.debug.print("engine.refresh  (incremental consume + draw)\n", .{});
    type_ctx.clearAtlas();
    type_ctx.stats = .{};
    engine.rewindInput();
    engine.buffer.write(payload);
    engine.screen.clear();
    engine.frame.invalidate();
    const t_cold = nowNs();
    try engine.refresh();
    const cold_ns = nowNs() - t_cold;
    const cold_stats = type_ctx.stats;
    row("refresh COLD", cold_ns, 1, "frame");
    std.debug.print(
        "    fill {d:.3} ms   glyphs {d:.3} ms   raster {d:.3} ms   atlas {d:.3} ms   miss {d} hit {d}\n",
        .{
            nsMs(engine.frame.last_fill_ns),
            nsMs(engine.frame.last_glyph_ns),
            nsMs(cold_stats.raster_ns),
            nsMs(cold_stats.atlas_ns),
            cold_stats.misses,
            cold_stats.hits,
        },
    );

    type_ctx.stats = .{};
    var fill_ns: u64 = 0;
    var glyph_ns: u64 = 0;
    const t_hot = nowNs();
    var i: u32 = 0;
    while (i < refresh_iters) : (i += 1) {
        try engine.refresh();
        fill_ns += engine.frame.last_fill_ns;
        glyph_ns += engine.frame.last_glyph_ns;
    }
    const hot_ns = nowNs() - t_hot;
    const hot_stats = type_ctx.stats;
    row("refresh HOT skip x60", hot_ns, refresh_iters, "frames");
    std.debug.print(
        "    fill {d:.3} ms ({d:.3} ms/f)   glyphs {d:.3} ms ({d:.3} ms/f)   raster {d:.3} ms   atlas {d:.3} ms   miss {d} hit {d}\n",
        .{
            nsMs(fill_ns),
            nsMs(fill_ns) / @as(f64, refresh_iters),
            nsMs(glyph_ns),
            nsMs(glyph_ns) / @as(f64, refresh_iters),
            nsMs(hot_stats.raster_ns),
            nsMs(hot_stats.atlas_ns),
            hot_stats.misses,
            hot_stats.hits,
        },
    );
    std.debug.print("\n", .{});
}

fn benchGlyphs(gpa: std.mem.Allocator, type_ctx: *zt.Type.Context, engine: *zt.Engine) !void {
    _ = gpa;
    std.debug.print("draw / glyphs  (hot screen {d} cells)\n", .{@as(u32, cols) * rows});
    type_ctx.stats = .{};
    const t_lookup = nowNs();
    var r: u16 = 0;
    var lookups: usize = 0;
    while (r < engine.screen.rows) : (r += 1) {
        var c: u16 = 0;
        while (c < engine.screen.cols) : (c += 1) {
            const cp = engine.screen.cell(r, c).codepoint;
            if (cp == ' ' or cp == 0) continue;
            _ = type_ctx.glyph(cp, size_px) catch continue;
            lookups += 1;
        }
    }
    const lookup_ns = nowNs() - t_lookup;
    row("type.glyph HOT lookups", lookup_ns, lookups, "glyphs");
    std.debug.print("    hits {d} misses {d}\n", .{ type_ctx.stats.hits, type_ctx.stats.misses });
    if (lookups == 0) std.debug.print("    INVALID empty screen\n", .{});

    var i: u32 = 0;
    var fill_ns: u64 = 0;
    var glyph_ns: u64 = 0;
    const t_draw = nowNs();
    while (i < refresh_iters) : (i += 1) {
        engine.frame.invalidate();
        engine.frame.render(&engine.screen, engine.cell_w, engine.cell_h, type_ctx, size_px);
        fill_ns += engine.frame.last_fill_ns;
        glyph_ns += engine.frame.last_glyph_ns;
    }
    const draw_ns = nowNs() - t_draw;
    row("draw.render FULL x60", draw_ns, refresh_iters, "frames");
    std.debug.print(
        "    fillRect {d:.3} ms ({d:.3} ms/f)   blit+lookup {d:.3} ms ({d:.3} ms/f)\n",
        .{
            nsMs(fill_ns),
            nsMs(fill_ns) / @as(f64, refresh_iters),
            nsMs(glyph_ns),
            nsMs(glyph_ns) / @as(f64, refresh_iters),
        },
    );

    engine.frame.render(&engine.screen, engine.cell_w, engine.cell_h, type_ctx, size_px);
    fill_ns = 0;
    glyph_ns = 0;
    i = 0;
    const t_skip = nowNs();
    while (i < refresh_iters) : (i += 1) {
        engine.frame.render(&engine.screen, engine.cell_w, engine.cell_h, type_ctx, size_px);
        fill_ns += engine.frame.last_fill_ns;
        glyph_ns += engine.frame.last_glyph_ns;
    }
    row("draw.render skip x60", nowNs() - t_skip, refresh_iters, "frames");
    std.debug.print(
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
        @memset(engine.frame.pixels, 0);
    }
    row("fb memset x60", nowNs() - t_memset, refresh_iters, "frames");
    std.debug.print("\n", .{});
}

fn benchRasterAtlas(gpa: std.mem.Allocator, type_ctx: *zt.Type.Context) !void {
    std.debug.print("rasterize / atlas  (printable ASCII, isolated)\n", .{});
    const face = type_ctx.faces.items[0];
    const font = face.font;

    type_ctx.clearAtlas();
    type_ctx.stats = .{};
    const t_miss = nowNs();
    var cp: u21 = 32;
    while (cp < 127) : (cp += 1) {
        _ = try type_ctx.glyph(cp, size_px);
    }
    const miss_ns = nowNs() - t_miss;
    row("glyph() COLD 95 ascii", miss_ns, 95, "glyphs");
    std.debug.print(
        "    raster {d:.3} ms   atlas+metrics {d:.3} ms   miss {d}\n",
        .{ nsMs(type_ctx.stats.raster_ns), nsMs(type_ctx.stats.atlas_ns), type_ctx.stats.misses },
    );

    type_ctx.stats = .{};
    const t_hit = nowNs();
    var n: u32 = 0;
    while (n < micro_iters) : (n += 1) {
        cp = 32;
        while (cp < 127) : (cp += 1) {
            _ = try type_ctx.glyph(cp, size_px);
        }
    }
    const hit_ns = nowNs() - t_hit;
    row("glyph() HOT 95 x200", hit_ns, @as(usize, micro_iters) * 95, "glyphs");
    std.debug.print("    hits {d} misses {d}\n", .{ type_ctx.stats.hits, type_ctx.stats.misses });

    const gid = (try font.glyphIndex('A')) orelse 0;
    const t_ras = nowNs();
    n = 0;
    while (n < micro_iters) : (n += 1) {
        const bmp = try font.rasterize(gpa, gid, size_px);
        gpa.free(bmp.pixels);
    }
    row("truetype.rasterize A x200", nowNs() - t_ras, micro_iters, "glyphs");

    const bmp = try font.rasterize(gpa, gid, size_px);
    defer gpa.free(bmp.pixels);
    var atlas = try zt.Type.Atlas.init(gpa, 1024, 1024);
    defer atlas.deinit();
    const t_at = nowNs();
    n = 0;
    var packed_n: u32 = 0;
    while (n < micro_iters) : (n += 1) {
        const rect = atlas.pack(bmp.width, bmp.height) orelse blk: {
            atlas.clear();
            break :blk atlas.pack(bmp.width, bmp.height) orelse continue;
        };
        atlas.blit(rect, bmp.pixels);
        packed_n += 1;
    }
    row("atlas.pack+blit x200", nowNs() - t_at, packed_n, "glyphs");
    std.debug.print("\n", .{});
}

fn benchPresentCopy(engine: *zt.Engine) !void {
    std.debug.print("present-shaped memcpy  (no SDL)\n", .{});
    const bytes = engine.frame.pixels.len * @sizeOf(u32);
    const tmp = try engine.allocator.alloc(u32, engine.frame.pixels.len);
    defer engine.allocator.free(tmp);
    var i: u32 = 0;
    const t0 = nowNs();
    while (i < refresh_iters) : (i += 1) {
        @memcpy(tmp, engine.frame.pixels);
    }
    row("fb memcpy x60", nowNs() - t0, refresh_iters, "frames");
    const strip = engine.cell_h * engine.frame.width;
    i = 0;
    const t1 = nowNs();
    while (i < refresh_iters) : (i += 1) {
        @memcpy(tmp[0..strip], engine.frame.pixels[0..strip]);
    }
    row("one-row memcpy x60", nowNs() - t1, refresh_iters, "frames");
    std.debug.print("    fb {d} B\n\n", .{bytes});
}

fn benchLarge(gpa: std.mem.Allocator, type_ctx: *zt.Type.Context, cell_w: u32, cell_h: u32) !void {
    const sizes = [_][2]u16{ .{ 220, 60 }, .{ @intCast(@max(1, 3840 / cell_w)), @intCast(@max(1, 2160 / cell_h)) } };

    for (sizes) |wh| {
        const scols = wh[0];
        const srows = wh[1];
        var engine = try zt.Engine.init(gpa, .{
            .cols = scols,
            .rows = srows,
            .buf_cap = ring_cap,
            .cell_w = cell_w,
            .cell_h = cell_h,
            .size_px = size_px,
            .hz = hz,
        });
        defer engine.deinit();
        engine.type_ctx = type_ctx;
        try fillAsciiScreen(gpa, &engine);
        const px = engine.frame.width * engine.frame.height;
        std.debug.print(
            "large  {d}x{d}  fb {d}x{d} ({d} px)\n",
            .{ scols, srows, engine.frame.width, engine.frame.height, px },
        );

        type_ctx.stats = .{};
        var fill_ns: u64 = 0;
        var glyph_ns: u64 = 0;
        var i: u32 = 0;
        const t_serial = nowNs();
        while (i < refresh_iters) : (i += 1) {
            engine.frame.invalidate();
            engine.frame.render(&engine.screen, engine.cell_w, engine.cell_h, type_ctx, size_px);
            fill_ns += engine.frame.last_fill_ns;
            glyph_ns += engine.frame.last_glyph_ns;
        }
        row("draw.render FULL x60", nowNs() - t_serial, refresh_iters, "frames");
        std.debug.print(
            "    fillRect {d:.3} ms ({d:.3} ms/f)   blit+lookup {d:.3} ms ({d:.3} ms/f)\n",
            .{ nsMs(fill_ns), nsMs(fill_ns) / @as(f64, refresh_iters), nsMs(glyph_ns), nsMs(glyph_ns) / @as(f64, refresh_iters) },
        );
        std.debug.print("\n", .{});
    }
}

fn fillAsciiScreen(gpa: std.mem.Allocator, engine: *zt.Engine) !void {
    const line = try gpa.alloc(u8, engine.screen.cols);
    defer gpa.free(line);
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789  ";
    var ch: usize = 0;
    var c: u16 = 0;
    while (c < line.len) : (c += 1) {
        line[c] = alphabet[ch % alphabet.len];
        ch += 1;
    }
    var runs: std.ArrayList(zt.Runs.Run) = .empty;
    defer runs.deinit(gpa);
    var r: u16 = 0;
    while (r < engine.screen.rows) : (r += 1) {
        runs.clearRetainingCapacity();
        try zt.Runs.split(gpa, line, &runs);
        engine.screen.feed(runs.items, line);
        if (r + 1 < engine.screen.rows) engine.screen.lineFeed();
    }
    engine.frame.invalidate();
    engine.frame.render(&engine.screen, engine.cell_w, engine.cell_h, engine.type_ctx, engine.size_px);
    engine.screen.clearDirty();
}

fn occupiedCells(screen: *const zt.Term.Screen) u32 {
    var n: u32 = 0;
    var r: u16 = 0;
    while (r < screen.rows) : (r += 1) {
        var c: u16 = 0;
        while (c < screen.cols) : (c += 1) {
            const cp = screen.cell(r, c).codepoint;
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

fn loadFont(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
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

fn nowNs() i128 {
    return @intCast(std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds);
}

fn nsMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn row(name: []const u8, elapsed_ns: i128, amount: usize, unit: []const u8) void {
    const ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const rate = if (sec > 0) @as(f64, @floatFromInt(amount)) / sec else 0;
    std.debug.print("  {s:<28} {d:10.3} ms", .{ name, ms });
    if (amount > 1 and elapsed_ns > 0) {
        if (std.mem.eql(u8, unit, "B")) {
            std.debug.print("  {d:8.1} MiB/s", .{rate / (1024.0 * 1024.0)});
        } else if (std.mem.eql(u8, unit, "frames")) {
            const per = ms / @as(f64, @floatFromInt(amount));
            std.debug.print("  {d:8.3} ms/f  {d:5.1} Hz  {d:5.1}% of 16.7ms", .{
                per,
                if (per > 0) 1000.0 / per else 0,
                per / 16.666666 * 100.0,
            });
        } else {
            std.debug.print("  {d:8.1} {s}/s", .{ rate, unit });
        }
    }
    std.debug.print("\n", .{});
}
