//! Differential tests for `CircBuffer.drain`: a VT fed through the drain must
//! end with the same visible state as a VT fed every byte (`exact = true`).
//! Scrollback history is allowed to differ and is never compared.
//!
//!   zig test src/firehose_test.zig src/stb_image.c -Ilib -lc -target x86_64-linux-musl

const std = @import("std");
const Ring = @import("circbuffer.zig");
const CircBuffer = Ring.CircBuffer;
const VtState = @import("vt.zig").VtState;
const Cell = @import("grid.zig").Cell;

const gpa = std.testing.allocator;

/// Label of the first difference of the latest `compare` (for the fuzz summary).
var first_what: [96]u8 = undefined;
var first_what_len: usize = 0;

fn noteFirst(what: []const u8) void {
    if (first_what_len != 0) return;
    first_what_len = @min(what.len, first_what.len);
    @memcpy(first_what[0..first_what_len], what[0..first_what_len]);
}

/// Index 0 is the reference (every byte parsed), 1 goes through the drain.
const Pair = struct {
    name: []const u8,
    cols: u16,
    rows: u16,
    ring: [2]CircBuffer,
    vt: [2]VtState,
    bad: u32 = 0,
    quiet: bool = false,

    fn create(name: []const u8, cols: u16, rows: u16, ring_size: usize) !*Pair {
        const p = try gpa.create(Pair);
        errdefer gpa.destroy(p);
        p.name = name;
        p.cols = cols;
        p.rows = rows;
        p.bad = 0;
        p.quiet = false;
        p.ring[0] = try CircBuffer.create(gpa, ring_size);
        errdefer p.ring[0].destroy();
        p.ring[1] = try CircBuffer.create(gpa, ring_size);
        errdefer p.ring[1].destroy();
        p.ring[0].exact = true;
        p.vt[0] = try VtState.init(gpa, cols, rows, 20, p.ring[0].storage);
        errdefer p.vt[0].deinit();
        p.vt[1] = try VtState.init(gpa, cols, rows, 20, p.ring[1].storage);
        return p;
    }

    fn destroy(p: *Pair) void {
        p.vt[0].deinit();
        p.vt[1].deinit();
        p.ring[0].destroy();
        p.ring[1].destroy();
        gpa.destroy(p);
    }

    /// Copy into the ring (both halves, so it works mapped or not) without draining.
    fn put(p: *Pair, i: usize, bytes: []const u8) void {
        const ring = &p.ring[i];
        const mask = ring.capacity - 1;
        for (bytes) |b| {
            const pos: usize = @intCast((ring.head) & mask);
            ring.storage[pos] = b;
            ring.storage[pos + ring.capacity] = b;
            ring.head += 1;
        }
    }

    fn freeSpace(p: *Pair, i: usize) usize {
        const ring = &p.ring[i];
        return @intCast(ring.capacity - (ring.head - ring.tail));
    }

    /// The way src/vt.zig tests feed: write what fits, drain, repeat.
    fn write(p: *Pair, i: usize, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len != 0) {
            var free = p.freeSpace(i);
            if (free == 0) {
                p.ring[i].drain(p.vt[i].sink());
                free = p.freeSpace(i);
                if (free == 0) return error.RingStalled;
            }
            const n = @min(free, rest.len);
            p.put(i, rest[0..n]);
            p.ring[i].drain(p.vt[i].sink());
            rest = rest[n..];
        }
    }

    /// Through `readSource` with a fake nonblocking source.
    fn writeSource(p: *Pair, i: usize, bytes: []const u8, max_read: usize) !void {
        var src = FakeSource{ .data = bytes, .max = max_read };
        var stalls: u32 = 0;
        while (src.pos < bytes.len) {
            const before = src.pos;
            p.ring[i].readSource(&src, 1_000_000_000, null, p.vt[i].sink()) catch return error.Hangup;
            p.ring[i].drain(p.vt[i].sink());
            if (src.pos == before) {
                stalls += 1;
                if (stalls > 2) return error.RingStalled;
            }
        }
    }

    fn report(p: *Pair, what: []const u8, a: anytype, b: anytype) void {
        p.bad += 1;
        noteFirst(what);
        if (p.quiet) return;
        std.debug.print("  [{s}] {s} differs\n    exact:   {any}\n    drained: {any}\n", .{ p.name, what, a, b });
    }

    fn reportBytes(p: *Pair, what: []const u8, a: []const u8, b: []const u8) void {
        p.bad += 1;
        noteFirst(what);
        if (p.quiet) return;
        std.debug.print("  [{s}] {s} differs\n    exact:   {f}\n    drained: {f}\n", .{ p.name, what, escaped(a), escaped(b) });
    }

    fn eq(p: *Pair, what: []const u8, a: anytype, b: anytype) void {
        if (!std.meta.eql(a, b)) p.report(what, a, b);
    }

    fn eqBytes(p: *Pair, what: []const u8, a: []const u8, b: []const u8) void {
        if (!std.mem.eql(u8, a, b)) p.reportBytes(what, a, b);
    }

    fn rowText(buf: []u8, cells: []const Cell) []const u8 {
        var n: usize = 0;
        for (cells) |c| {
            const cp: u21 = if (c.codepoint < 0x20) '?' else c.codepoint;
            n += std.unicode.utf8Encode(cp, buf[n..]) catch blk: {
                buf[n] = '?';
                break :blk 1;
            };
        }
        return buf[0..n];
    }

    fn cellStr(buf: []u8, vt: *const VtState, c: Cell) []const u8 {
        const st = vt.styleOf(c);
        return std.fmt.bufPrint(buf, "U+{X:0>4} fg={d},{d},{d} bg={d},{d},{d} attrs=0x{x}", .{ c.codepoint, st.fg.r, st.fg.g, st.fg.b, st.bg.r, st.bg.g, st.bg.b, @as(u16, @bitCast(st.attrs)) }) catch "?";
    }

    /// Same character and same resolved style (the two terminals intern
    /// styles in different orders, so ids differ).
    fn cellEql(va: *const VtState, ca: Cell, vb: *const VtState, cb: Cell) bool {
        return ca.codepoint == cb.codepoint and va.styleOf(ca).key() == vb.styleOf(cb).key();
    }

    fn rowEql(va: *const VtState, ra: []const Cell, vb: *const VtState, rb: []const Cell) bool {
        for (ra, rb) |ca, cb| if (!cellEql(va, ca, vb, cb)) return false;
        return true;
    }

    fn named(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.bufPrint(buf, fmt, args) catch "?";
    }

    /// Compare the whole visible state; returns true if equal.
    fn compare(p: *Pair) bool {
        p.bad = 0;
        first_what_len = 0;
        const a = &p.vt[0];
        const b = &p.vt[1];
        var wbuf: [64]u8 = undefined;
        p.eq("active screen", a.which, b.which);
        for (0..2) |k| {
            const ga = &a.grids[k];
            const gb = &b.grids[k];
            for (0..p.rows) |r| {
                const ra = ga.rowSliceConst(@intCast(r), p.cols);
                const rb = gb.rowSliceConst(@intCast(r), p.cols);
                if (!rowEql(a, ra, b, rb)) {
                    p.bad += 1;
                    noteFirst(named(&wbuf, "screen {d} cells", .{k}));
                    if (!p.quiet) {
                        var ta: [512]u8 = undefined;
                        var tb: [512]u8 = undefined;
                        var first: usize = 0;
                        for (ra, rb, 0..) |ca, cb, x| {
                            if (!cellEql(a, ca, b, cb)) {
                                first = x;
                                break;
                            }
                        }
                        var ca: [96]u8 = undefined;
                        var cb: [96]u8 = undefined;
                        std.debug.print("  [{s}] screen {d} row {d} cells differ (first at col {d}: exact={s} drained={s})\n    exact:   |{s}|\n    drained: |{s}|\n", .{ p.name, k, r, first, cellStr(&ca, a, ra[first]), cellStr(&cb, b, rb[first]), rowText(&ta, ra), rowText(&tb, rb) });
                    }
                }
                const wa = ga.wraps[ga.lineIndex(@intCast(r))];
                const wb = gb.wraps[gb.lineIndex(@intCast(r))];
                p.eq(named(&wbuf, "screen {d} row {d} soft-wrap flag", .{ k, r }), wa, wb);
            }
            p.eq(named(&wbuf, "screen {d} cursor", .{k}), ga.cursor, gb.cursor);
            p.eq(named(&wbuf, "screen {d} wrap_pending", .{k}), ga.wrap_pending, gb.wrap_pending);
            p.eq(named(&wbuf, "screen {d} pen fg", .{k}), ga.fg, gb.fg);
            p.eq(named(&wbuf, "screen {d} pen bg", .{k}), ga.bg, gb.bg);
            p.eq(named(&wbuf, "screen {d} pen attrs", .{k}), ga.attrs, gb.attrs);
            p.eq(named(&wbuf, "screen {d} saved cursor", .{k}), ga.saved_cursor, gb.saved_cursor);
            p.eq(named(&wbuf, "screen {d} saved wrap_pending", .{k}), ga.saved_wrap_pending, gb.saved_wrap_pending);
            p.eq(named(&wbuf, "screen {d} saved fg", .{k}), ga.saved_fg, gb.saved_fg);
            p.eq(named(&wbuf, "screen {d} saved bg", .{k}), ga.saved_bg, gb.saved_bg);
            p.eq(named(&wbuf, "screen {d} saved attrs", .{k}), ga.saved_attrs, gb.saved_attrs);
            p.eq(named(&wbuf, "screen {d} scroll_top", .{k}), ga.scroll_top, gb.scroll_top);
            p.eq(named(&wbuf, "screen {d} scroll_bottom", .{k}), ga.scroll_bottom, gb.scroll_bottom);
            p.eq(named(&wbuf, "screen {d} view scroll", .{k}), ga.scroll, gb.scroll);
        }
        p.eq("flags", @as(u32, @bitCast(a.flags)), @as(u32, @bitCast(b.flags)));
        p.eq("cursor_style", a.cursor_style, b.cursor_style);
        p.eq("mouse", a.mouse, b.mouse);
        p.eq("modify_other_keys", a.modify_other_keys, b.modify_other_keys);
        p.eq("g0", a.g0, b.g0);
        p.eq("g1", a.g1, b.g1);
        p.eq("g2", a.g2, b.g2);
        p.eq("g3", a.g3, b.g3);
        p.eq("gl", a.gl, b.gl);
        p.eq("ss", a.ss, b.ss);
        p.eq("ss_active", a.ss_active, b.ss_active);
        // `last_cp` (the REP character) is not compared: it differs after any dropped
        // text, and only matters through a later REP, which the "REP after dropped
        // text" case and the fuzz vocabulary check through the visible cells.
        p.eq("saved_mode", a.saved_mode, b.saved_mode);
        p.eq("saved_mode_val", a.saved_mode_val, b.saved_mode_val);
        p.eqBytes("tab stops", std.mem.sliceAsBytes(a.tabs), std.mem.sliceAsBytes(b.tabs));
        p.eq("scheme", a.scheme, b.scheme);
        p.eqBytes("palette table", std.mem.sliceAsBytes(a.table[0..]), std.mem.sliceAsBytes(b.table[0..]));
        p.eq("ul_color", a.ul_color, b.ul_color);
        p.eq("ul_set", a.ul_set, b.ul_set);
        p.eq("color_stack_size", a.color_stack_size, b.color_stack_size);
        p.eq("color_stack_idx", a.color_stack_idx, b.color_stack_idx);
        p.eq("kitty_kbd", a.kitty_kbd, b.kitty_kbd);
        p.eq("kitty_kbd_idx", a.kitty_kbd_idx, b.kitty_kbd_idx);
        p.eqBytes("title", a.title.items, b.title.items);
        p.eq("title_stack len", a.title_stack.items.len, b.title_stack.items.len);
        if (a.title_stack.items.len == b.title_stack.items.len) {
            for (a.title_stack.items, b.title_stack.items) |x, y| p.eqBytes("title_stack entry", x, y);
        }
        p.eqBytes("cwd", a.cwd.items, b.cwd.items);
        p.eqBytes("app_id", a.app_id.items, b.app_id.items);
        p.eqBytes("notify_title", a.notify_title.items, b.notify_title.items);
        p.eqBytes("notify_body", a.notify_body.items, b.notify_body.items);
        p.eqBytes("clipboard", a.clip.items, b.clip.items);
        p.eq("clip_kind", a.clip_kind, b.clip_kind);
        p.eq("pointer shape", a.pointer, b.pointer);
        p.eq("sel colors", .{ a.have_sel_fg, a.have_sel_bg, a.sel_fg, a.sel_bg }, .{ b.have_sel_fg, b.have_sel_bg, b.sel_fg, b.sel_bg });
        p.eq("sixel state", .{ a.sixel_reg, a.sixel_geo_w, a.sixel_geo_h, a.sixel_palette_ok }, .{ b.sixel_reg, b.sixel_geo_w, b.sixel_geo_h, b.sixel_palette_ok });
        if (a.sixel_palette_ok and b.sixel_palette_ok) {
            p.eqBytes("sixel palette", std.mem.sliceAsBytes(a.sixel_palette[0..]), std.mem.sliceAsBytes(b.sixel_palette[0..]));
        }
        p.eq("shell_mark", a.shell_mark, b.shell_mark);
        p.eq("kitty open transfer", .{ a.kitty.streaming(), a.kitty.assembling }, .{ b.kitty.streaming(), b.kitty.assembling });
        p.eqBytes("reply bytes", a.reply.items, b.reply.items);
        p.compareImages();
        return p.bad == 0;
    }

    const Img = struct {
        id: u32,
        col: i32,
        rel: i64,
        columns: u32,
        rows: u32,
        src: [4]u32,
        screen: u1,
        w: u32,
        h: u32,
        have_img: bool,
        pix: u64,
        pend: u64,
        has_pend: bool,
    };

    fn collect(p: *Pair, vt: *VtState, out: *std.ArrayList(Img)) !void {
        vt.prepareImages();
        for (vt.kitty.placements.items) |pl| {
            const g = &vt.grids[pl.screen];
            const rel = pl.row - @as(i64, @intCast(g.base));
            const img = vt.kitty.find(pl.image_id);
            const span: i64 = if (pl.rows != 0) pl.rows else if (img) |im| @divTrunc(@as(i64, im.height) + vt.cell_px_h - 1, vt.cell_px_h) else 1;
            if (rel >= p.rows or rel + @max(span, 1) <= 0) continue;
            var e = Img{ .id = pl.image_id, .col = pl.col, .rel = rel, .columns = pl.columns, .rows = pl.rows, .src = .{ pl.src_x, pl.src_y, pl.src_w, pl.src_h }, .screen = pl.screen, .w = 0, .h = 0, .have_img = false, .pix = 0, .pend = 0, .has_pend = false };
            if (img) |im| {
                e.have_img = true;
                e.w = im.width;
                e.h = im.height;
                if (im.assigned) e.id = 0;
                e.pix = std.hash.Wyhash.hash(0, im.rgba);
                if (im.pending) |pe| {
                    e.has_pend = true;
                    e.pend = std.hash.Wyhash.hash(0, pe.data);
                }
            }
            try out.append(gpa, e);
        }
    }

    fn compareImages(p: *Pair) void {
        var la: std.ArrayList(Img) = .empty;
        defer la.deinit(gpa);
        var lb: std.ArrayList(Img) = .empty;
        defer lb.deinit(gpa);
        p.collect(&p.vt[0], &la) catch return;
        p.collect(&p.vt[1], &lb) catch return;
        if (la.items.len != lb.items.len) {
            p.report("on-screen image placement count", la.items.len, lb.items.len);
            return;
        }
        for (la.items, lb.items, 0..) |x, y, i| {
            if (!std.meta.eql(x, y)) {
                var buf: [64]u8 = undefined;
                p.report(named(&buf, "image placement #{d}", .{i}), x, y);
            }
        }
    }
};

