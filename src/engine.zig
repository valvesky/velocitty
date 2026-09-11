//! Ingest / EAGAIN refresh pipeline.

const std = @import("std");
const assert = std.debug.assert;
const circbuffer = @import("circbuffer.zig");
const CircBuffer = circbuffer.CircBuffer;
const Preparse = @import("preparse.zig");
const Runs = @import("runs.zig");
const Term = @import("term.zig");
const Draw = @import("draw.zig");
const Type = @import("type.zig");
const Select = @import("select.zig");

pub const PumpStat = struct {
    bytes_in: usize = 0,
    frames: u32 = 0,
    consumed: usize = 0,
};

const sync_timeout_ns: i128 = 250_000_000;
/// 64 × 4 KiB pages. Same window as vt `RING_PAGES`; wrap is one mmap view.
pub const default_buf_cap: usize = 64 * 4096;
const run_cap: usize = 1024;

pub const Options = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    buf_cap: usize = default_buf_cap,
    cell_w: u32 = 8,
    cell_h: u32 = 16,
    size_px: f32 = 16,
    hz: u32 = 30,
    scrollback: u32 = Term.default_scrollback,
    scheme: Term.Scheme = .{},
    whitelist: bool = false,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    hz: u32,
    whitelist: bool,
    last_refresh_ns: ?i128,
    buffer: CircBuffer,
    screen: Term.Screen,
    frame: Draw.Frame,
    cell_w: u32,
    cell_h: u32,
    size_px: f32,
    base_cell_w: u32,
    base_cell_h: u32,
    base_size_px: f32,
    type_ctx: ?*Type.Context = null,
    arena: std.heap.ArenaAllocator,
    runs: std.ArrayList(Runs.Run),
    queries: Term.Queries = .{},
    sync_hold_ns: ?i128 = null,
    /// Absolute ring offset already fed into `screen`. Live TUI state lives on
    /// the grid; the ring is only a tail of unread bytes plus resize replay.
    fed: u64 = 0,
    fed_epoch: u64 = 0,
    query_at: u64 = 0,
    query_epoch: u64 = 0,
    selection: Select.State = .{},

    pub fn init(allocator: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Engine {
        assert(options.hz > 0);
        assert(options.size_px > 0);
        var buffer = try CircBuffer.init(allocator, options.buf_cap);
        errdefer buffer.deinit();
        var screen = try Term.Screen.initWithScheme(allocator, options.cols, options.rows, options.scrollback, options.scheme);
        errdefer screen.deinit();
        var frame = try Draw.Frame.init(
            allocator,
            @as(u32, options.cols) * options.cell_w,
            @as(u32, options.rows) * options.cell_h,
        );
        errdefer frame.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var runs: std.ArrayList(Runs.Run) = .empty;
        try runs.ensureTotalCapacity(arena.allocator(), run_cap);
        return .{
            .allocator = allocator,
            .hz = options.hz,
            .whitelist = options.whitelist,
            .last_refresh_ns = null,
            .buffer = buffer,
            .screen = screen,
            .frame = frame,
            .cell_w = options.cell_w,
            .cell_h = options.cell_h,
            .size_px = options.size_px,
            .base_cell_w = options.cell_w,
            .base_cell_h = options.cell_h,
            .base_size_px = options.size_px,
            .arena = arena,
            .runs = runs,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.arena.deinit();
        self.frame.deinit();
        self.screen.deinit();
        self.buffer.deinit();
        self.* = undefined;
    }

    pub fn setCellMetrics(self: *Engine, cell_w: u32, cell_h: u32, size_px: f32) bool {
        assert(cell_w > 0);
        assert(cell_h > 0);
        assert(size_px > 0);
        if (self.cell_w == cell_w and self.cell_h == cell_h and self.size_px == size_px) return false;
        self.cell_w = cell_w;
        self.cell_h = cell_h;
        self.size_px = size_px;
        if (self.type_ctx) |ctx| ctx.clearAtlas();
        return true;
    }

    pub fn resize(self: *Engine, cols: u16, rows: u16) std.mem.Allocator.Error!void {
        assert(cols > 0);
        assert(rows > 0);
        try self.screen.resize(cols, rows);
        self.selection.clear();
        try self.frame.resize(
            @as(u32, cols) * self.cell_w,
            @as(u32, rows) * self.cell_h,
        );
        self.buffer.resetParsed();
        self.fed = self.buffer.rd;
        self.fed_epoch = self.buffer.epoch;
        try self.refresh();
    }

    pub fn ingest(self: *Engine, bytes: []const u8) void {
        var src = bytes;
        while (src.len > 0) {
            if (self.buffer.available() == self.buffer.capacity) {
                if (self.screen.altScreen()) {
                    self.flushLive() catch {
                        self.buffer.write(src);
                        return;
                    };
                }
                if (self.buffer.available() == self.buffer.capacity) {
                    self.buffer.write(src);
                    return;
                }
            }
            const space = self.buffer.capacity - self.buffer.available();
            const n = @min(space, src.len);
            self.buffer.write(src[0..n]);
            src = src[n..];
        }
    }

    pub fn takeReports(self: *Engine, out: []u8) usize {
        if (!self.queries.pending()) return 0;
        return self.queries.write(
            &self.screen,
            self.frame.width,
            self.frame.height,
            self.cell_w,
            self.cell_h,
            out,
        );
    }

    /// Refresh only when a frame period has elapsed. Matches the EAGAIN 1/hz rule.
    /// CSI ? 2026 h holds the frame until 2026 l or `sync_timeout_ns`.
    /// The ring stays at most `buf_cap` (256 KiB default) and is drained after feed.
    pub fn onWouldBlock(self: *Engine, now_ns: i128) std.mem.Allocator.Error!bool {
        if (self.buffer.available() == 0) return false;
        self.addNewQueries();
        if (self.syncHeld(now_ns)) return false;
        const force = self.queries.sync_flush;
        self.queries.sync_flush = false;
        if (!force) {
            const period: i128 = @divTrunc(1_000_000_000, self.hz);
            if (self.last_refresh_ns) |last| {
                if (now_ns - last < period) return false;
            }
        }
        try self.refresh();
        self.last_refresh_ns = now_ns;
        return true;
    }

    fn syncHeld(self: *Engine, now_ns: i128) bool {
        if (self.queries.sync_depth == 0) {
            self.sync_hold_ns = null;
            return false;
        }
        if (self.sync_hold_ns) |start| {
            if (now_ns - start >= sync_timeout_ns) return false;
        } else {
            self.sync_hold_ns = now_ns;
        }
        return true;
    }

    /// Drain `reader` until a zero-length slice (EAGAIN / EOF).
    ///
    /// Firehose: memcpy into the ring only. Overflow overwrites the oldest
    /// unread bytes. Preparse / queries / feed / paint run on EAGAIN if 1/hz
    /// has passed — not per chunk, not when the buffer is full.
    /// Alt screen: flush the ring into the grid before overflow so in-place
    /// frames are not truncated, and paint at hz while still readable.
    ///
    /// `reader.read(buf)` returns the filled slice. `clock.now()` is ns.
    /// `ctx.onFrame(*Engine)` is invoked after each refresh.
    pub fn pump(self: *Engine, reader: anytype, clock: anytype, ctx: anytype) !PumpStat {
        var stat: PumpStat = .{};
        while (true) {
            try self.flushLiveIfFull();
            var space = self.buffer.capacity - self.buffer.available();
            if (space == 0) space = self.buffer.capacity;
            const dest = self.buffer.spare()[0..space];
            const chunk = try reader.read(dest);
            if (chunk.len == 0) break;
            self.buffer.commit(chunk.len);
            stat.bytes_in += chunk.len;
            if (self.screen.altScreen()) {
                try self.noteFrame(clock.now(), &stat, ctx);
            }
        }
        try self.noteFrame(clock.now(), &stat, ctx);
        return stat;
    }

    fn liveInput(self: *const Engine) bool {
        if (self.screen.altScreen()) return true;
        return hasInPlaceEsc(self.buffer.peek());
    }

    /// Apply live TUI bytes to the grid without painting. Firehose text is left
    /// in the ring so `lastLines` can still take the newest rows.
    fn flushLive(self: *Engine) std.mem.Allocator.Error!void {
        if (self.buffer.available() == 0) return;
        if (!self.liveInput()) return;
        try self.feedNew();
        self.drainRing();
    }

    fn flushLiveIfFull(self: *Engine) std.mem.Allocator.Error!void {
        if (self.buffer.available() < self.buffer.capacity) return;
        if (!self.screen.altScreen()) return;
        try self.flushLive();
    }

    /// Scan only bytes not yet seen. Firehose overwrite drops unscanned bytes.
    fn addNewQueries(self: *Engine) void {
        if (self.query_epoch != self.buffer.epoch or self.query_at < self.buffer.rd) {
            self.query_at = self.buffer.rd;
            self.query_epoch = self.buffer.epoch;
        }
        if (self.query_at >= self.buffer.wr) return;
        const peek = self.buffer.peek();
        const off: usize = @intCast(self.query_at - self.buffer.rd);
        if (off < peek.len) self.queries.add(peek[off..]);
        self.query_at = self.buffer.wr;
    }

    fn feedNew(self: *Engine) std.mem.Allocator.Error!void {
        if (self.fed_epoch != self.buffer.epoch or self.fed < self.buffer.rd or self.fed > self.buffer.wr) {
            self.fed = self.buffer.rd;
            self.fed_epoch = self.buffer.epoch;
        }
        _ = Preparse.consume(&self.buffer, self.whitelist);
        // In-place TUIs (CUP/ED/SGR, alt screen) must not drop earlier lines:
        // home/erase often sit on extra newline-separated rows above the last
        // `rows` of a visualizer frame. Plain firehose still takes the tail.
        const take: u32 = if (self.liveInput()) circbuffer.line_max else self.screen.rows;
        const view = self.buffer.lastLines(take);
        if (view.n == 0) {
            self.fed = self.buffer.parsed;
            return;
        }
        const peek = self.buffer.peek();
        var li: u32 = 0;
        while (li < view.n) : (li += 1) {
            try self.feedLine(peek, view.get(li));
        }
        self.fed = self.buffer.parsed;
    }

    fn feedLine(self: *Engine, peek: []const u8, line: circbuffer.Line) std.mem.Allocator.Error!void {
        if (line.off < self.buffer.rd) return;
        const off: usize = @intCast(line.off - self.buffer.rd);
        if (off + line.len > peek.len) return;
        const slice = peek[off .. off + line.len];
        self.runs.clearRetainingCapacity();
        try Runs.split(self.arena.allocator(), slice, &self.runs);
        self.screen.feed(self.runs.items, slice);
        if (lineEndedWithNl(&self.buffer, line)) self.screen.lineFeed();
    }

    /// Drop unread bytes and resync `fed`. Use instead of `buffer.clear()`.
    pub fn rewindInput(self: *Engine) void {
        self.buffer.clear();
        self.fed = self.buffer.rd;
        self.fed_epoch = self.buffer.epoch;
        self.query_at = self.buffer.rd;
        self.query_epoch = self.buffer.epoch;
    }

    fn drainRing(self: *Engine) void {
        if (self.fed_epoch != self.buffer.epoch or self.buffer.parsed < self.buffer.rd) {
            self.fed = self.buffer.rd;
            self.fed_epoch = self.buffer.epoch;
            return;
        }
        const n: usize = @intCast(self.buffer.parsed - self.buffer.rd);
        if (n != 0) self.buffer.consume(n);
        self.fed = self.buffer.rd;
        self.fed_epoch = self.buffer.epoch;
    }

    fn noteFrame(self: *Engine, now_ns: i128, stat: *PumpStat, ctx: anytype) !void {
        const n = self.buffer.available();
        if (!try self.onWouldBlock(now_ns)) return;
        stat.frames += 1;
        stat.consumed += n;
        ctx.onFrame(self);
    }

    pub fn scrollBy(self: *Engine, delta: i32) void {
        self.screen.scrollBy(delta);
        self.redraw();
        self.screen.clearDirty();
    }

    pub fn selectedTextAlloc(self: *Engine) std.mem.Allocator.Error![]u8 {
        return Select.copyAlloc(self.allocator, &self.screen, self.selection);
    }

    pub fn redraw(self: *Engine) void {
        self.frame.renderSel(&self.screen, self.cell_w, self.cell_h, self.type_ctx, self.size_px, self.selection);
    }

    pub fn refresh(self: *Engine) std.mem.Allocator.Error!void {
        self.addNewQueries();
        try self.feedNew();
        self.drainRing();
        self.redraw();
        self.screen.clearDirty();
    }
};

fn hasInPlaceEsc(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        const rel = std.mem.indexOfScalar(u8, bytes[i..], 0x1b) orelse return false;
        i += rel;
        const seq = Preparse.parseSeq(bytes, i);
        if (!seq.complete) break;
        if (seq.class == .csi) {
            const final = bytes[seq.end - 1];
            switch (final) {
                'H', 'f', 'J', 'K', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'd', 'r', 'L', 'M', 'S', 'T', '@', 'P', 'X' => return true,
                'h', 'l' => {
                    const body = bytes[seq.start..seq.end];
                    if (std.mem.indexOf(u8, body, "1049") != null) return true;
                    if (std.mem.indexOf(u8, body, "1047") != null) return true;
                    if (std.mem.indexOf(u8, body, "?47") != null) return true;
                },
                else => {},
            }
        }
        i = seq.end;
    }
    return false;
}

