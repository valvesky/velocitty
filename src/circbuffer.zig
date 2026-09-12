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
        const lines = self.getLastNLines(nlines);
        self.splitIntoRuns(lines);
        return self.runs.items;
    }

    /// Read directly from a file descriptor.
    pub fn read(self: *CircBuffer, reader: std.io.AnyReader) !usize {
        assert(self.mapped);

        // NOTE(vasco): we can always read capacity because the buffer is mmap'd
        const target_slice = self.storage[self.head..][0..self.capacity];
        const bytes_read = try reader.read(target_slice);
        self.head += bytes_read;
        return bytes_read;
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
        self.tail = self.head;
    }

    /// Get last N lines of input. May be less than expected.
    fn getLastNLines(self: CircBuffer, n: usize) []Line {
        const min = @min(n, self.lines.items.len);
        return self.lines.items[0..min];
    }

    /// Vectorized loop that splits circular buffer into lines
    fn splitIntoLines(self: *CircBuffer) void {

        // NOTE(vasco): again, because this is a mapped
        // circular buffed, we can also read read without
        // wrapping without any worries
        assert(std.math.isPowerOfTwo(self.capacity));
        assert(self.mapped);
        assert(self.tail <= self.head);

        self.lines.clearRetainingCapacity();

        const to_read: u32 = @intCast(self.head - self.tail);
        const start   = self.tail & (self.capacity - 1); // same as %
        const end     = start + to_read;
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

            switch (slice[i]) {
                0x0A => {
                    self.pushLine(.{
                        .off = line_start,
                        .len = i - line_start,
                        .esc = esc,
                    });
                    esc = true;
                    i+= 1;
                    line_start = i;
                },
                0x1B => {
                    esc = true;
                    i+= 1;
                    // TODO: some actual parsing
                    // for the sake of correctness
                },
                else => unreachable,
            }
        }

        // push trailing line
        if (line_start < to_read) {
            self.pushLine(.{
                .off = line_start,
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
                            seq_len = 2; // Simple ESC sequence (e.g., ESC M, ESC 7)
                        },
                    }
                } else {
                    kind = .esc;
                    seq_len = 1;
                }
            } else if (c >= 0x80) { // High-bit (UTF-8 or C1 control)
                const utf8_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                if (utf8_len > 1 and i + utf8_len <= to_read) {
                    kind = .utf8;
                    seq_len = @intCast(utf8_len);
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

inline fn skipAsciiPrintable(slice: []const u8) usize {
    return SIMD.skipOutRange(slice, 0x20, 0x7E);
}

inline fn skipHighBit(slice: []const u8) usize {
    return SIMD.skipToLowerThan(slice, 0x80);
}

test "correct line split" {
}


test "hardware level mirroring" {
    const gpa = std.testing.allocator;
    const cap = std.heap.pageSize();
    var buf = try CircBuffer.create(gpa, cap);
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


    defer buf.destroy();

}