const FakeSource = struct {
    data: []const u8,
    max: usize,
    pos: usize = 0,

    pub fn read(self: *FakeSource, dest: []u8) error{ WouldBlock, Unused }!usize {
        if (self.pos >= self.data.len) return error.WouldBlock;
        const n = @min(@min(dest.len, self.max), self.data.len - self.pos);
        @memcpy(dest[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    pub fn wait(self: *FakeSource, event_fd: ?c_int, timeout_ms: c_int) void {
        _ = self;
        _ = event_fd;
        _ = timeout_ms;
    }
};

fn escaped(bytes: []const u8) std.fmt.Alt([]const u8, formatEsc) {
    return .{ .data = bytes };
}

fn formatEsc(bytes: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (bytes) |b| switch (b) {
        0x1b => try w.writeAll("\\e"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\\' => try w.writeAll("\\\\"),
        0x20...0x5b, 0x5d...0x7e => try w.writeByte(b),
        else => try w.print("\\x{x:0>2}", .{b}),
    };
}

/// Feed `chunks` to a fresh pair and compare after every chunk. `source_max`
/// 0 writes directly into the ring, otherwise through `readSource` with that
/// read size cap.
fn runChunks(name: []const u8, cols: u16, rows: u16, ring_size: usize, chunks: []const []const u8, source_max: usize, quiet: bool) !bool {
    const p = try Pair.create(name, cols, rows, ring_size);
    defer p.destroy();
    p.quiet = quiet;
    var total: usize = 0;
    for (chunks, 0..) |c, ci| {
        total += c.len;
        for (0..2) |i| {
            if (source_max == 0) try p.write(i, c) else try p.writeSource(i, c, source_max);
        }
        if (!p.compare()) {
            if (!quiet) std.debug.print("  [{s}] mismatch after chunk {d} ({d} bytes), ring {d}{s}\n", .{ name, ci, total, ring_size, if (source_max == 0) "" else " (readSource)" });
            return false;
        }
    }
    return true;
}

/// Run one case in several shapes: given chunks on both ring sizes, as one
/// chunk, byte by byte, and through readSource.
fn runCase(name: []const u8, cols: u16, rows: u16, chunks: []const []const u8) !void {
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(gpa);
    for (chunks) |c| try all.appendSlice(gpa, c);
    const singles = try gpa.alloc([]const u8, all.items.len);
    defer gpa.free(singles);
    for (singles, 0..) |*s, i| s.* = all.items[i .. i + 1];
    const whole: []const []const u8 = &.{all.items};

    var failed = false;
    const Shape = struct { label: []const u8, ring: usize, chunks: []const []const u8, src: usize };
    const shapes = [_]Shape{
        .{ .label = "chunks/4096", .ring = 4096, .chunks = chunks, .src = 0 },
        .{ .label = "chunks/1024", .ring = 1024, .chunks = chunks, .src = 0 },
        .{ .label = "whole/4096", .ring = 4096, .chunks = whole, .src = 0 },
        .{ .label = "bytewise/1024", .ring = 1024, .chunks = singles, .src = 0 },
        .{ .label = "readSource/1024", .ring = 1024, .chunks = chunks, .src = 7 },
    };
    for (shapes) |s| {
        var buf: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s} {s}", .{ name, s.label }) catch name;
        if (!try runChunks(label, cols, rows, s.ring, s.chunks, s.src, failed)) {
            std.debug.print("FAILED case '{s}' shape {s}, bytes: {f}\n", .{ name, s.label, escaped(all.items) });
            failed = true;
        }
    }
    if (failed) return error.DrainDiffersFromExact;
}

fn one(name: []const u8, cols: u16, rows: u16, bytes: []const u8) !void {
    try runCase(name, cols, rows, &.{bytes});
}

/// Split `bytes` in two at every position; ring 1024.
fn sweep(name: []const u8, cols: u16, rows: u16, bytes: []const u8) !void {
    var failures: usize = 0;
    var first_fail: ?usize = null;
    var last_fail: usize = 0;
    for (0..bytes.len + 1) |at| {
        var buf: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s} split@{d}", .{ name, at }) catch name;
        if (!try runChunks(label, cols, rows, 1024, &.{ bytes[0..at], bytes[at..] }, 0, failures != 0)) {
            failures += 1;
            if (first_fail == null) first_fail = at;
            last_fail = at;
        }
    }
    if (failures != 0) {
        std.debug.print("FAILED sweep '{s}': {d} of {d} split positions differ (first {d}, last {d}), bytes: {f}\n", .{ name, failures, bytes.len + 1, first_fail.?, last_fail, escaped(bytes) });
        return error.DrainDiffersFromExact;
    }
}

/// Odd-sized reads that end exactly at each `cuts` offset; counts the reads
/// that went outside the ring (straight into the spill buffer).
const PieceSource = struct {
    data: []const u8,
    cuts: []const usize,
    ring: []const u8,
    pos: usize = 0,
    step: usize = 0,
    direct: usize = 0,

    pub fn read(self: *PieceSource, dest: []u8) error{ WouldBlock, Unused }!usize {
        if (self.pos >= self.data.len) return error.WouldBlock;
        const sizes = [_]usize{ 1, 7, 4093, 13, 509, 3001, 65 };
        var n = @min(@min(dest.len, self.data.len - self.pos), sizes[self.step % sizes.len]);
        self.step += 1;
        for (self.cuts) |c| if (c > self.pos and c < self.pos + n) {
            n = c - self.pos;
        };
        const d = @intFromPtr(dest.ptr);
        const r = @intFromPtr(self.ring.ptr);
        if (d < r or d >= r + self.ring.len) self.direct += 1;
        @memcpy(dest[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    pub fn wait(self: *PieceSource, event_fd: ?c_int, timeout_ms: c_int) void {
        _ = self;
        _ = event_fd;
        _ = timeout_ms;
    }
};

test "one-string kitty image larger than the ring: read into spill, then handed to the image" {
    // Not subject to the drain/exact mismatches below: ring 4096 and an
    // image of 64x64 RGBA (21848 base64 bytes) in a single APC.
    const p = try Pair.create("one-apc-image", 20, 5, 4096);
    defer p.destroy();
    var raw: [64 * 64 * 4]u8 = undefined;
    for (&raw, 0..) |*b, i| b.* = @truncate(i *% 7 +% i / 251);
    var b64: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&b64, &raw);
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    try stream.appendSlice(gpa, "ab\x1b_Ga=T,f=32,s=64,v=64,i=9,c=4,r=2;");
    try stream.appendSlice(gpa, &b64);
    // ESC ends one read, the backslash starts the next.
    const esc_at = stream.items.len;
    try stream.appendSlice(gpa, "\x1b\\done");

    try p.write(0, stream.items);

    var src = PieceSource{ .data = stream.items, .cuts = &.{esc_at + 1}, .ring = p.ring[1].storage };
    while (src.pos < stream.items.len) {
        try p.ring[1].readSource(&src, 1_000_000_000, null, p.vt[1].sink());
    }
    p.ring[1].drain(p.vt[1].sink());

    try std.testing.expect(src.direct > 4);
    const img = p.vt[1].kitty.find(9) orelse return error.NoImage;
    const pend = img.pending orelse return error.NotPending;
    // The base64 stayed where read(2) wrote it: the image owns the spill buffer.
    try std.testing.expect(pend.owned.len != 0);
    try std.testing.expectEqualSlices(u8, &b64, pend.data);
    try std.testing.expectEqual(@as(usize, 0), p.ring[1].spill.capacity);
    try std.testing.expect(p.compare());
    const shown = p.vt[1].kitty.find(9).?;
    try std.testing.expectEqualSlices(u8, &raw, shown.rgba);
    const dump = try p.vt[1].dumpAlloc(gpa);
    defer gpa.free(dump);
    try std.testing.expect(std.mem.indexOf(u8, dump, "done") != null);
}

// ------------------------------------------------------------ reviewer cases

test "CPR after dropped text" {
    try one("cpr", 8, 3, "ABC\x1b[6n\x1b[H\x1b[2J");
}

test "DECSC position dropped" {
    try one("decsc", 8, 3, "\x1b[2;3H\x1b7\x1b[H\x1b[2J\x1b8X");
}

test "mode save survives dedup (XTSAVE/XTRESTORE)" {
    try one("xtsave", 8, 3, "\x1b[?1h\x1b[?1s\x1b[?1l\x1b[H\x1b[2J\x1b[?1r");
}

test "DECRQM after dropped mode change" {
    try one("decrqm", 8, 3, "\x1b[?1h\x1b[?1$p\x1b[?1l\x1b[H\x1b[2J");
}

test "DECSTBM vs DECRQSS" {
    try one("decrqss", 8, 3, "\x1b[2;3r\x1bP$qr\x1b\\\x1b[1;2r\x1b[H\x1b[2J");
}

test "cursor column entering the live region" {
    try one("col-after-lf", 8, 2, "A\n\n\nX");
}

test "cursor row after ED 2" {
    try one("row-after-ed2", 8, 2, "A\r\nB\x1b[2JX");
}

test "ED 3 is not a screen clear" {
    try one("ed3", 8, 3, "A\x1b[2;1HB\x1b[3J");
}

test "origin mode home plus ED 0" {
    try one("origin-ed0", 8, 4, "A\x1b[2;3r\x1b[?6h\x1b[H\x1b[J");
}

test "alt screen exit does not clear (47 after 1049)" {
    try one("alt-1049-47", 8, 3, "\x1b[?1049hA\x1b[?1049l\x1b[?47h");
}

test "repeated 1049h" {
    try one("alt-1049-1049", 8, 3, "P\x1b[?1049hA\x1b[?1049hB\x1b[?1049lQ\x1b[?1049h");
}

test "1047 alt screen" {
    try one("alt-1047", 8, 3, "P\x1b[?1047hA\x1b[?1047lQ\x1b[?1047hR");
}

test "raw C1 RI inside text" {
    try one("c1-ri", 8, 2, "A\r\n\x8d\r\n\x8d\r\nX");
}

test "reverse-wrap BS inside text" {
    try one("revwrap", 8, 2, "12345678abc\x08\x08\x08\x08\x08\x08\x08\x08\x08\x08\x08\x08\x08\x08Xz");
}

test "REP after dropped text" {
    try one("rep", 8, 3, "A\x1b[H\x1b[2J\x1b[b");
}

test "sixel shared palette" {
    try one("sixel-palette", 8, 3, "\x1b[?1070l\x1bPq#1;2;0;100;0~\x1b\\\x1b[H\x1b[2J\x1bPq#1~\x1b\\");
}

test "kitty replies kept for dead transfers" {
    try one("kitty-replies", 8, 3, "\x1b_Ga=t,f=32,s=1,v=1,i=7;AAAAAA==\x1b\\\x1b[H\x1b[2J\x1b_Ga=t,f=32,s=1,v=1,i=7;AAAAAA==\x1b\\");
}

test "kitty query interleaved in a chunked transfer across two drains" {
    try runCase("kitty-interleave", 8, 3, &.{
        "\x1b_Ga=t,f=32,s=1,v=1,i=7,m=1;/wAA\x1b\\",
        "\x1b_Ga=q,i=9;\x1b\\\x1b_Gm=0;/w==\x1b\\\x1b[H\x1b[2J",
    });
}

test "kitty displayed image around a clear" {
    try one("kitty-display", 8, 3, "\x1b_Ga=T,f=32,s=1,v=1,i=3;AAAAAA==\x1b\\\x1b[H\x1b[2J\x1b_Ga=T,f=32,s=1,v=1,i=4;/wAA/w==\x1b\\");
}

// ----------------------------------------------------------------- own cases

test "SGR state across a dead region" {
    try one("sgr-cut", 8, 3, "\x1b[31;1mA\x1b[H\x1b[2J\x1b[4mX");
}

test "SGR across scrolled-off lines" {
    try one("sgr-scroll", 8, 3, "\x1b[1;42mAAA\r\nB\r\nC\r\nD\r\nE\x1b[0mF\r\n\x1b[7mG");
}

test "DECSTBM with LFs inside a region" {
    try one("stbm-lf", 8, 4, "1\r\n\x1b[2;3r\x1b[3;1Ha\nb\nc\nd\x1b[re\r\nf");
}

test "DECSTBM region scroll then clear" {
    try one("stbm-clear", 8, 4, "\x1b[2;3r\x1b[2;1H1\n2\n3\n4\n5\x1b[H\x1b[2J\x1b[r\x1b[3;3HX");
}

test "wrap_pending at the cut (scrolled)" {
    try one("wrap-pending-scroll", 8, 3, "1\r\n2\r\n3\r\n4\r\n12345678");
}

test "wrap_pending at the cut then print" {
    try one("wrap-pending-print", 8, 3, "1\r\n2\r\n3\r\n4\r\n12345678X");
}

test "wrap_pending at a clear" {
    try one("wrap-pending-clear", 8, 3, "ab\x1b[H\x1b[2J12345678");
}

test "OSC title in a dead region" {
    try one("title-dead", 8, 3, "\x1b]0;one\x07A\x1b[H\x1b[2J");
}

test "OSC title overwritten in a dead region" {
    try one("title-overwrite", 8, 3, "\x1b]2;one\x1b\\\x1b]2;two\x07\x1b[H\x1b[2J");
}

test "title stack across a dead region" {
    try one("title-stack", 8, 3, "\x1b[22;0t\x1b]0;a\x07\x1b[H\x1b[2J\x1b[23;0t");
}

test "OSC 8 hyperlink spanning the cut" {
    try one("osc8-span", 8, 3, "\x1b]8;;http://a\x07AB\r\n\r\n\r\n\r\nCD\x1b]8;;\x07E");
}

test "OSC 8 opened before a clear" {
    try one("osc8-clear", 8, 3, "\x1b]8;;http://a\x07AB\x1b[H\x1b[2JCD\x1b]8;;\x07E");
}

test "OSC colors in a dead region" {
    try one("osc-colors", 8, 3, "\x1b]4;1;#ff0000\x07\x1b]11;#102030\x07\x1b]4;1;#00ff00\x07A\x1b[H\x1b[2J\x1b]104\x07");
}

test "tab stops and HT" {
    try one("tabs", 20, 3, "\tA\t\t\x1b[H\x1b[2J\x1b[3C\x1bH\x1b[H\x1b[2J\tB\x1b[g\tC\x1b[3g\r\tD");
}

test "HT across scrolled lines" {
    try one("tabs-scroll", 20, 3, "\x1b[5G\x1bH\r\n\tA\r\n\tB\r\n\tC\r\n\tD");
}

test "insert mode" {
    try one("insert", 8, 3, "ABCD\x1b[4h\x1b[H\x1b[2J12\x1b[1;1Hxy\x1b[4lz");
}

test "DECAWM off" {
    try one("autowrap-off", 8, 3, "\x1b[?7l12345678901\x1b[H\x1b[2J\x1b[?7lABCDEFGHIJ\x1b[?7hK");
}

test "wide chars at the cut (clear)" {
    try one("wide-clear", 8, 3, "旦旦旦旦\x1b[H\x1b[2J1234567旦8");
}

test "wide chars at the cut (scroll)" {
    try one("wide-scroll", 8, 3, "1\r\n2\r\n3\r\n1234567旦旦");
}

test "charsets across a dead region" {
    try one("charset", 8, 3, "\x1b(0q\x1b)0\x0eq\x1b[H\x1b[2J\x0fq\x1b(Bq");
}

test "cursor style and visibility across a clear" {
    try one("cursor-style", 8, 3, "\x1b[3 q\x1b[?25l\x1b[H\x1b[2J\x1b[5 q");
}

test "alt screen content survives a primary clear" {
    try one("alt-primary", 8, 3, "P1\r\nP2\x1b[?1049hA\r\nB\x1b[H\x1b[2JC\x1b[?1049lX\x1b[H\x1b[2J\x1b[?1049hY");
}

test "alt screen scrolling LFs" {
    try one("alt-scroll", 8, 3, "\x1b[?1049h1\r\n2\r\n3\r\n4\r\n5\r\n6\x1b[?1049lz");
}

test "queries scattered over a clear" {
    try one("queries", 12, 4, "AB\x1b[6n\x1b[c\x1b[>c\x1b[?6n\x1b[H\x1b[2J\x1b[5n\x1b[18t\x1b[14t\x1b[?u");
}

test "split at every byte: CSI" {
    try sweep("split-csi", 8, 3, "A\x1b[H\x1b[2J\x1b[2;3H\x1b[1;38;2;1;2;3mX\x1b[6n");
}

test "split at every byte: OSC with BEL" {
    try sweep("split-osc-bel", 8, 3, "A\x1b[H\x1b[2J\x1b]0;hello title\x07X");
}

test "split at every byte: OSC with ST" {
    try sweep("split-osc-st", 8, 3, "A\x1b[H\x1b[2J\x1b]2;hello\x1b\\X");
}

test "split at every byte: UTF-8 4-byte" {
    try sweep("split-utf8", 8, 3, "A\x1b[H\x1b[2J😀X旦é");
}

test "split at every byte: kitty APC" {
    try sweep("split-kitty", 8, 3, "\x1b_Ga=T,f=32,s=1,v=1,i=3;AAAAAA==\x1b\\\x1b[H\x1b[2J\x1b_Ga=T,f=32,s=1,v=1,i=4;/wAA/w==\x1b\\");
}

test "split at every byte: sixel" {
    try sweep("split-sixel", 8, 3, "\x1bPq#0;2;100;0;0#0~~~\x1b\\\x1b[H\x1b[2J\x1bPq#0~\x1b\\X");
}

test "split at every byte: DCS DECRQSS" {
    try sweep("split-decrqss", 8, 3, "\x1b[2;3r\x1bP$qr\x1b\\\x1b[H\x1b[2J\x1bP$qm\x1b\\");
}

test "strings longer than the ring: OSC (spill)" {
    try one("long-osc", 8, 3, "A\x1b]2;" ++ rep("t", 5000) ++ "\x07\x1b[H\x1b[2JX");
}

test "strings longer than the ring: OSC across drains" {
    try runCase("long-osc-chunks", 8, 3, &.{ "A\x1b]2;" ++ rep("t", 3000), rep("u", 3000) ++ "\x07\x1b[H\x1b[2JX" });
}

test "strings longer than the ring: OSC 52 and DCS" {
    try one("long-clip-dcs", 8, 3, "\x1b]52;c;" ++ rep("AAAA", 1500) ++ "\x07\x1bP" ++ rep("z", 3000) ++ "\x1b\\\x1b[H\x1b[2JX");
}

test "strings longer than the ring: sixel" {
    try one("long-sixel", 8, 3, "\x1bPq#0;2;100;0;0" ++ rep("~", 3000) ++ "\x1b\\\x1b[H\x1b[2JX");
}

test "text longer than the ring with scrolling" {
    try one("long-text", 20, 4, "0123456789\r\n" ++ rep(rep("x", 80) ++ "\r\n", 80) ++ "end");
}

// ---------------------------------------------------------------------- fuzz

const text_pieces = [_][]const u8{
    "hello",  " world", "A",  "X",   "0123456789012345678901234567890", "wörld", "旦海", "😀", "e\u{301}",
    "\r\n",   "\n",     "\r", "\n",  "\r\n",                            "\x08",   "\t",   "\x0b", "\x0c",
};

const ctl_pieces = [_][]const u8{
    // motion and erase
    "\x1b[H",       "\x1b[2;3H",   "\x1b[5;9H",    "\x1b[1;1H",  "\x1b[3A",           "\x1b[2B",          "\x1b[4C",           "\x1b[3D",    "\x1b[2E",
    "\x1b[F",       "\x1b[5G",     "\x1b[3d",      "\x1b[J",     "\x1b[0J",           "\x1b[1J",          "\x1b[2J",           "\x1b[2J",    "\x1b[3J",
    "\x1b[K",       "\x1b[1K",     "\x1b[2K",      "\x1b[2L",    "\x1b[M",            "\x1b[3@",          "\x1b[2P",           "\x1b[4X",    "\x1b[S",
    "\x1b[T",       "\x1b[3b",     "\x1b[b",       "\x1b[3I",    "\x1b[2Z",           "\x1b[g",           "\x1b[3g",           "\x1bH",
    // regions
    "\x1b[2;3r",    "\x1b[r",      "\x1b[2;4r",
    // SGR
    "\x1b[1m",      "\x1b[31m",    "\x1b[0m",      "\x1b[m",     "\x1b[38;2;1;2;3m",  "\x1b[48;5;100m",   "\x1b[4:3m",         "\x1b[7m",
    // modes
    "\x1b[?7l",     "\x1b[?7h",    "\x1b[?6h",     "\x1b[?6l",   "\x1b[?25l",         "\x1b[?25h",        "\x1b[?1h",          "\x1b[?1l",   "\x1b[4h",
    "\x1b[4l",      "\x1b[?1s",    "\x1b[?1r",     "\x1b[?2004h", "\x1b[?5h",         "\x1b[?5l",         "\x1b[?47h",         "\x1b[?47l",  "\x1b[?1047h",
    "\x1b[?1047l",  "\x1b[?1049h", "\x1b[?1049l",  "\x1b[?1049h", "\x1b[?1049l",      "\x1b[?1070l",      "\x1b[?1070h",       "\x1b[3 q",   "\x1b[?1000h",
    // queries
    "\x1b[6n",      "\x1b[5n",     "\x1b[c",       "\x1b[>c",    "\x1b[?1$p",         "\x1b[?6$p",        "\x1bP$qr\x1b\\",    "\x1bP$qm\x1b\\", "\x1b[?u",
    "\x1b[14t",     "\x1b[18t",    "\x1b[22;0t",   "\x1b[23;0t", "\x1b[?996n",
    // ESC and C1
    "\x1b7",        "\x1b8",       "\x1bM",        "\x1bD",      "\x1bE",             "\x1b(0",           "\x1b(B",            "\x1b)0",     "\x0e",
    "\x0f",         "\x1b#8",      "\x8d",         "\x84",       "\x85",              "\x1bc",
    // OSC
    "\x1b]0;title\x07", "\x1b]2;t2\x1b\\", "\x1b]8;;http://x\x07", "\x1b]8;;\x07", "\x1b]11;#102030\x07", "\x1b]4;1;#ff0000\x07", "\x1b]104\x07",
    "\x1b]7;file:///tmp\x07", "\x1b]133;A\x07", "\x1b]52;c;aGk=\x07",
    // kitty
    "\x1b_Ga=T,f=32,s=1,v=1;AAAAAA==\x1b\\",
    "\x1b_Ga=T,f=32,s=1,v=1,i=5,c=2,r=1;/wAA/w==\x1b\\",
    "\x1b_Ga=t,f=32,s=1,v=1,i=7;AAAAAA==\x1b\\",
    "\x1b_Ga=p,i=7\x1b\\",
    "\x1b_Ga=d\x1b\\",
    "\x1b_Ga=q,i=9;\x1b\\",
    "\x1b_Ga=t,f=32,s=1,v=1,i=8,m=1;/wAA\x1b\\",
    "\x1b_Gm=0;/w==\x1b\\",
    // sixel
    "\x1bPq#0;2;100;0;0#0~~~~-#0~~\x1b\\",
    "\x1bPq#1;2;0;100;0~\x1b\\",
    "\x1bPq#1~~\x1b\\",
    // long string
    "\x1b]2;" ++ rep("t", 2000) ++ "\x07",
};

const FuzzCase = struct {
    seed: u64,
    cols: u16,
    rows: u16,
    ring: usize,
};

/// Piece index space: [0, text_pieces.len) text, then ctl.
fn pieceBytes(idx: u32) []const u8 {
    if (idx < text_pieces.len) return text_pieces[idx];
    return ctl_pieces[idx - text_pieces.len];
}

fn buildBytes(pieces: []const u32, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    for (pieces) |i| try out.appendSlice(gpa, pieceBytes(i));
}

/// Deterministic for (case, pieces): chunk sizes come from the case seed.
fn fuzzRun(c: FuzzCase, pieces: []const u32, quiet: bool) !bool {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try buildBytes(pieces, &bytes);
    var chunks: std.ArrayList([]const u8) = .empty;
    defer chunks.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(c.seed ^ 0x9e3779b97f4a7c15);
    const rand = prng.random();
    var at: usize = 0;
    while (at < bytes.items.len) {
        const n: usize = switch (rand.uintLessThan(u8, 6)) {
            0 => 1 + rand.uintLessThan(usize, 3),
            1 => 1 + rand.uintLessThan(usize, 2000),
            else => 1 + rand.uintLessThan(usize, 120),
        };
        const end = @min(bytes.items.len, at + n);
        try chunks.append(gpa, bytes.items[at..end]);
        at = end;
    }
    const source_max: usize = if (c.seed & 1 == 0) 0 else 1 + rand.uintLessThan(usize, 200);
    return runChunks("fuzz", c.cols, c.rows, c.ring, chunks.items, source_max, quiet);
}

/// Drop ranges of pieces (halving the range size) while the case still fails.
fn shrink(c: FuzzCase, list: *std.ArrayList(u32)) !void {
    var step: usize = @max(list.items.len / 2, 1);
    while (true) {
        var i: usize = 0;
        while (i < list.items.len) {
            const end = @min(list.items.len, i + step);
            const saved = try gpa.dupe(u32, list.items[i..end]);
            defer gpa.free(saved);
            list.replaceRangeAssumeCapacity(i, end - i, &.{});
            if (list.items.len != 0 and !try fuzzRun(c, list.items, true)) continue; // still fails: stay removed
            try list.insertSlice(gpa, i, saved);
            i += step;
        }
        if (step == 1) break;
        step /= 2;
    }
}

test "seeded differential fuzz" {
    const master: u64 = 0xF1AE_C0DE;
    const ncases = 150;
    const n_text = text_pieces.len;
    const n_all = n_text + ctl_pieces.len;
    var failures: usize = 0;
    const Tally = struct { name: [96]u8 = undefined, len: usize = 0, n: u32 = 0 };
    var tally: [32]Tally = @splat(.{});
    var ntally: usize = 0;
    var pieces: std.ArrayList(u32) = .empty;
    defer pieces.deinit(gpa);
    for (0..ncases) |ci| {
        const seed = master +% ci *% 0x9E3779B97F4A7C15;
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        const c = FuzzCase{
            .seed = seed,
            .cols = 8 + rand.uintLessThan(u16, 13),
            .rows = 3 + rand.uintLessThan(u16, 6),
            .ring = if (rand.boolean()) 1024 else 4096,
        };
        pieces.clearRetainingCapacity();
        const count = 20 + rand.uintLessThan(usize, 70);
        for (0..count) |_| {
            const idx: u32 = if (rand.uintLessThan(u8, 100) < 35)
                rand.uintLessThan(u32, n_text)
            else
                @intCast(n_text + rand.uintLessThan(usize, n_all - n_text));
            try pieces.append(gpa, idx);
        }
        if (try fuzzRun(c, pieces.items, true)) continue;
        failures += 1;
        const what = first_what[0..first_what_len];
        var slot: ?usize = null;
        for (tally[0..ntally], 0..) |t, ti| {
            if (std.mem.eql(u8, t.name[0..t.len], what)) slot = ti;
        }
        if (slot == null and ntally < tally.len) {
            tally[ntally] = .{ .len = what.len };
            @memcpy(tally[ntally].name[0..what.len], what);
            slot = ntally;
            ntally += 1;
        }
        if (slot) |ti| tally[ti].n += 1;
        if (failures > 3) continue;
        try shrink(c, &pieces);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try buildBytes(pieces.items, &bytes);
        std.debug.print("\nFUZZ FAILURE seed=0x{x} case={d} grid={d}x{d} ring={d} (shrunk to {d} pieces, {d} bytes)\n  bytes: {f}\n", .{ seed, ci, c.cols, c.rows, c.ring, pieces.items.len, bytes.items.len, escaped(bytes.items) });
        _ = try fuzzRun(c, pieces.items, false);
    }
    if (failures != 0) {
        std.debug.print("fuzz: {d} of {d} cases differ (first 3 shrunk above); first differing item per failing case:\n", .{ failures, ncases });
        for (tally[0..ntally]) |t| std.debug.print("  {d:>4}  {s}\n", .{ t.n, t.name[0..t.len] });
        return error.DrainDiffersFromExact;
    }
}

fn rep(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    @setEvalBranchQuota(1_000_000);
    var out: [s.len * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

// ------------------------------------------------- second review (sol)

const red_px = "/wAA/w==";

test "dead line feeds still scroll a placed image away" {
    try runCase("ghost-scroll-image", 8, 3, &.{ "\x1b_Ga=T,f=32,s=1,v=1,i=5,c=1,r=8,C=1;" ++ red_px ++ "\x1b\\", &rep("\n", 20) });
}

test "an image taller than the screen outlives the LF cut" {
    try one("tall-image", 8, 3, "\x1b_Ga=T,f=32,s=1,v=1,i=5,c=1,r=8,C=1;" ++ red_px ++ "\x1b\\" ++ rep("\n", 5));
}

test "DECSTR and RIS keep reverse wraparound on" {
    try one("decstr-rwrap", 8, 2, "A\x1b[!p\n\r\x08\n\r\x08\n");
    try one("ris-rwrap", 8, 2, "\x1bcA\n\r\x08\n\r\x08\n");
}

test "XTRESTORE and leaving the alt screen restart the LF count" {
    try one("xtrestore-origin", 8, 2, "\x1b[?6sA\n\x1b[?6r\n\x1b[?6r\n");
    try one("alt-restore", 8, 2, "A\n\x1b[?47h\x1b[?1049l\n\x1b[?47h\x1b[?1049l\n");
}

test "a cleared image is gone for a later a=p" {
    try runCase("clear-then-place", 8, 3, &.{ "\x1b_Ga=T,f=32,s=1,v=1,i=5,c=1,r=1,C=1;" ++ red_px ++ "\x1b\\\x1b[2J", "\x1b_Ga=p,i=5,c=1,r=1,C=1;\x1b\\" });
}

test "a chunked transfer places on the screen it completes on" {
    try one("chunk-screen", 8, 3, "\x1b_Ga=T,f=32,s=1,v=1,i=5,c=1,r=1,C=1,m=1;/wAA\x1b\\\x1b[?47h\x1b_Gm=0;/w==\x1b\\\x1b[?47l\x1b[2J");
}

test "a dead sixel replaces the image with its assigned id" {
    try one("sixel-id", 8, 3, "\x1b_Ga=T,f=32,s=1,v=1,i=1,c=1,r=1,C=1;" ++ red_px ++ "\x1b\\\x1b[?47h\x1bPq~\x1b\\\x1b[2J\x1b[?47l");
}

test "malformed UTF-8 swallows the character REP would repeat" {
    try runCase("bad-utf8-rep", 8, 3, &.{ "X", "\x1b[?7l\xc2A\r\x1b[2J\x1b[b" });
}

test "combined alt-screen parameters apply in order" {
    try one("alt-params", 8, 3, "\x1b[?47hA\x1b[?47l\x1b[?47;1049h");
}

test "an invalid DECSTBM keeps the region" {
    try one("bad-decstbm", 8, 3, "\x1b[2;3r\x1b[1;4rA\n\n\n\n\n");
}

test "SGR 0 clears the underline color" {
    try one("ul-color", 8, 3, "\x1b[58;2;1;2;3m\x1b[m\x1b[2J");
}