fn lineEndedWithNl(buf: *const CircBuffer, line: circbuffer.Line) bool {
    const abs = line.off + line.len;
    if (abs >= buf.parsed or abs < buf.rd) return false;
    const peek = buf.peek();
    const i: usize = @intCast(abs - buf.rd);
    if (i >= peek.len) return false;
    return peek[i] == '\n';
}

test "kitty rgb pixel is drawn" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 4,
        .rows = 2,
        .buf_cap = 256,
        .cell_w = 4,
        .cell_h = 4,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("\x1b[?25l\x1b_Ga=T,f=24,s=1,v=1,C=1;/wAA\x1b\\");
    try engine.refresh();
    try std.testing.expectEqual(Draw.Frame.pack(.{ .r = 255, .g = 0, .b = 0 }), engine.frame.pixels[0]);
    try std.testing.expect(engine.screen.kitty.placements.items.len == 1);
}

test "kitty png pixel is drawn" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 4,
        .rows = 2,
        .buf_cap = 256,
        .cell_w = 4,
        .cell_h = 4,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("\x1b[?25l\x1b_Ga=T,f=100,C=1,c=1,r=1,i=9;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC\x1b\\");
    try engine.refresh();
    try std.testing.expectEqual(@as(usize, 1), engine.screen.kitty.placements.items.len);
    try std.testing.expectEqual(Draw.Frame.pack(.{ .r = 255, .g = 0, .b = 0 }), engine.frame.pixels[0]);
}

