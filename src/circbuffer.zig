//! Mirrored circular buffer for dealing with firehose PTY input.
//!
//! The mirrored buffer is also responsible for preparsing
//! and splitting the input into lines and then into runs
//! of easy to parse sequences.
//!
//! Keeping everything here guarrantees that the lines and runs
//! indeed point to the correct buffer.
//!
//! Obviously, we want to reduce runtime allocations to close to
//! zero. Runs and Lines are stored in dynamic arrays that only
//! grow and double and size.

const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const posix = std.posix;

const SIMD = @import("simd.zig");

pub const Line = packed struct {
    off: u32,
    len: u32,
    esc: bool,
};

pub const Run = struct {
    pub const Kind = enum {
        c0,
        c1,
        esc,
        csi,
        osc,
        str,
        esc_kitty,
        esc_sixel,
        plain,
        utf8,
    };

    kind: Kind,
    off: u32,
    len: u32,
};

pub const CircBuffer = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    capacity: usize,
    mapped: bool,
    head: u64 = 0,
    tail: u64 = 0,
    /// `head` when an incomplete ESC/CSI/OSC/UTF-8 run was parked at the end.
    /// `pending` stays false until more bytes arrive so we do not spin.
    hold_at_head: u64 = 0,
    epoch: u64 = 0,
    lines: std.ArrayListUnmanaged(Line) = .empty,
    runs: std.ArrayListUnmanaged(Run) = .empty,

    /// Create circular buffer
    pub fn create(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!CircBuffer {
        assert(capacity > 0);
        assert(std.math.isPowerOfTwo(capacity));

        var lines: std.ArrayListUnmanaged(Line) = .empty;
        try lines.ensureTotalCapacity(allocator, 256);
        errdefer lines.deinit(allocator);

        var runs: std.ArrayListUnmanaged(Run) = .empty;
        try runs.ensureTotalCapacity(allocator, 1024);
        errdefer runs.deinit(allocator);

        if (mapMirror(capacity)) |storage| {
            return .{
                .allocator = allocator,
                .storage = storage,
                .capacity = capacity,
                .mapped = true,
                .lines = lines,
                .runs = runs,
            };
        }

        const storage = try allocator.alloc(u8, capacity * 2);
        return .{
            .allocator = allocator,
            .storage = storage,
            .capacity = capacity,
            .mapped = false,
            .lines = lines,
            .runs = runs,
        };
    }

    /// Destroy circular buffer.
    pub fn destroy(self: *CircBuffer) void {
        if (self.mapped) {
            switch (builtin.os.tag) {
                .linux => posix.munmap(@alignCast(self.storage)),
                else => unreachable,
            }
        } else {
            self.allocator.free(self.storage);
        }
        self.lines.deinit(self.allocator);
        self.runs.deinit(self.allocator);
        self.* = undefined;
    }

    /// Consume everything and return runs.
    pub fn consumeAndGetRuns(self: *CircBuffer, nlines: usize) []Run {
        self.consumeAndPreparse();
        if (self.lines.items.len == 0) {
            self.finishConsume(0);
            return &.{};
        }
        const all = nlines >= self.lines.items.len;
        const lines = self.getLastNLines(nlines);
        if (lines.len == 0) {
            self.finishConsume(0);
            return &.{};
        }
        self.splitIntoRuns(lines);
        var held: u32 = 0;
        if (all) held = self.trimIncomplete();
        self.finishConsume(held);
        return self.runs.items;
    }

    pub fn pending(self: *const CircBuffer) bool {
        if (self.head == self.tail) return false;
        if (self.hold_at_head != 0 and self.head == self.hold_at_head) return false;
        return true;
    }

    /// The circular buffer read directly from the PTY using
    /// it's very particular logic.
    ///
    /// 1. We are allowed to truncate data and to delete old data.
    /// That's the purpose of a circular buffer in the first place. 
    /// Meaning that if we recieve firehose input it will be trucated
    /// by this function to the size of the circular buffer. 
    ///
    /// 2. So as to not completely freeze the program, we will
    /// return on EAGAIN IF AND ONLY IF 1/hz has passed. By default
    /// hz should be 30.
    ///
    /// To agents and humans: DO NOT CHANGE THIS COMMENT and do not
    /// break this logic.
    pub const Pump = struct {
        fd: posix.fd_t,
        ctx: *anyopaque,
        tick: *const fn (*anyopaque) void,
    };

    pub fn readPTY(self: *CircBuffer, pty: posix.fd_t, hz: u32) error{Hangup}!void {
        return self.readPTYPump(pty, hz, null);
    }

    /// Same return rules as `readPTY`. `pump` is ticked when its fd wakes during the EAGAIN wait
    /// so window events are not frozen for 1/hz.
    pub fn readPTYPump(self: *CircBuffer, pty: posix.fd_t, hz: u32, pump: ?Pump) error{Hangup}!void {
        const rate: u32 = if (hz == 0) 30 else hz;
        const period_ns: i128 = @divTrunc(1_000_000_000, rate);
        const start_ns = nowNs();
        const mask = self.capacity - 1;

        while (true) {
            const off: usize = @intCast(self.head & mask);
            const dest = self.storage[off..][0..self.capacity];
            const n = posix.read(pty, dest) catch |err| switch (err) {
                error.WouldBlock => {
                    const elapsed = nowNs() - start_ns;
                    if (elapsed >= period_ns) return;
                    // Never poll(0): a readable X fd plus 0ms timeout busy-loops.
                    const remaining_ns = period_ns - elapsed;
                    const timeout_ms: i32 = @intCast(@min(@max(@divTrunc(remaining_ns + 999_999, 1_000_000), 1), 1000));
                    if (pump) |p| {
                        const t0 = nowNs();
                        waitReadable2(pty, p.fd, timeout_ms);
                        p.tick(p.ctx);
                        // Motion/XI floods keep the X fd readable so poll returns
                        // immediately. Sleep on the PTY only for the rest of the
                        // frame instead of spinning at 100% CPU.
                        if (nowNs() - t0 < 200_000) {
                            const elapsed2 = nowNs() - start_ns;
                            if (elapsed2 >= period_ns) return;
                            const rest = period_ns - elapsed2;
                            const rest_ms: i32 = @intCast(@min(@max(@divTrunc(rest + 999_999, 1_000_000), 1), 1000));
                            waitReadable(pty, rest_ms);
                        }
                    } else {
                        waitReadable(pty, timeout_ms);
                    }
                    continue;
                },
                else => return error.Hangup,
            };
            if (n == 0) return error.Hangup;
            self.syncMirror(off, n);
            self.head += n;
        }
    }

    fn syncMirror(self: *CircBuffer, off: usize, n: usize) void {
        if (self.mapped or n == 0) return;
        const cap = self.capacity;
        const a = self.storage;
        const first = @min(n, cap - off);
        if (first != 0) {
            @memcpy(a[off + cap ..][0..first], a[off..][0..first]);
        }
        const rest = n - first;
        if (rest != 0) {
            @memcpy(a[0..rest], a[cap..][0..rest]);
        }
    }

    /// Consume all the bytes. Will be a maximum of the size
    /// of the buffer since data is meant to be truncated.
    /// This function will preparse input into lines.
    ///
    /// Needs a terminal to apply a few "whitelisted"
    /// sequences that could effect the final screen.
    fn consumeAndPreparse(self: *CircBuffer) void {
        assert(self.tail <= self.head);

        // NOTE(vasco): indices are monotonic and keep growing forever
        // therefore we must make sure the head hasn't skipped too far
        // ahead of tail.
        if ((self.head - self.tail) > self.capacity)
            self.tail = self.head - self.capacity;
        splitIntoLines(self);
    }

    fn finishConsume(self: *CircBuffer, held: u32) void {
        if (held == 0 or held > self.head - self.tail) {
            self.tail = self.head;
            self.hold_at_head = 0;
            return;
        }
        self.tail = self.head - held;
        self.hold_at_head = self.head;
    }

    fn trimIncomplete(self: *CircBuffer) u32 {
        if (self.runs.items.len == 0) return 0;
        const last = self.runs.items[self.runs.items.len - 1];
        const bytes = self.storage[last.off .. last.off + last.len];
        if (runIsComplete(last.kind, bytes)) return 0;
        _ = self.runs.pop();
        return last.len;
    }

    /// Get last N lines of input. May be less than expected.
    fn getLastNLines(self: CircBuffer, n: usize) []Line {
        const len = self.lines.items.len;
        const min = @min(n, len);
        return self.lines.items[len - min ..];
    }

    /// Vectorized loop that splits circular buffer into lines
    fn splitIntoLines(self: *CircBuffer) void {

        // NOTE(vasco): again, because this is a mapped
        // circular buffed, we can also read without
        // wrapping without any worries
        assert(std.math.isPowerOfTwo(self.capacity));
        assert(self.tail <= self.head);

        self.lines.clearRetainingCapacity();

        const to_read: u32 = @intCast(self.head - self.tail);
        const start: u32 = @intCast(self.tail & (self.capacity - 1)); // same as %
        const end = start + to_read;
        const slice = self.storage[start..end];

        var i: u32 = 0;
        var line_start: u32 = 0;
        var esc: bool = false;

        while (i < to_read) {

            // NOTE(vasco): The only thing we need to look
            // for is ESC and LF. "Offscreen" escape sequences
            // may change the end result on the screen. They
            // may also contain newline bytes that aren't meant
            // to split the screen.

            i += SIMD.skipEqualEither(slice[i..], 0x0A, 0x1B);
            if (i >= to_read) break;

            switch (slice[i]) {
                0x0A => {
                    self.pushLine(.{
                        .off = start + line_start,
                        .len = i - line_start + 1,
                        .esc = esc,
                    });
                    esc = false;
                    i += 1;
                    line_start = i;
                },
                0x1B => {
                    esc = true;
                    i += 1;
                    // TODO: some actual parsing
                    // for the sake of correctness
                },
                else => unreachable,
            }
        }

        // push trailing line
        if (line_start < to_read) {
            self.pushLine(.{
                .off = start + line_start,
                .len = to_read - line_start,
                .esc = esc,
            });
        }
    }

    fn splitIntoRuns(self: *CircBuffer, lines: []Line) void {

        // NOTE(vasco): Splitting into Runs should be
        // pretty simple: scan for <= SPC and >= DEL
        // Once we know if we have either we can
        // use a pretty simple switch to and determine
        // the run type.

        // NOTE(vasco): We want to parse lines as if they are contiguous
        // while also taking advantage of flags like .esc
        // of each line for an easier time parsing.

        self.runs.clearRetainingCapacity();

        const start = lines[0].off;
        const last_line = lines[lines.len - 1];
        const end = last_line.off + last_line.len;
        const to_read: u32 = end - start;
        const slice = self.storage[start..end];

        var i: u32 = 0;
        var run_start: u32 = 0;

        while (i < to_read) {
            // NOTE(vasco): fast forward ascii
            i += SIMD.skipOutRange(slice[i..], 0x21, 0x7E);

            if (i >= to_read) break;

            const c = slice[i];

            if (i > run_start) {
                self.pushRun(.{
                    .off = start + run_start,
                    .len = i - run_start,
                    .kind = .plain,
                });
            }

            var kind: Run.Kind = .c0;
            var seq_len: u32 = 1;

            if (c == 0x1B) { // ESC sequence family
                if (i + 1 < to_read) {
                    const next = slice[i + 1];
                    switch (next) {
                        '[' => {
                            kind = .csi;
                            seq_len = @intCast(skipCsi(slice[i..]));
                        },
                        ']' => {
                            kind = .osc;
                            seq_len = @intCast(skipOsc(slice[i..]));
                        },
                        'P' => { // DCS (Sixel / Kitty graphics)
                            seq_len = @intCast(skipDcs(slice[i..]));
                            if (std.mem.startsWith(u8, slice[i..], "\x1bPq")) {
                                kind = .esc_sixel;
                            } else if (std.mem.startsWith(u8, slice[i..], "\x1bP_G")) {
                                kind = .esc_kitty;
                            } else {
                                kind = .str;
                            }
                        },
                        '_', '^', 'X' => { // APC / PM / SOS
                            kind = .str;
                            seq_len = @intCast(skipStTerminated(slice[i..]));
                        },
                        else => {
                            kind = .esc;
                            seq_len = @intCast(skipEsc(slice[i..]));
                        },
                    }
                } else {
                    kind = .esc;
                    seq_len = 1;
                }
            } else if (c >= 0x80) { // High-bit (UTF-8 or C1 control)
                const utf8_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                if (utf8_len > 1) {
                    kind = .utf8;
                    if (i + utf8_len <= to_read) {
                        seq_len = @intCast(utf8_len);
                    } else {
                        seq_len = to_read - i;
                    }
                } else {
                    kind = .c1;
                    seq_len = 1;
                }
            } else { // C0 control byte (0x0A '\n', 0x0D '\r', 0x09 '\t', 0x20 ' ', etc.)
                kind = .c0;
                seq_len = 1;
            }

            self.pushRun(.{
                .off = start + i,
                .len = seq_len,
                .kind = kind,
            });

            i += seq_len;
            run_start = i;
        }

        if (to_read > run_start) {
            self.pushRun(.{
                .off = start + run_start,
                .len = to_read - run_start,
                .kind = .plain,
            });
        }
    }

    inline fn pushRun(self: *CircBuffer, run: Run) void {
        self.runs.append(self.allocator, run) catch {
            // wow
        };
    }

    inline fn pushLine(self: *CircBuffer, line: Line) void {
        self.lines.append(self.allocator, line) catch {
            // wow
        };
    }

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
};

