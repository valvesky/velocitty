const std = @import("std");

const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vec_len, u8);
const Mask = @Int(.unsigned, vec_len);

comptime {
    std.debug.assert(vec_len <= 64);
}

pub const ScanOp = enum {
    less_than,
    greater_than,
    equal,
    equal_either,
    in_range,  // inclusive
    out_range, // exclusive
};

pub inline fn skipToLowerThan(slice: []const u8, threshold: u8) u32 {
    return skipUntil(.less_than, slice, threshold, 0);
}

pub inline fn skipToGreaterThan(slice: []const u8, threshold: u8) u32 {
    return skipUntil(.greater_than, slice, threshold, 0);
}

pub inline fn skipEqual(slice: []const u8, target: u8) u32 {
    return skipUntil(.equal, slice, target, 0);
}

pub inline fn skipEqualEither(slice: []const u8, target_a: u8, target_b: u8) u32 {
    return skipUntil(.equal_either, slice, target_a, target_b);
}

pub inline fn skipInRange(slice: []const u8, min: u8, max: u8) u32 {
    return skipUntil(.in_range, slice, min, max);
}

pub inline fn skipOutRange(slice: []const u8, min: u8, max: u8) u32 {
    return skipUntil(.out_range, slice, min, max);
}

pub inline fn skipUntil(
    comptime op: ScanOp,
    slice: []const u8,
    threshold: u8,
    secondary_threshold: u8,
) u32 {
    var offset: u32 = 0;
    const slice_len: u32 = @intCast(slice.len);

    const target_vec: Vec = @splat(threshold);
    const sec_vec: Vec = @splat(secondary_threshold);

    while (offset + vec_len <= slice_len) {
        const chunk: Vec = slice[offset..][0..vec_len].*;

        const matches: @Vector(vec_len, bool) = switch (op) {
            .less_than => chunk < target_vec,
            .greater_than => chunk > target_vec,
            .equal => chunk == target_vec,
            .equal_either => (chunk == target_vec) | (chunk == sec_vec),
            .in_range => (chunk >= target_vec) & (chunk <= sec_vec),
            .out_range => (chunk < target_vec) | (chunk > sec_vec),
        };

        const mask: Mask = @bitCast(matches);
        if (mask != 0) {
            return offset + @ctz(mask);
        }

        offset += vec_len;
    }

    while (offset < slice_len) {
        const b = slice[offset];
        const matched = switch (op) {
            .less_than => b < threshold,
            .greater_than => b > threshold,
            .equal => b == threshold,
            .equal_either => b == threshold or b == secondary_threshold,
            .in_range => b >= threshold and b <= secondary_threshold,
            .out_range => b < threshold or b > secondary_threshold,
        };

        if (matched) break;
        offset += 1;
    }

    return offset;
}

/// Index of the first byte that equals any of `set` (or `slice.len`).
pub inline fn skipToAny(slice: []const u8, comptime set: []const u8) u32 {
    var offset: u32 = 0;
    const slice_len: u32 = @intCast(slice.len);
    while (offset + vec_len <= slice_len) {
        const chunk: Vec = slice[offset..][0..vec_len].*;
        var matches: @Vector(vec_len, bool) = @splat(false);
        inline for (set) |b| matches = matches | (chunk == @as(Vec, @splat(b)));
        const mask: Mask = @bitCast(matches);
        if (mask != 0) return offset + @ctz(mask);
        offset += vec_len;
    }
    while (offset < slice_len) : (offset += 1) {
        inline for (set) |b| if (slice[offset] == b) return offset;
    }
    return offset;
}

// ---------------------------------------------------------------------------
// UTF-8 runs
//
// `decodeUtf8Run` decodes the run of text at the start of a slice into
// codepoints. Its semantics are those of a scalar walk (`decodeUtf8Step`):
// - `.non_ascii` runs end at a byte < 0x80 that starts a sequence (not one
//   swallowed by an invalid sequence, below); `.printable` runs also take
//   0x20..0x7E as one-byte codepoints and end at C0 or DEL instead. Either
//   ends at the end of the slice;
// - a byte that cannot start a sequence (0x80..0xBF, 0xF8..0xFF) is skipped
//   on its own;
// - a lead whose sequence would pass the end of the slice ends the run and
//   consumes the rest of the slice;
// - an invalid sequence (bad continuation, overlong, surrogate, > U+10FFFF)
//   is skipped as a whole: the lead's length in bytes, whatever they are.
// 64-byte blocks of 1- (`.printable`), 2- and 3-byte sequences are
// validated and decoded with vectors (back-to-back 3-byte and 2-byte
// sequences with one fixed shuffle, mixed ones with a lead-mask walk);
// 4-byte sequences, invalid input and the last bytes take the scalar step.
// `.printable` also ends a run early, at a block that starts with 32 bytes
// of printable ASCII, so the caller can print those in bulk.