test "kitty png survives 2026 sync on a small ring" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 4,
        .rows = 2,
        .buf_cap = 4096,
        .cell_w = 4,
        .cell_h = 4,
        .hz = 60,
    });
    defer engine.deinit();

    const w: u32 = 16;
    const h: u32 = 16;
    var rgb: [16 * 16 * 3]u8 = undefined;
    for (0..w * h) |i| {
        rgb[i * 3 + 0] = 255;
        rgb[i * 3 + 1] = 0;
        rgb[i * 3 + 2] = 0;
    }
    var b64_buf: [1024]u8 = undefined;
    const b64_len = std.base64.standard.Encoder.calcSize(rgb.len);
    const b64 = std.base64.standard.Encoder.encode(b64_buf[0..b64_len], &rgb);

    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(gpa);
    try seq.appendSlice(gpa, "\x1b[?2026h\x1b[?25l");
    const piece = 64;
    var off: usize = 0;
    var first = true;
    while (off < b64.len) {
        const end = @min(off + piece, b64.len);
        const last = end == b64.len;
        if (first) {
            try seq.appendSlice(gpa, "\x1b_Ga=T,f=24,s=16,v=16,C=1,i=2,m=1;");
            first = false;
        } else if (last) {
            try seq.appendSlice(gpa, "\x1b_Gm=0;");
        } else {
            try seq.appendSlice(gpa, "\x1b_Gm=1;");
        }
        try seq.appendSlice(gpa, b64[off..end]);
        try seq.appendSlice(gpa, "\x1b\\");
        off = end;
    }
    try seq.appendSlice(gpa, "\x1b[?2026l");

    const Src = struct {
        bytes: []const u8,
        off: usize = 0,
        pub fn read(self: *@This(), buf: []u8) error{}![]u8 {
            const n = @min(buf.len, self.bytes.len - self.off);
            @memcpy(buf[0..n], self.bytes[self.off..][0..n]);
            self.off += n;
            return buf[0..n];
        }
        pub fn now(_: *const @This()) i128 {
            return 0;
        }
    };
    const Tap = struct {
        pub fn onFrame(_: @This(), _: *Engine) void {}
    };
    var src = Src{ .bytes = seq.items };
    _ = try engine.pump(&src, &src, Tap{});
    try std.testing.expectEqual(@as(usize, 1), engine.screen.kitty.placements.items.len);
    try std.testing.expectEqual(Draw.Frame.pack(.{ .r = 255, .g = 0, .b = 0 }), engine.frame.pixels[0]);
}