fn runIsComplete(kind: Run.Kind, bytes: []const u8) bool {
    if (bytes.len == 0) return true;
    switch (kind) {
        .c0, .c1, .plain => return true,
        .utf8 => {
            const need = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return true;
            return bytes.len >= need;
        },
        .esc => {
            if (bytes.len < 2) return false;
            const last = bytes[bytes.len - 1];
            return last < 0x20 or last > 0x2F;
        },
        .csi => {
            if (bytes.len < 3) return false;
            const last = bytes[bytes.len - 1];
            return last >= 0x40 and last <= 0x7E;
        },
        .osc, .str, .esc_kitty, .esc_sixel => {
            if (bytes[bytes.len - 1] == 0x07) return true;
            if (bytes.len >= 2 and bytes[bytes.len - 2] == 0x1b and bytes[bytes.len - 1] == '\\') return true;
            return false;
        },
    }
}

inline fn skipEsc(slice: []const u8) usize {
    if (slice.len < 2) return slice.len;
    var i: usize = 1;
    while (i < slice.len and slice[i] >= 0x20 and slice[i] <= 0x2F) i += 1;
    if (i < slice.len) return i + 1;
    return slice.len;
}

inline fn skipCsi(slice: []const u8) usize {
    if (slice.len < 3) return slice.len;
    const offset = 2 + SIMD.skipInRange(slice[2..], 0x40, 0x7E);
    if (offset < slice.len) {
        return offset + 1;
    }
    return slice.len;
}