pub const Utf8Mode = enum { non_ascii, printable };

pub const Utf8Run = struct {
    /// Bytes consumed.
    read: usize,
    /// Codepoints stored in `dst`.
    written: usize,
    /// The run ended (ASCII byte, C0/DEL for `.printable`, or end of
    /// slice); otherwise `dst` is (nearly) full.
    done: bool,
};

/// Length of the sequence `lead` starts (as `std.unicode.utf8ByteSequenceLength`),
/// 1 for ASCII and for a byte that cannot start one.
pub inline fn utf8SeqLen(lead: u8) u3 {
    return switch (lead) {
        0x00...0x7F => 1,
        0xC0...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF7 => 4,
        else => 1,
    };
}

/// Decode one UTF-8 sequence whose length came from its lead byte.
/// Rejects bad continuation bytes, overlongs, surrogates and > U+10FFFF.
pub inline fn decodeUtf8Seq(seq: []const u8) ?u21 {
    for (seq[1..]) |c| if (c & 0xC0 != 0x80) return null;
    const cp: u21 = switch (seq.len) {
        2 => (@as(u21, seq[0] & 0x1F) << 6) | (seq[1] & 0x3F),
        3 => (@as(u21, seq[0] & 0x0F) << 12) | (@as(u21, seq[1] & 0x3F) << 6) | (seq[2] & 0x3F),
        4 => blk: {
            const v = (@as(u32, seq[0] & 0x07) << 18) | (@as(u32, seq[1] & 0x3F) << 12) | (@as(u32, seq[2] & 0x3F) << 6) | (seq[3] & 0x3F);
            if (v > 0x10FFFF) return null;
            break :blk @intCast(v);
        },
        else => return null,
    };
    const min: u21 = switch (seq.len) {
        2 => 0x80,
        3 => 0x800,
        else => 0x10000,
    };
    if (cp < min or (cp >= 0xD800 and cp <= 0xDFFF)) return null;
    return cp;
}

/// One scalar step at `src[i.*]`, a byte >= 0x80: advances `i` and returns
/// the codepoint if the sequence was valid. A truncated sequence returns
/// null with `i.* == src.len`.
pub inline fn decodeUtf8Step(src: []const u8, i: *usize) ?u21 {
    const len = utf8SeqLen(src[i.*]);
    if (len == 1) {
        i.* += 1;
        return null;
    }
    if (i.* + len > src.len) {
        i.* = src.len;
        return null;
    }
    const cp = decodeUtf8Seq(src[i.*..][0..len]);
    i.* += len;
    return cp;
}

inline fn endsRun(comptime mode: Utf8Mode, b: u8) bool {
    return switch (mode) {
        .non_ascii => b < 0x80,
        .printable => b < 0x20 or b == 0x7F,
    };
}

/// The scalar reference for `decodeUtf8Run` (same contract, without the
/// early end before printable ASCII).
pub fn decodeUtf8RunScalar(comptime mode: Utf8Mode, src: []const u8, dst: []u32) Utf8Run {
    var i: usize = 0;
    var n: usize = 0;
    while (true) {
        if (i >= src.len or endsRun(mode, src[i])) return .{ .read = i, .written = n, .done = true };
        if (n == dst.len) return .{ .read = i, .written = n, .done = false };
        if (mode == .printable and src[i] < 0x80) {
            dst[n] = src[i];
            n += 1;
            i += 1;
        } else if (decodeUtf8Step(src, &i)) |cp| {
            dst[n] = cp;
            n += 1;
        }
    }
}

const block = 64;
const BlockVec = @Vector(block, u8);
const BlockWide = @Vector(block, u16);

/// Most codepoints one block can produce.
fn blockOut(comptime mode: Utf8Mode) usize {
    return if (mode == .printable) block else block / 2;
}

inline fn bits64(v: @Vector(block, bool)) u64 {
    return @bitCast(v);
}

inline fn below(n: u32) u64 {
    return if (n >= block) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
}

