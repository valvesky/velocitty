//! Firehose IO model: ring truncates to 4 KiB, consume/paint only on EAGAIN.

const std = @import("std");
const zt = @import("ZT");

const firehose_bytes: usize = 1 << 30;
const buf_cap: usize = 1 << 12;
const hz: u32 = 30;
const duration_ns: i128 = 2_000_000_000;
const head_mark = "HEAD";
const tail_mark = "TAIL";

const Firehose = struct {
    total: usize,
    off: usize = 0,
    duration_ns: i128,

    pub fn read(self: *Firehose, buf: []u8) error{}![]u8 {
        if (self.off >= self.total) return buf[0..0];
        const n = @min(buf.len, self.total - self.off);
        fill(buf[0..n], self.off, self.total);
        self.off += n;
        return buf[0..n];
    }

    pub fn now(self: *const Firehose) i128 {
        if (self.total == 0) return self.duration_ns;
        return @divTrunc(self.duration_ns * @as(i128, @intCast(self.off)), @as(i128, @intCast(self.total)));
    }
};

const Tap = struct {
    pub fn onFrame(_: @This(), _: *zt.Engine) void {}
};

fn fill(dest: []u8, off: usize, total: usize) void {
    @memset(dest, 'x');
    writeAt(dest, off, 0, head_mark);
    if (total >= tail_mark.len) {
        writeAt(dest, off, total - tail_mark.len, tail_mark);
    }
}

fn writeAt(dest: []u8, dest_off: usize, src_off: usize, bytes: []const u8) void {
    const dest_end = dest_off + dest.len;
    const src_end = src_off + bytes.len;
    const lo = @max(dest_off, src_off);
    const hi = @min(dest_end, src_end);
    if (lo >= hi) return;
    const n = hi - lo;
    @memcpy(dest[lo - dest_off ..][0..n], bytes[lo - src_off ..][0..n]);
}

test "1GB firehose truncates to 4 KiB and paints once on EAGAIN" {
    const gpa = std.testing.allocator;
    var engine = try zt.Engine.init(gpa, .{
        .cols = 80,
        .rows = 24,
        .buf_cap = buf_cap,
        .cell_w = 2,
        .cell_h = 2,
        .hz = hz,
    });
    defer engine.deinit();

    var src = Firehose{
        .total = firehose_bytes,
        .duration_ns = duration_ns,
    };
    const stat = try engine.pump(&src, &src, Tap{});

    try std.testing.expectEqual(firehose_bytes, stat.bytes_in);
    try std.testing.expectEqual(firehose_bytes, src.off);
    try std.testing.expect(engine.buffer.available() <= buf_cap);

    try std.testing.expectEqual(@as(u32, 1), stat.frames);
    try std.testing.expect(stat.consumed <= buf_cap);

    const peek = engine.buffer.peek();
    if (peek.len != 0) {
        try std.testing.expect(!std.mem.startsWith(u8, peek, head_mark));
        try std.testing.expect(std.mem.endsWith(u8, peek, tail_mark));
    }
}