inline fn skipOsc(slice: []const u8) usize {
    if (slice.len < 3) return slice.len;
    return skipStTerminated(slice);
}

inline fn skipDcs(slice: []const u8) usize {
    return skipStTerminated(slice);
}

inline fn skipStTerminated(slice: []const u8) usize {
    var idx: usize = 2;
    while (idx < slice.len) {
        idx += SIMD.skipEqualEither(slice[idx..], 0x07, 0x1B);
        if (idx >= slice.len) break;

        if (slice[idx] == 0x07) return idx + 1;

        if (slice[idx] == 0x1B) {
            if (idx + 1 < slice.len and slice[idx + 1] == '\\') {
                return idx + 2;
            }
            idx += 1;
        }
    }
    return slice.len;
}

fn nowNs() i128 {
    return @intCast(std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds);
}

fn waitReadable(fd: posix.fd_t, timeout_ms: i32) void {
    var fds = [_]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
    };
    _ = posix.poll(&fds, timeout_ms) catch {};
}

fn waitReadable2(a: posix.fd_t, b: posix.fd_t, timeout_ms: i32) void {
    var fds = [_]posix.pollfd{
        .{ .fd = a, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = b, .events = posix.POLL.IN, .revents = 0 },
    };
    _ = posix.poll(&fds, timeout_ms) catch {};
}