/// Lead positions of back-to-back 3-byte (`pat3`) and 2-byte (`pat2`) sequences.
const pat3: u64 = 0x9249_2492_4924_9249;
const pat2: u64 = 0x5555_5555_5555_5555;
/// `decodeBlock`: the block starts with printable ASCII; end the run.
const ascii_stretch = std.math.maxInt(usize);

/// Validate and decode the longest prefix of `src[0..64]` made of whole,
/// valid sequences into `dst[written..]` (room for `blockOut(mode)`).
/// Returns the prefix length in bytes; 0 means the scalar step goes first.
inline fn decodeBlock(comptime mode: Utf8Mode, src: *const [block]u8, dst: [*]u32, written: *usize) usize {
    const v: BlockVec = src.*;
    const cont = bits64(v & @as(BlockVec, @splat(0xC0)) == @as(BlockVec, @splat(0x80)));
    const lead2 = bits64(v & @as(BlockVec, @splat(0xE0)) == @as(BlockVec, @splat(0xC0)));
    const lead3 = bits64(v & @as(BlockVec, @splat(0xF0)) == @as(BlockVec, @splat(0xE0)));
    const lead1: u64 = if (mode == .printable)
        bits64(v >= @as(BlockVec, @splat(0x20))) & bits64(v < @as(BlockVec, @splat(0x7F)))
    else
        0;
    if (mode == .printable and lead1 & 0xFFFF_FFFF == 0xFFFF_FFFF) return ascii_stretch;
    const multi = lead2 | lead3;
    const leads = lead1 | multi;
    // First byte that ends the run, is a 4-byte lead or is never valid.
    const stop: u32 = @ctz(~(cont | leads));
    if (stop == 0) return 0;
    // Continuations each lead asks for (positions past 63 fall off).
    const need = (multi << 1) | (lead3 << 2);
    // End on a sequence boundary: a sequence must not run past the block
    // or into `stop`; cut before the lead of one that does.
    var cut = stop;
    if (stop == block) {
        const tail = (lead3 >> 62) | ((multi >> 63) << 1);
        if (tail != 0) cut = if (tail & 1 != 0) 62 else 63;
    }
    while (cut < block and (need >> @intCast(cut)) & 1 != 0) {
        const before = leads & below(cut);
        if (before == 0) return 0;
        cut = 63 - @clz(before);
    }
    if (cut == 0) return 0;
    // First structural mismatch: a continuation nobody asked for, or a
    // lead where a continuation was owed. Cut before the broken sequence.
    const bad_struct = (need ^ cont) & below(cut);
    if (bad_struct != 0) {
        const m: u32 = @ctz(bad_struct);
        if ((need >> @intCast(m)) & 1 != 0) {
            // Owed to the sequence of the last lead before m.
            const before = leads & below(m);
            if (before == 0) return 0;
            cut = 63 - @clz(before);
        } else cut = m;
        if (cut == 0) return 0;
    }
    // Values: 2-byte overlong (C0, C1), 3-byte overlong (E0 then < A0),
    // surrogates (ED then >= A0).
    const next = std.simd.shiftElementsLeft(v, 1, 0);
    const over2 = lead2 & bits64(v < @as(BlockVec, @splat(0xC2)));
    const over3 = bits64(v == @as(BlockVec, @splat(0xE0))) & bits64(next < @as(BlockVec, @splat(0xA0)));
    const surr = bits64(v == @as(BlockVec, @splat(0xED))) & bits64(next >= @as(BlockVec, @splat(0xA0)));
    const bad_val = (over2 | over3 | surr) & below(cut);
    if (bad_val != 0) {
        cut = @ctz(bad_val);
        if (cut == 0) return 0;
    }
    // Codepoint at every position as if it were a lead (u16 is enough).
    const b0: BlockWide = v;
    const b1: BlockWide = next;
    const b2: BlockWide = std.simd.shiftElementsLeft(v, 2, 0);
    const c1 = b1 & @as(BlockWide, @splat(0x3F));
    const c2 = b2 & @as(BlockWide, @splat(0x3F));
    const cp2 = ((b0 & @as(BlockWide, @splat(0x1F))) << @splat(6)) | c1;
    const cp3 = ((b0 & @as(BlockWide, @splat(0x0F))) << @splat(12)) | (c1 << @splat(6)) | c2;
    const is3: @Vector(block, bool) = @bitCast(lead3);
    var cpv = @select(u16, is3, cp3, cp2);
    if (mode == .printable) {
        const is1: @Vector(block, bool) = @bitCast(lead1);
        cpv = @select(u16, is1, b0, cpv);
    }
    const cps: [block]u16 = cpv;
    const in_cut = below(cut);
    const sel = leads & in_cut;
    var n = written.*;
    if (sel == pat3 & in_cut) {
        // Back-to-back 3-byte sequences (CJK): every third lane.
        const idx = comptime blk: {
            var a: [21]i32 = undefined;
            for (&a, 0..) |*x, k| x.* = 3 * k;
            break :blk a;
        };
        const out: @Vector(21, u32) = @shuffle(u16, cpv, undefined, idx);
        dst[n..][0..21].* = out;
        n += @popCount(sel);
    } else if (sel == pat2 & in_cut) {
        const idx = comptime blk: {
            var a: [32]i32 = undefined;
            for (&a, 0..) |*x, k| x.* = 2 * k;
            break :blk a;
        };
        const out: @Vector(32, u32) = @shuffle(u16, cpv, undefined, idx);
        dst[n..][0..32].* = out;
        n += @popCount(sel);
    } else {
        var m = sel;
        while (m != 0) : (m &= m - 1) {
            dst[n] = cps[@ctz(m)];
            n += 1;
        }
    }
    written.* = n;
    return cut;
}