test "ingest refresh" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("ab\ncd");
    try std.testing.expect(try engine.onWouldBlock(1_000_000_000));
    try std.testing.expectEqual(@as(u21, 'a'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), engine.screen.cell(1, 0).codepoint);
    try std.testing.expect(!(try engine.onWouldBlock(1_000_000_000)));
    try engine.refresh();
    try std.testing.expectEqual(@as(u21, 'a'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), engine.screen.cell(0, 1).codepoint);
    try std.testing.expect(!(try engine.onWouldBlock(1_000_000_000 + 17_000_000)));
}

test "rewindInput resyncs fed" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("ab");
    try engine.refresh();
    engine.rewindInput();
    engine.screen.clear();
    engine.ingest("XY");
    try engine.refresh();
    try std.testing.expectEqual(@as(u21, 'X'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'Y'), engine.screen.cell(0, 1).codepoint);
}

test "feedNew clamps stale fed after buffer.clear" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("ab");
    try engine.refresh();
    engine.buffer.clear();
    engine.screen.clear();
    engine.ingest("XY");
    try engine.refresh();
    try std.testing.expectEqual(@as(u21, 'X'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'Y'), engine.screen.cell(0, 1).codepoint);
}

test "alt screen refresh" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("AB\x1b[?1049hXY");
    try engine.refresh();
    try std.testing.expect(engine.screen.altScreen());
    try std.testing.expectEqual(@as(u21, 'X'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'Y'), engine.screen.cell(0, 1).codepoint);
    engine.ingest("\x1b[?1049l");
    try engine.refresh();
    try std.testing.expect(!engine.screen.altScreen());
    try std.testing.expectEqual(@as(u21, 'A'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), engine.screen.cell(0, 1).codepoint);
}