inline fn skipAsciiPrintable(slice: []const u8) usize {
    return SIMD.skipOutRange(slice, 0x20, 0x7E);
}

inline fn skipHighBit(slice: []const u8) usize {
    return SIMD.skipToLowerThan(slice, 0x80);
}

test "correct line split" {}

test "hardware level mirroring" {
    const gpa = std.testing.allocator;
    const cap = std.heap.pageSize();
    var buf = try CircBuffer.create(gpa, cap);
    defer buf.destroy();
    if (buf.mapped) return;

    // We should be able to write capacity bytes
    // at any point in time and have it wrap
    // automagically
    //
    // read(1234)
    // |12340000|mmmmmm|
    //      ^head
    //
    // read(12345678)
    // |56781234|mmmmmm|
    //                 ^head
    //
    // |1234xxxx|
}


// NOTE(vasco): The circular buffer must be fed in a very particular way.
// We must guarrantee that circbuffer.readPTY(); will read until one of two
// conditions are met: 
// 1. EOF
// 2. EAGAIN and 1/hz time has passed since the first read.
//    Meaning that once we start reading we will be updating the 
//    screen (aka consuming)
test "correct circular buffer feed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const cap = std.heap.pageSize();
    var buf = try CircBuffer.create(gpa, cap);
    defer buf.destroy();

    var fds: [2]i32 = undefined;
    const pipe_rc = std.os.linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true });
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(pipe_rc));
    defer _ = std.os.linux.close(fds[0]);

    const t0 = nowNs();
    try buf.readPTY(fds[0], 1000);
    try std.testing.expect(nowNs() - t0 >= 500_000);
    try std.testing.expect(!buf.pending());

    const msg = "hello\nworld";
    const wr = std.os.linux.write(fds[1], msg.ptr, msg.len);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(wr));
    _ = std.os.linux.close(fds[1]);

    try std.testing.expectError(error.Hangup, buf.readPTY(fds[0], 1000));
    try std.testing.expect(buf.pending());
    try std.testing.expectEqual(@as(u64, msg.len), buf.head - buf.tail);
}