/// Decode the run at the start of `src` into `dst` (see the section
/// comment). Stops early, with `done` false, when `dst` is nearly full.
pub fn decodeUtf8Run(comptime mode: Utf8Mode, src: []const u8, dst: []u32) Utf8Run {
    var i: usize = 0;
    var n: usize = 0;
    while (true) {
        if (i + block <= src.len and dst.len - n >= blockOut(mode)) {
            const took = decodeBlock(mode, src[i..][0..block], dst.ptr, &n);
            if (took == ascii_stretch) return .{ .read = i, .written = n, .done = true };
            if (took != 0) {
                i += took;
                continue;
            }
        }
        if (i >= src.len or endsRun(mode, src[i])) return .{ .read = i, .written = n, .done = true };
        if (n == dst.len) return .{ .read = i, .written = n, .done = false };
        if (mode == .printable and src[i] < 0x80) {
            dst[n] = src[i];
            n += 1;
            i += 1;
        } else if (decodeUtf8Step(src, &i)) |cp| {
            dst[n] = cp;
            n += 1;
        }
    }
}

/// Decode all of `src` the way a caller walks runs: after a run, a byte
/// that ended it is skipped (and recorded as 0xFFFF_0000 | byte), and
/// printable ASCII left by `.printable`'s early end is taken as is.
fn walkRuns(comptime mode: Utf8Mode, comptime simd: bool, src: []const u8, cap: usize, out: *std.ArrayList(u32)) !void {
    var buf: [512]u32 = undefined;
    var off: usize = 0;
    while (off < src.len) {
        const r = if (simd) decodeUtf8Run(mode, src[off..], buf[0..cap]) else decodeUtf8RunScalar(mode, src[off..], buf[0..cap]);
        try out.appendSlice(std.testing.allocator, buf[0..r.written]);
        off += r.read;
        if (!r.done or off >= src.len) continue;
        if (endsRun(mode, src[off])) {
            try out.append(std.testing.allocator, 0xFFFF_0000 | @as(u32, src[off]));
            off += 1;
        } else {
            // `.printable` stopped before plain ASCII.
            std.debug.assert(mode == .printable and simd);
            while (off < src.len and src[off] >= 0x20 and src[off] < 0x7F) : (off += 1) {
                try out.append(std.testing.allocator, src[off]);
            }
        }
    }
}

fn expectSameRuns(src: []const u8, cap: usize) !void {
    inline for (.{ Utf8Mode.non_ascii, Utf8Mode.printable }) |mode| {
        var a: std.ArrayList(u32) = .empty;
        defer a.deinit(std.testing.allocator);
        var b: std.ArrayList(u32) = .empty;
        defer b.deinit(std.testing.allocator);
        try walkRuns(mode, true, src, cap, &a);
        try walkRuns(mode, false, src, cap, &b);
        try std.testing.expectEqualSlices(u32, b.items, a.items);
    }
    // `.non_ascii` has no early end: every call matches the reference.
    var a: [512]u32 = undefined;
    var b: [512]u32 = undefined;
    var off: usize = 0;
    while (off < src.len) {
        const ra = decodeUtf8Run(.non_ascii, src[off..], a[0..cap]);
        const rb = decodeUtf8RunScalar(.non_ascii, src[off..], b[0..cap]);
        try std.testing.expectEqual(rb, ra);
        try std.testing.expectEqualSlices(u32, b[0..rb.written], a[0..ra.written]);
        off += ra.read;
        if (ra.done and off < src.len) off += 1;
    }
}