test "resize reflows" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("abcdefghij");
    try engine.resize(4, 3);
    try std.testing.expectEqual(@as(u16, 4), engine.screen.cols);
    try std.testing.expectEqual(@as(u16, 3), engine.screen.rows);
    try std.testing.expectEqual(@as(u32, 8), engine.frame.width);
    try std.testing.expectEqual(@as(u32, 6), engine.frame.height);
    try std.testing.expectEqual(@as(u21, 'a'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), engine.screen.cell(1, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'i'), engine.screen.cell(2, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'j'), engine.screen.cell(2, 1).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), engine.screen.cell(2, 2).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), engine.screen.cell(2, 3).codepoint);
}

test "resize reflow short remainder does not copy previous row" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 4,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("AAAABBBBCCCC\nDDDDEEEEFF\n");
    try engine.resize(4, 8);
    const row = struct {
        fn eq(screen: *const Term.Screen, r: u16, expect: []const u21) !void {
            for (expect, 0..) |cp, c| {
                try std.testing.expectEqual(cp, screen.cell(r, @intCast(c)).codepoint);
            }
        }
    };
    try row.eq(&engine.screen, 0, &.{ 'A', 'A', 'A', 'A' });
    try row.eq(&engine.screen, 1, &.{ 'B', 'B', 'B', 'B' });
    try row.eq(&engine.screen, 2, &.{ 'C', 'C', 'C', 'C' });
    try row.eq(&engine.screen, 3, &.{ 'D', 'D', 'D', 'D' });
    try row.eq(&engine.screen, 4, &.{ 'E', 'E', 'E', 'E' });
    try row.eq(&engine.screen, 5, &.{ 'F', 'F', ' ', ' ' });
    try row.eq(&engine.screen, 6, &.{ ' ', ' ', ' ', ' ' });
}

