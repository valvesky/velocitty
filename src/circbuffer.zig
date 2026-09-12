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

const Term = @import("term.zig").Term;

const assert = std.debug.assert;
const posix = std.posix;

const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vec_len, u8);
const Mask = std.meta.Int(.unsigned, vec_len);

comptime {
    assert(vec_len <= 64);
}

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
    lines: std.ArrayListUnmanaged(Line) = .{},
    runs: std.ArrayListUnmanaged(Run) = .{},

    /// Create circular buffer
    pub fn create(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!CircBuffer {
        assert(capacity > 0);
        assert(std.math.isPowerOfTwo(capacity));

        var lines: std.ArrayListUnmanaged(Line) = . me;
        try lines.ensureTotalCapacity(allocator, 256);
        errdefer lines.deinit(allocator);

        var runs: std.ArrayListUnmanaged(Run) = . me;
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
        self.allocator.free(self.lines);
        self.* = undefined;
    }

    /// Consume everything and return runs.
    pub fn consumeAndGetRuns(self: *CircBuffer, term: *Term) []Run {
        self.consumeAndPreparse(term);
        const lines = self.getLastNLines(term.rows);
        self.splitLinesIntoRuns(lines);
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
    fn consumeAndPreparse(self: CircBuffer, term: Term) void {

        assert(self.tail <= self.head);

        // NOTE(vasco): indices are monotonic and keep growing forever
        // therefore we must make sure the head hasn't skipped too far
        // ahead of tail.
        if ((self.head - self.tail) > self.capacity) 
            self.tail = self.head - self.capacity;
        splitIntoLines(self, term);
        self.tail = self.head;
    }

    /// Get last N lines of input. May be less than expected.
    fn getLastNLines(self: CircBuffer, n: usize) []Line {
        const min = @min(n, self.lines.len);
        return self.lines[0..min];
    }

    /// Vectorized loop that splits circular buffer into lines
    fn splitIntoLines(self: CircBuffer, term: Term) void {

        // NOTE(vasco): again, because this is a mapped
        // circular buffed, we can also read read without
        // wrapping without any worries
        assert(std.math.isPowerOfTwo(self.capacity));
        assert(self.mapped);
        assert(self.tail <= self.head);

        self.lines.clearRetainingCapacity();

        const to_read = self.head - self.tail;
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
            const chunk: Vec = slice[i..][0..vec_len].*;
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
                        .esc = esc,
                    });
                    esc = false;
                    last_line = i;
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

                    term.rows;

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
                    //     '[' => { csi.parse()};
                    //     ']' => { i = skipSeq(slice) }; // non whitelisted get skipped
                    // }
                }

                // Advance past the processed byte
                i = match_index + 1;
                continue;
            }

            i += vec_len;
        }

        // Scalar loop
        while (i < to_read) {

            const byte = slice[i];

            if (byte == 0x0A) {
                try self.lines.append(self.allocator, .{ 
                    .off = i,
                    .len = last_line - i,
                    .esc = esc,
                });
                esc = false;
                last_line = i;
            } else if (byte == 0x1B) {
                esc = true;
            }

            i += 1;
        }
    }

    fn splitLinesIntoRuns(self: *CircBuffer, lines: []Line) void {

        // NOTE(vasco): Splitting into Runs should be 
        // pretty simple: scan for <= SPC and >= DEL
        // Once we know if we have either we can
        // use a pretty simple switch to and determine 
        // the run type.

        // NOTE(vasco): We want to parse lines as if they are contiguous
        // while also taking advantage of flags like .esc
        // of each line for an easier time parsing.

        self.runs.clearRetainingCapacity();

        const vec_spc: Vec = @splat(0x20); // Controls/SPC <= 0x20
        const vec_del: Vec = @splat(0x7F); // DEL / High-bit >= 0x7F

        for (lines) |line| {
            const slice = self.storage[line.off .. line.off + line.len];
            var i: usize = 0;
            var run_start: usize = 0;

            while (i < slice.len) {
                // --- Step 1: SIMD Fast-Path (Scan for non-plain ASCII) ---
                if (!line.esc) {
                    // If line has no escape sequences, vector scan for any boundary (<= 0x20 or >= 0x7F)
                    while (i + vec_len <= slice.len) {
                        const chunk: Vec = slice[i..][0..vec_len].*;
                        const matches = (chunk <= vec_spc) | (chunk >= vec_del);
                        const mask: u16 = @bitCast(matches);

                        if (mask != 0) {
                            i += @ctz(mask); // Jump directly to the first non-plain byte
                            break;
                        }
                        i += vec_len;
                    }
                }

                if (i >= slice.len) break;

                const c = slice[i];

                // --- Step 2: Sequence Classification & Multi-byte Advancement ---
                if (c > 0x20 and c < 0x7F) {
                    // Plain Printable ASCII byte
                    i += 1;
                    continue;
                }

                // Flush preceding plain text run if one accumulated
                if (i > run_start) {
                    try self.runs.append(self.allocator, .{
                        .off = line.off + run_start,
                        .len = i - run_start,
                        .kind = .plain,
                    });
                }

                // Categorize non-plain byte and measure sequence length
                var kind: Run.Kind = .c0;
                var seq_len: usize = 1;

                if (c == 0x1B) { // ESC
                    if (i + 1 < slice.len) {
                        const next = slice[i + 1];
                        switch (next) {
                            '[' => { // CSI
                                kind = .csi;
                                seq_len = skipCsi(slice[i..]);
                            },
                            ']' => { // OSC
                                kind = .osc;
                                seq_len = skipOsc(slice[i..]);
                            },
                            'P' => { // DCS (Sixel / Kitty graphics streams)
                                seq_len = skipDcs(slice[i..]);
                                if (std.mem.startsWith(u8, slice[i..], "\x1bPq")) {
                                    kind = .esc_sixel;
                                } else if (std.mem.startsWith(u8, slice[i..], "\x1bP_G")) {
                                    kind = .esc_kitty;
                                } else {
                                    kind = .str;
                                }
                            },
                            '_', '^', 'X' => { // APC / PM / SOS String sequences
                                kind = .str;
                                seq_len = skipStTerminated(slice[i..]);
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
                } else if (c >= 0x80) { // High-bit (UTF-8 lead or C1 control)
                    const utf8_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                    if (utf8_len > 1 and i + utf8_len <= slice.len) {
                        kind = .utf8;
                        seq_len = utf8_len;
                    } else {
                        kind = .c1;
                        seq_len = 1;
                    }
                } else { // C0 control character (BS, TAB, CR, LF, etc.)
                    kind = .c0;
                    seq_len = 1;
                }

                // Emit control/sequence run
                try self.runs.append(self.allocator, .{
                    .off = line.off + i,
                    .len = seq_len,
                    .kind = kind,
                });

                i += seq_len;
                run_start = i;
            }

            // Flush remaining trailing plain text
            if (slice.len > run_start) {
                try self.runs.append(self.allocator, .{
                    .off = line.off + run_start,
                    .len = slice.len - run_start,
                    .kind = .plain,
                });
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
};

// NOTE(vasco):
// The skip functions will be useful in the future.
// No harm in leaving them here because of zig's tree shaking.

fn skipCsi(slice: []const u8) usize {
    if (slice.len < 3) return slice.len;
    var idx: usize = 2; // Skip ESC [
    while (idx < slice.len) : (idx += 1) {
        const b = slice[idx];
        if (b >= 0x40 and b <= 0x7E) return idx + 1; // Final byte terminates CSI
    }
    return slice.len;
}

fn skipOsc(slice: []const u8) usize {
    if (slice.len < 3) return slice.len;
    return skipStTerminated(slice);
}

fn skipDcs(slice: []const u8) usize {
    return skipStTerminated(slice);
}

fn skipStTerminated(slice: []const u8) usize {
    var idx: usize = 2;
    while (idx < slice.len) : (idx += 1) {
        if (slice[idx] == 0x07) return idx + 1; // BEL termination
        if (slice[idx] == 0x1B and idx + 1 < slice.len and slice[idx + 1] == '\\') {
            return idx + 2; // ST (ESC \) termination
        }
    }
    return slice.len;
}

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
