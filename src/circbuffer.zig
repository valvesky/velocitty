//! Mirrored circular buffer for firehose PTY input.
//!
//! The ring is a tail window: new bytes overwrite the oldest when full.
//! A kernel page mapping (when capacity is page-aligned) makes wrap one
//! contiguous view, so a read/write of length <= capacity never splits.
//! `parsed` is how far the prepass has walked; unread bytes stay so resize
//! can rebuild. Overflow drops the oldest and resyncs `parsed`.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;

const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
const Mask = std.meta.Int(.unsigned, vec_len);

comptime {
    assert(vec_len <= 64);
}

pub const line_max = 256;

pub const Line = struct {
    off: u64,
    len: u32,
};

pub const CircBuffer = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    capacity: usize,
    mapped: bool,
    rd: u64 = 0,
    wr: u64 = 0,
    parsed: u64 = 0,
    /// Bumped on `clear` so consumers can drop absolute offsets.
    epoch: u64 = 0,
    lines: []Line,
    line_i: u32 = 0,
    line_n: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!CircBuffer {
        assert(capacity > 0);
        assert(std.math.isPowerOfTwo(capacity));
        const lines = try allocator.alloc(Line, line_max);
        errdefer allocator.free(lines);
        if (mapMirror(capacity)) |storage| {
            return .{
                .allocator = allocator,
                .storage = storage,
                .capacity = capacity,
                .mapped = true,
                .lines = lines,
            };
        }
        const storage = try allocator.alloc(u8, capacity * 2);
        return .{
            .allocator = allocator,
            .storage = storage,
            .capacity = capacity,
            .mapped = false,
            .lines = lines,
        };
    }

    pub fn deinit(self: *CircBuffer) void {
        if (self.mapped) {
            switch (builtin.os.tag) {
                .linux => posix.munmap(@alignCast(self.storage)),
                else => unreachable,
            }
        } else {
            self.allocator.free(self.storage);
        }
        self.allocator.free(self.lines);
        self.* = undefined;
    }

    pub fn available(self: *const CircBuffer) usize {
        return @intCast(self.wr - self.rd);
    }

    pub fn tail(self: *const CircBuffer) usize {
        return self.index(self.rd);
    }

    /// Contiguous unread bytes. Valid until the next write, consume, or deinit.
    pub fn peek(self: *const CircBuffer) []const u8 {
        const n = self.available();
        if (n == 0) return &.{};
        const t = self.index(self.rd);
        return self.storage[t .. t + n];
    }

    /// Contiguous unparsed suffix of `peek`.
    pub fn unparsed(self: *const CircBuffer) []const u8 {
        const view = self.peek();
        if (self.parsed <= self.rd) return view;
        const skip: usize = @intCast(self.parsed - self.rd);
        return view[skip..];
    }

    /// Contiguous writable window of `capacity` bytes (wrap is one view).
    pub fn spare(self: *CircBuffer) []u8 {
        const off = self.index(self.wr);
        return self.storage[off .. off + self.capacity];
    }

    pub fn consume(self: *CircBuffer, n: usize) void {
        assert(n <= self.available());
        self.rd += n;
        if (self.parsed < self.rd) self.parsed = self.rd;
        self.dropLines();
    }

    pub fn advanceParsed(self: *CircBuffer, n: usize) void {
        assert(self.parsed + n <= self.wr);
        self.parsed += n;
    }

    pub fn clear(self: *CircBuffer) void {
        self.rd = 0;
        self.wr = 0;
        self.parsed = 0;
        self.epoch += 1;
        self.line_i = 0;
        self.line_n = 0;
    }

    pub fn resetParsed(self: *CircBuffer) void {
        self.parsed = self.rd;
        self.line_i = 0;
        self.line_n = 0;
    }

    /// Always accepts `data`. Oldest unread bytes are dropped if needed.
    pub fn write(self: *CircBuffer, data: []const u8) void {
        var src = data;
        if (src.len >= self.capacity) {
            src = src[src.len - self.capacity ..];
        }
        if (src.len == 0) return;
        @memcpy(self.spare()[0..src.len], src);
        self.commit(src.len);
    }

    /// After filling `spare()[0..n]`, mirror (heap path) and bump `wr`.
    pub fn commit(self: *CircBuffer, n: usize) void {
        assert(n <= self.capacity);
        if (n == 0) return;
        if (!self.mapped) self.syncMirror(self.index(self.wr), n);
        self.produce(n);
    }

    pub fn produce(self: *CircBuffer, n: usize) void {
        if (n == 0) return;
        if (self.wr - self.rd + n > self.capacity) {
            self.rd = self.wr + n - self.capacity;
            if (self.parsed < self.rd) {
                self.parsed = self.rd;
                self.resync();
            }
            self.dropLines();
        }
        self.wr += n;
    }

    pub fn lastLines(self: *const CircBuffer, n: u32) LineView {
        var count = self.line_n;
        if (n != 0 and n < count) count = n;
        return .{ .buf = self, .i0 = self.line_n - count, .n = count };
    }

    pub fn pushLine(self: *CircBuffer, off: u64, n: u32) void {
        if (n == 0) return;
        if (self.line_n != 0) {
            const last = &self.lines[(self.line_i + self.line_n - 1) % line_max];
            if (last.off + last.len == off and last.len != 0) {
                const last_byte = self.storage[self.index(last.off + last.len - 1)];
                if (last_byte != '\n') {
                    last.len += n;
                    return;
                }
            }
        }
        if (self.line_n == line_max) {
            self.line_i += 1;
            if (self.line_i == line_max) self.line_i = 0;
            self.line_n -= 1;
        }
        const slot = (self.line_i + self.line_n) % line_max;
        self.lines[slot] = .{
            .off = off,
            .len = n,
        };
        self.line_n += 1;
    }

    fn index(self: *const CircBuffer, abs: u64) usize {
        return @intCast(abs & (self.capacity - 1));
    }

    fn syncMirror(self: *CircBuffer, off: usize, n: usize) void {
        const cap = self.capacity;
        const first = @min(n, cap - off);
        @memcpy(self.storage[off + cap ..][0..first], self.storage[off..][0..first]);
        const rest = n - first;
        if (rest == 0) return;
        @memcpy(self.storage[0..rest], self.storage[cap..][0..rest]);
    }

    fn dropLines(self: *CircBuffer) void {
        while (self.line_n != 0) {
            const line = self.lines[self.line_i];
            if (line.off >= self.rd) break;
            self.line_i += 1;
            if (self.line_i == line_max) self.line_i = 0;
            self.line_n -= 1;
        }
    }

    fn resync(self: *CircBuffer) void {
        const view = self.peek();
        const V = @Vector(vec_len, u8);
        const esc: V = @splat(0x1b);
        var i: usize = 0;
        while (i + vec_len <= view.len) : (i += vec_len) {
            const chunk: V = view[i..][0..vec_len].*;
            const bits: Mask = @bitCast(@as(@Vector(vec_len, u1), @intFromBool(chunk == esc)));
            if (bits != 0) {
                self.parsed = self.rd + i + @ctz(bits);
                return;
            }
        }
        while (i < view.len) : (i += 1) {
            if (view[i] == 0x1b) {
                self.parsed = self.rd + i;
                return;
            }
        }
    }
};