test "device reports from ingest" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("\x1b[2;3H\x1b[6n\x1b[c");
    try engine.refresh();
    var buf: [64]u8 = undefined;
    const n = engine.takeReports(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1b[2;3R") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1b[?64;1;2;6;9;15;16;21;22c") != null);
    try std.testing.expectEqual(@as(usize, 0), engine.takeReports(&buf));
}

test "incremental feed does not reprint" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("X");
    try engine.refresh();
    engine.ingest("Y");
    try engine.refresh();
    try std.testing.expectEqual(@as(u21, 'X'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'Y'), engine.screen.cell(0, 1).codepoint);
}

test "resize reflow cols 1" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("ab\ncd");
    try engine.resize(1, 6);
    try std.testing.expectEqual(@as(u21, 'a'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), engine.screen.cell(1, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), engine.screen.cell(2, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), engine.screen.cell(3, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), engine.screen.cell(4, 0).codepoint);
}

test "sync 2026 holds then flushes" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("\x1b[?2026hX");
    try std.testing.expect(!(try engine.onWouldBlock(1)));
    try std.testing.expectEqual(@as(u21, ' '), engine.screen.cell(0, 0).codepoint);
    engine.ingest("\x1b[?2026l");
    try std.testing.expect(try engine.onWouldBlock(2));
    try std.testing.expectEqual(@as(u21, 'X'), engine.screen.cell(0, 0).codepoint);
}

test "sync 2026 timeout paints" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("\x1b[?2026hY");
    try std.testing.expect(!(try engine.onWouldBlock(10)));
    try std.testing.expect(try engine.onWouldBlock(10 + sync_timeout_ns));
    try std.testing.expectEqual(@as(u21, 'Y'), engine.screen.cell(0, 0).codepoint);
}

test "in-place updates survive ring overflow" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 4,
        .rows = 2,
        .buf_cap = 32,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("\x1b[?1049h\x1b[HABCD\x1b[2;1HEFGH");
    try engine.refresh();
    try std.testing.expectEqual(@as(u21, 'A'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), engine.screen.cell(1, 0).codepoint);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        engine.ingest("\x1b[1;1HXXXX");
        try engine.refresh();
    }
    try std.testing.expectEqual(@as(u21, 'X'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), engine.screen.cell(1, 0).codepoint);
}

test "visible lines only last rows" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 4,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("A\nB\nC\nD");
    try engine.refresh();
    try std.testing.expectEqual(@as(u21, 'C'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), engine.screen.cell(1, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 0), engine.screen.scrollMax());
}

test "drainRing keeps incomplete ESC" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
        .whitelist = true,
    });
    defer engine.deinit();
    engine.ingest("\x1b[31");
    try engine.refresh();
    try std.testing.expect(engine.buffer.available() > 0);
    engine.ingest("mX");
    try engine.refresh();
    try std.testing.expectEqual(@as(u21, 'X'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u8, 170), engine.screen.cell(0, 0).fg.r);
    try std.testing.expectEqual(@as(u8, 0), engine.screen.cell(0, 0).fg.g);
}

/// ncmpcpp-style visualizer: home/erase on extra lines, then `rows` of bars.
/// Digit `('0'+(frame+row)%10)` fills each row so a missed refresh is obvious.
fn visualizerFrame(buf: []u8, frame: u32, cols: u16, rows: u16) []u8 {
    var n: usize = 0;
    const prefix = "\x1b[s\n\x1b[u\n\x1b[H\n\x1b[2J\n\x1b[H";
    @memcpy(buf[n..][0..prefix.len], prefix);
    n += prefix.len;
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        const color: u8 = @intCast(1 + (frame + r) % 15);
        const ch: u8 = '0' + @as(u8, @intCast((frame + r) % 10));
        const head = std.fmt.bufPrint(buf[n..], "\x1b[38;5;{d}m", .{color}) catch unreachable;
        n += head.len;
        var c: u16 = 0;
        while (c < cols) : (c += 1) {
            buf[n] = ch;
            n += 1;
        }
        const tail = "\x1b[K";
        @memcpy(buf[n..][0..tail.len], tail);
        n += tail.len;
        if (r + 1 < rows) {
            buf[n] = '\n';
            n += 1;
        }
    }
    return buf[0..n];
}