test "utf8 run decoder matches the scalar reference" {
    var prng = std.Random.DefaultPrng.init(0x5eed_07f8);
    const rnd = prng.random();
    var src: [400]u8 = undefined;
    const pieces = [_][]const u8{
        "\xe6\x97\xa6", "\xe6\xb5\xb7", "\xef\xbc\x9a", "\xc3\xa9", "\xc2\x80", "\xdf\xbf",
        "\xf0\x9f\x98\x80", "\xf4\x8f\xbf\xbf", "\xe0\xa0\x80", "\xef\xbf\xbf", "\xed\x9f\xbf", "\xee\x80\x80",
        "a", " ", "~", "Zq",
        // invalid: overlongs, surrogates, > U+10FFFF, stray, bad continuation
        "\xc0\x80", "\xc1\xbf", "\xe0\x80\x80", "\xe0\x9f\xbf", "\xed\xa0\x80", "\xed\xbf\xbf",
        "\xf0\x80\x80\x80", "\xf4\x90\x80\x80", "\xf8", "\xff", "\x80", "\xbf", "\xe6\x97", "\xe6\x41\x42",
        "\xc3", "\xe6", "\xf0\x9f", "\n", "\x7f", "\x1b",
    };
    const first_bad = 16;
    var iter: usize = 0;
    while (iter < 20000) : (iter += 1) {
        // Shape: mostly one kind of sequence, sometimes noise.
        const mode = rnd.uintLessThan(u8, 8);
        var len: usize = 0;
        const target = rnd.uintLessThan(usize, src.len - 8);
        while (len < target) {
            const piece: []const u8 = switch (mode) {
                0 => pieces[0],
                1 => pieces[rnd.uintLessThan(usize, 3)],
                2 => pieces[3 + rnd.uintLessThan(usize, 3)],
                3 => pieces[rnd.uintLessThan(usize, 12)],
                4 => pieces[rnd.uintLessThan(usize, first_bad)],
                5 => if (rnd.uintLessThan(u8, 3) == 0) pieces[12 + rnd.uintLessThan(usize, 4)] else pieces[3 + rnd.uintLessThan(usize, 3)],
                6 => pieces[rnd.uintLessThan(usize, pieces.len)],
                else => blk: {
                    // Raw random bytes, biased to the high half.
                    const k = rnd.uintLessThan(usize, 4) + 1;
                    for (0..k) |j| src[len + j] = rnd.int(u8) | if (rnd.boolean()) @as(u8, 0x80) else 0;
                    break :blk src[len..][0..k];
                },
            };
            if (len + piece.len > src.len) break;
            if (piece.ptr != src[len..].ptr) @memcpy(src[len..][0..piece.len], piece);
            len += piece.len;
            // Occasionally a rare error inside a long clean stretch.
            if (mode < 6 and rnd.uintLessThan(u8, 64) == 0 and len < src.len) {
                src[len] = pieces[first_bad + rnd.uintLessThan(usize, pieces.len - first_bad)][0];
                len += 1;
            }
        }
        // Start offsets near vector boundaries, and a few output sizes.
        const start = rnd.uintLessThan(usize, @min(len + 1, 70));
        const cap: usize = switch (rnd.uintLessThan(u8, 4)) {
            0 => 1 + rnd.uintLessThan(usize, 80),
            else => 512,
        };
        try expectSameRuns(src[start..len], cap);
    }
}

test "utf8 run decoder: every truncation and every flipped byte" {
    const text = "旦海司有幼雞讀松鼻種比門真目怪少：扒裝虎怕您跑綠蝶黃，位香法士錯乙音造活羽詞坡村目園尺" ++
        "ÀÁÂÃÄÅÆÇÈÉÊË ÌÍÎÏÐÑÒÓÔÕÖØ ŒŠÙÚÛÜÝŸÞßàá ‘’“”😀😛😇 —–§¶ ū̀n̂o᷵H̨a̠b̡͓̐ plain ASCII text, long enough for a block!";
    var buf: [text.len]u8 = undefined;
    for (0..text.len + 1) |cut| for (0..text.len) |flip| {
        if (flip % 7 != cut % 7) continue;
        @memcpy(&buf, text);
        buf[flip] ^= 0x40;
        try expectSameRuns(buf[0..cut], 512);
    };
}