pub const LineView = struct {
    buf: *const CircBuffer,
    i0: u32,
    n: u32,

    pub fn get(self: LineView, i: u32) Line {
        assert(i < self.n);
        return self.buf.lines[(self.buf.line_i + self.i0 + i) % line_max];
    }
};

fn mapMirror(size: usize) ?[]u8 {
    if (builtin.os.tag != .linux) return null;
    if (size == 0 or size % std.heap.pageSize() != 0) return null;
    const fd = posix.memfd_create("zt-ring", 0) catch return null;
    defer _ = std.os.linux.close(fd);
    if (std.os.linux.errno(std.os.linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return null;
    const none = posix.mmap(
        null,
        size * 2,
        .{},
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return null;
    const half: [*]align(std.heap.page_size_min) u8 = @ptrCast(none.ptr);
    _ = posix.mmap(
        half,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED, .FIXED = true },
        fd,
        0,
    ) catch {
        posix.munmap(none);
        return null;
    };
    const rest: [*]align(std.heap.page_size_min) u8 = @alignCast(half + size);
    _ = posix.mmap(
        rest,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED, .FIXED = true },
        fd,
        0,
    ) catch {
        posix.munmap(none);
        return null;
    };
    return none;
}

test "write peek consume" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.init(gpa, 8);
    defer buf.deinit();
    buf.write("abcd");
    try std.testing.expectEqualStrings("abcd", buf.peek());
    buf.consume(2);
    try std.testing.expectEqualStrings("cd", buf.peek());
}

test "wrap is contiguous" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.init(gpa, 8);
    defer buf.deinit();
    buf.write("abcd");
    buf.consume(2);
    buf.write("efghij");
    try std.testing.expectEqualStrings("cdefghij", buf.peek());
}

test "firehose keeps newest" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.init(gpa, 8);
    defer buf.deinit();
    buf.write("1234567");
    buf.write("abc");
    try std.testing.expectEqualStrings("34567abc", buf.peek());
    buf.write("0123456789");
    try std.testing.expectEqualStrings("23456789", buf.peek());
}

test "spare commit wrap" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.init(gpa, 8);
    defer buf.deinit();
    buf.write("abcd");
    buf.consume(2);
    const dest = buf.spare();
    @memcpy(dest[0..6], "efghij");
    buf.commit(6);
    try std.testing.expectEqualStrings("cdefghij", buf.peek());
}

test "parsed does not rescan" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.init(gpa, 8);
    defer buf.deinit();
    buf.write("abcd");
    try std.testing.expectEqualStrings("abcd", buf.unparsed());
    buf.advanceParsed(2);
    try std.testing.expectEqualStrings("cd", buf.unparsed());
    buf.write("ef");
    try std.testing.expectEqualStrings("cdef", buf.unparsed());
}

test "mmap wrap is one view" {
    const gpa = std.testing.allocator;
    const cap = std.heap.pageSize();
    var buf = try CircBuffer.init(gpa, cap);
    defer buf.deinit();
    if (!buf.mapped) return;
    @memset(buf.spare()[0 .. cap / 2], 'a');
    buf.commit(cap / 2);
    buf.consume(cap / 2);
    @memset(buf.spare()[0..cap], 'b');
    buf.commit(cap);
    const view = buf.peek();
    try std.testing.expectEqual(cap, view.len);
    try std.testing.expectEqual(@as(u8, 'b'), view[0]);
    try std.testing.expectEqual(@as(u8, 'b'), view[view.len - 1]);
}