fn expectVisualizer(screen: *const Term.Screen, frame: u32) !void {
    var r: u16 = 0;
    while (r < screen.rows) : (r += 1) {
        const ch: u21 = '0' + @as(u21, @intCast((frame + r) % 10));
        const color = Term.vga_palette[1 + (frame + r) % 15];
        var c: u16 = 0;
        while (c < screen.cols) : (c += 1) {
            const cell = screen.cell(r, c);
            try std.testing.expectEqual(ch, cell.codepoint);
            try std.testing.expectEqual(color.r, cell.fg.r);
            try std.testing.expectEqual(color.g, cell.fg.g);
            try std.testing.expectEqual(color.b, cell.fg.b);
        }
    }
}

test "visualizer in-place frames update every row" {
    const gpa = std.testing.allocator;
    const cols: u16 = 8;
    const rows: u16 = 4;
    var engine = try Engine.init(gpa, .{
        .cols = cols,
        .rows = rows,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
        .whitelist = true,
    });
    defer engine.deinit();
    engine.ingest("\x1b[?25l\x1b[?1049h");
    try engine.refresh();
    var buf: [512]u8 = undefined;
    var frame: u32 = 0;
    while (frame < 32) : (frame += 1) {
        engine.ingest(visualizerFrame(&buf, frame, cols, rows));
        try engine.refresh();
        try expectVisualizer(&engine.screen, frame);
    }
}

test "visualizer frames survive ring overflow in one ingest" {
    const gpa = std.testing.allocator;
    const cols: u16 = 8;
    const rows: u16 = 4;
    var engine = try Engine.init(gpa, .{
        .cols = cols,
        .rows = rows,
        .buf_cap = 32,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
        .whitelist = true,
    });
    defer engine.deinit();
    engine.ingest("\x1b[?25l\x1b[?1049h");
    try engine.refresh();
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(gpa);
    var buf: [512]u8 = undefined;
    var frame: u32 = 0;
    while (frame < 12) : (frame += 1) {
        try seq.appendSlice(gpa, visualizerFrame(&buf, frame, cols, rows));
    }
    engine.ingest(seq.items);
    try engine.refresh();
    try expectVisualizer(&engine.screen, 11);
}

test "visualizer pump with frozen clock still ends on last frame" {
    const gpa = std.testing.allocator;
    const cols: u16 = 8;
    const rows: u16 = 4;
    var engine = try Engine.init(gpa, .{
        .cols = cols,
        .rows = rows,
        .buf_cap = 32,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
        .whitelist = true,
    });
    defer engine.deinit();
    engine.ingest("\x1b[?25l\x1b[?1049h");
    try engine.refresh();
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(gpa);
    var buf: [512]u8 = undefined;
    var frame: u32 = 0;
    while (frame < 12) : (frame += 1) {
        try seq.appendSlice(gpa, visualizerFrame(&buf, frame, cols, rows));
    }
    const Src = struct {
        bytes: []const u8,
        off: usize = 0,
        pub fn read(self: *@This(), dest: []u8) error{}![]u8 {
            const n = @min(dest.len, @min(16, self.bytes.len - self.off));
            @memcpy(dest[0..n], self.bytes[self.off..][0..n]);
            self.off += n;
            return dest[0..n];
        }
        pub fn now(_: *const @This()) i128 {
            return 0;
        }
    };
    const Tap = struct {
        pub fn onFrame(_: @This(), _: *Engine) void {}
    };
    var src = Src{ .bytes = seq.items };
    _ = try engine.pump(&src, &src, Tap{});
    try engine.refresh();
    try expectVisualizer(&engine.screen, 11);
}

test "selected text from visible grid" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    engine.ingest("hello\nworld");
    try engine.refresh();
    engine.selection = Select.State{
        .on = true,
        .a = .{ .col = 0, .row = 0 },
        .b = .{ .col = 4, .row = 1 },
    };
    const text = try engine.selectedTextAlloc();
    defer gpa.free(text);
    try std.testing.expectEqualStrings("hello\nworld", text);
}