fn append(buf: *CircBuffer, src: []const u8) void {
    const cap = buf.capacity;
    const off: usize = @intCast(buf.head & (cap - 1));
    @memcpy(buf.storage[off..][0..src.len], src);
    buf.syncMirror(off, src.len);
    buf.head += src.len;
}

test "hold incomplete csi until final" {
    const gpa = std.testing.allocator;
    const cap = std.heap.pageSize();
    var buf = try CircBuffer.create(gpa, cap);
    defer buf.destroy();

    append(&buf, "\x1b[31");
    try std.testing.expect(buf.pending());
    const first = buf.consumeAndGetRuns(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), first.len);
    try std.testing.expect(!buf.pending());

    append(&buf, "mX");
    try std.testing.expect(buf.pending());
    const second = buf.consumeAndGetRuns(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 2), second.len);
    try std.testing.expectEqual(Run.Kind.csi, second[0].kind);
    try std.testing.expectEqual(Run.Kind.plain, second[1].kind);
    try std.testing.expect(!buf.pending());
}

test "hold lone ESC then CSI" {
    const gpa = std.testing.allocator;
    const cap = std.heap.pageSize();
    var buf = try CircBuffer.create(gpa, cap);
    defer buf.destroy();

    append(&buf, "\x1b");
    const first = buf.consumeAndGetRuns(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 0), first.len);
    try std.testing.expect(!buf.pending());

    append(&buf, "[7m");
    const second = buf.consumeAndGetRuns(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqual(Run.Kind.csi, second[0].kind);
    const bytes = buf.storage[second[0].off .. second[0].off + second[0].len];
    try std.testing.expectEqualStrings("\x1b[7m", bytes);
}
