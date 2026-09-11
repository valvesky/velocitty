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
const Vec = @Vector(vec_len, u8);
const Mask = std.meta.Int(.unsigned, vec_len);

comptime {
    assert(vec_len <= 64);
}

/// Lines probably don't need to be monotonic.
/// I think... ?
pub const Line = packed struct {
    off: u32,
    len: u32,
    esc: bool,
};

const CircBuffer = @This;

allocator: std.mem.Allocator;
storage: []u8;
capacity: usize;
mapped: bool;
head: u64 = 0;
tail: u64 = 0;
epoch: u64 = 0;
lines: ArrayListUnmanaged(Line) = .{};

/// Create circular buffer
pub fn create(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!CircBuffer {
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
    self.allocator.free(self.lines);
    self.* = undefined;
}


/// Read directly from a file descriptor from a file descriptor.
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
pub fn consumeAndPreparse(self: CircBuffer, term: Term) void {

    assert(self.tail <= self.head);

    // NOTE(vasco): indices are monotonic and keep growing forever
    // therefore we must make sure the head hasn't skipped too far
    // ahead of tail.
    self.tail = if ((head - tail) > self.capacity) self.head;
    splitIntoLines(self, term);
    tail = head;
}

/// Get last N lines of input. May be less than expected.
pub fn getLastNLines(self: CircBuffer, n: usize) []Line {
    const min = @min(n, self.lines.len);
    return self.lines[0..min];
}

/// Vectorized loop that splits circular buffer into lines
fn splitIntoLines(self: CircBuffer, term: Term) void {

    // NOTE(vasco): again, because this is a mapped
    // circular buffed, we can also read read without
    // wrapping without any worries
    assert(std.math.isPowerOfTwo(capacity));
    assert(self.mapped);
    assert(self.tail <= self.head);

    self.lines.clearRetainingCapacity();

    const to_read = self.head - self.tial;
    const start   = self.tail & (self.capacity - 1); // same as %
    const end     = start + to_read;
    const slice = self.storage[start..end];

    var i: usize = 0;
    var last_line: usize = 0; 
    var esc: bool = false;


    // NOTE(vasco): Okay, the only thing we need to look
    // for is ESC and LF. We need to do this vectorized
    // or else it defeats the point.

    const vec_lf: Vec = @splat(0x0A); // '\n'
    const vec_esc: Vec = @splat(0x1B); // ESC
                                    
    while (i + vec_len <= to_read) {
        const chunk: Vec = slice[i..][0..VectorLen].*;
        const match_lf = (chunk == vec_lf);
        const match_esc = (chunk == vec_esc);
        const matches: @Vector(vec_len, bool) = match_lf | match_esc;
        const bitmask: u32 = @bitCast(matches);

        if (bitmask != 0) {
            // Found ESC or LF in this vector block!
            // @ctz gives the index of the first matching byte lane
            const match_offset = @ctz(bitmask);
            const match_index = i + match_offset;
            const byte = slice[match_index];

            if (byte == 0x0A) {
                try self.lines.append(self.allocator, .{ 
                    .off = match_index,
                    .len = last_line - match_index,
                    .esc = esc }
                );

                esc = false;
            } else if (byte == 0x1B) {
                esc = true;

                // TODO(vasco):
                // treat whitelisted offscreen escape sequences
                // this would make output more correct
                // but we can skip it for now
                //
                // I will have to test to see how many programs
                // this would actually effect.
                //
                // What's more concerning is that you can
                // be inside an escape sequence with a binary
                // payload containing a newline. That would
                // cause potential bugs.

                // NOTE(vasco): Now it gets tricky.
                // The ideal scenarios is that we only 
                // treat sequences that will update the terminal 
                // cursor.
                //
                // Once we know we just have a payload that may
                // or may not be offscreen, we start skipping 
                // along with more vectorized parsing.
                // i++;
                // var esc_slice;
                // switch (slice[i]) {
                //     '[' => { esc.parse()};
                //     ']' => { csi.parse(esc_slice)};
                // }
            }

            // Advance past the processed byte
            i = match_index + 1;
            continue;
        }
    }
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



// NOTE(vasco):
// The skip functions will be useful in the future.
// No harm in leaving them here because of zig's tree shaking.


/// Bytes in `[0x20, 0x7F)`. Same predicate as the AVX2 printable run in vt.
fn skipAsciiPrintable(input: []const u8, start: usize) usize {
    const V = @Vector(vec_len, u8);
    const space: V = @splat(0x20);
    const del: V = @splat(0x7F);
    var i = start;
    while (i + vec_len <= input.len) : (i += vec_len) {
        const chunk: V = input[i..][0..vec_len].*;
        const bad: @Vector(vec_len, u1) =
            @intFromBool(chunk < space) | @intFromBool(chunk >= del);
        const bits: Mask = @bitCast(bad);
        if (bits != 0) return i + @ctz(bits);
    }
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c < 0x20 or c >= 0x7F) return i;
    }
    return input.len;
}

/// Bytes with the high bit set. Stops at ASCII / C0 / DEL.
fn skipHighBit(input: []const u8, start: usize) usize {
    const V = @Vector(vec_len, u8);
    const hi: V = @splat(0x80);
    var i = start;
    while (i + vec_len <= input.len) : (i += vec_len) {
        const chunk: V = input[i..][0..vec_len].*;
        const bad: @Vector(vec_len, u1) = @intFromBool(chunk < hi);
        const bits: Mask = @bitCast(bad);
        if (bits != 0) return i + @ctz(bits);
    }
    while (i < input.len) : (i += 1) {
        if (input[i] < 0x80) return i;
    }
    return input.len;
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
