//! Line split and cursor-tracking preparse.
//!
//! Vector scan for newline and ESC. When `whitelist` is on, payload-bearing
//! sequences (OSC, DCS, SOS, PM, APC) skip interior newlines. CSI cursor moves
//! update the tracked cursor so only on-screen lines are selected later.
//! Whitelist ESC parsing is off by default.

const std = @import("std");
const assert = std.debug.assert;
const EastAsian = @import("type/east_asian.zig");
const CircBuffer = @import("circbuffer.zig").CircBuffer;

const vec_len = std.simd.suggestVectorLength(u8) orelse 16;

comptime {
    assert(vec_len <= 64);
}

pub const Line = struct {
    off: u32,
    len: u32,
};

pub const Cursor = struct {
    row: u32 = 0,
    col: u32 = 0,
};

pub const Class = enum {
    other,
    osc,
    dcs,
    sos,
    pm,
    apc,
    csi,
    simple,
};

pub const Seq = struct {
    class: Class,
    start: usize,
    end: usize,
    complete: bool,
};

pub fn parseSeq(src: []const u8, start: usize) Seq {
    assert(start < src.len);
    assert(src[start] == 0x1b);
    if (start + 1 >= src.len) {
        return .{ .class = .other, .start = start, .end = start + 1, .complete = false };
    }
    return switch (src[start + 1]) {
        ']' => eatString(src, start, .osc, true),
        'P' => eatString(src, start, .dcs, false),
        'X' => eatString(src, start, .sos, false),
        '^' => eatString(src, start, .pm, false),
        '_' => eatString(src, start, .apc, false),
        '[' => eatCsi(src, start),
        else => eatSimple(src, start),
    };
}

fn eatSimple(src: []const u8, start: usize) Seq {
    var i = start + 1;
    while (i < src.len and src[i] >= 0x20 and src[i] <= 0x2f) i += 1;
    if (i >= src.len) {
        return .{ .class = .simple, .start = start, .end = src.len, .complete = false };
    }
    if (src[i] >= 0x30 and src[i] <= 0x7e) {
        return .{ .class = .simple, .start = start, .end = i + 1, .complete = true };
    }
    return .{ .class = .other, .start = start, .end = start + 1, .complete = true };
}

/// Last CSI intermediate byte (`0x20…0x2F`), or 0 if none.
/// `CSI ! p` → `'!'`, `CSI 2 SP q` → `' '`, `CSI ? 25 $ p` → `'$'`.
pub fn csiIntermediate(seq: []const u8) u8 {
    assert(seq.len >= 3);
    assert(seq[0] == 0x1b and seq[1] == '[');
    var i = seq.len - 1;
    while (i > 2) {
        i -= 1;
        const c = seq[i];
        if (c >= 0x20 and c <= 0x2f) return c;
        if (c >= 0x30) return 0;
    }
    return 0;
}

pub fn csiParams(seq: []const u8, out: []u16) usize {
    assert(seq.len >= 3);
    assert(seq[0] == 0x1b and seq[1] == '[');
    var n: usize = 0;
    var val: u16 = 0;
    var have = false;
    var i: usize = 2;
    while (i + 1 < seq.len) : (i += 1) {
        const c = seq[i];
        if (c >= '0' and c <= '9') {
            have = true;
            val = val *% 10 +% (c - '0');
        } else if (c == ';' or c == ':') {
            if (n < out.len) out[n] = if (have) val else 0;
            n += 1;
            val = 0;
            have = false;
        }
    }
    if (n < out.len) out[n] = if (have) val else 0;
    n += 1;
    return @min(n, out.len);
}

pub fn scan(
    allocator: std.mem.Allocator,
    input: []const u8,
    cols: u16,
    lines: *std.ArrayList(Line),
) std.mem.Allocator.Error!Cursor {
    assert(cols > 0);
    var cursor: Cursor = .{};
    var start: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c >= 0x20 and c < 0x7f) {
            const j = skipAsciiPrintable(input, i);
            try advanceAscii(allocator, lines, &cursor, &start, i, j, cols);
            i = j;
            continue;
        }
        if (c >= 0x80) {
            const j = skipHighBit(input, i);
            try advanceUtf8(allocator, lines, &cursor, input, &start, i, j, cols);
            i = j;
            continue;
        }
        if (c == 0x0a) {
            try pushLine(allocator, lines, start, i);
            cursor.row += 1;
            cursor.col = 0;
            i += 1;
            start = i;
            continue;
        }
        if (c == 0x1b) {
            const seq = parseSeq(input, i);
            switch (seq.class) {
                .osc, .dcs, .sos, .pm, .apc => {
                    i = seq.end;
                },
                .csi => {
                    if (seq.complete) applyCsi(input[seq.start..seq.end], &cursor, cols);
                    i = seq.end;
                },
                .simple => {
                    if (seq.complete) {
                        switch (input[seq.start + 1]) {
                            'E' => {
                                try pushLine(allocator, lines, start, seq.start);
                                cursor.row += 1;
                                cursor.col = 0;
                                i = seq.end;
                                start = i;
                                continue;
                            },
                            'D' => cursor.row += 1,
                            'M' => cursor.row -|= 1,
                            else => {},
                        }
                    }
                    i = seq.end;
                },
                .other => {
                    i += 1;
                },
            }
            continue;
        }
        i = try advanceAtom(allocator, lines, &cursor, input, &start, i, cols);
    }
    if (start < input.len or lines.items.len == 0) {
        try pushLine(allocator, lines, start, input.len);
    }
    return cursor;
}

fn pushLine(allocator: std.mem.Allocator, lines: *std.ArrayList(Line), start: usize, end: usize) !void {
    assert(end >= start);
    try lines.append(allocator, .{
        .off = @intCast(start),
        .len = @intCast(end - start),
    });
}

fn eatString(src: []const u8, start: usize, class: Class, bel: bool) Seq {
    var i = start + 2;
    while (i < src.len) : (i += 1) {
        if (bel and src[i] == 0x07) {
            return .{ .class = class, .start = start, .end = i + 1, .complete = true };
        }
        if (src[i] == 0x1b) {
            if (i + 1 >= src.len) {
                return .{ .class = class, .start = start, .end = src.len, .complete = false };
            }
            if (src[i + 1] == '\\') {
                return .{ .class = class, .start = start, .end = i + 2, .complete = true };
            }
        }
    }
    return .{ .class = class, .start = start, .end = src.len, .complete = false };
}

fn eatCsi(src: []const u8, start: usize) Seq {
    var i = start + 2;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c >= 0x40 and c <= 0x7e) {
            return .{ .class = .csi, .start = start, .end = i + 1, .complete = true };
        }
        if (c >= 0x20 and c <= 0x3f) continue;
        return .{ .class = .other, .start = start, .end = start + 1, .complete = true };
    }
    return .{ .class = .csi, .start = start, .end = src.len, .complete = false };
}

const Mask = std.meta.Int(.unsigned, vec_len);

/// Bytes in `[0x20, 0x7F)`. Same predicate as the AVX2 printable run in vt.
pub fn skipAsciiPrintable(input: []const u8, start: usize) usize {
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
pub fn skipHighBit(input: []const u8, start: usize) usize {
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

/// Last complete UTF-8 sequence end in `src[start..end]`. Incomplete tail is excluded.
/// O(1) in the lead: walk back over continuations instead of decoding the run.
pub fn utf8AvailableEnd(src: []const u8, start: usize, end: usize) usize {
    if (start >= end) return start;
    var i = end;
    while (i > start and src[i - 1] & 0xC0 == 0x80) i -= 1;
    if (i == start) {
        const n = std.unicode.utf8ByteSequenceLength(src[start]) catch return end;
        if (start + n > src.len or start + n > end) return start;
        return end;
    }
    const lead = i - 1;
    if (lead < start) return start;
    const n = std.unicode.utf8ByteSequenceLength(src[lead]) catch return lead;
    if (lead + n > src.len or lead + n > end) return lead;
    return end;
}

/// Soft-wrap a span that is already known to be ASCII printable (width 1).
fn advanceAscii(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    cursor: *Cursor,
    start: *usize,
    from: usize,
    to: usize,
    cols: u16,
) std.mem.Allocator.Error!void {
    const width: u32 = cols;
    var i = from;
    while (i < to) {
        if (cursor.col >= width) {
            if (i > start.*) try pushLine(allocator, lines, start.*, i);
            start.* = i;
            cursor.row += 1;
            cursor.col = 0;
            continue;
        }
        const room: usize = width - cursor.col;
        const take = @min(to - i, room);
        cursor.col += @as(u32, @intCast(take));
        i += take;
    }
}

fn advanceUtf8(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    cursor: *Cursor,
    input: []const u8,
    start: *usize,
    from: usize,
    to: usize,
    cols: u16,
) std.mem.Allocator.Error!void {
    const width: u32 = cols;
    var i = from;
    while (i < to) {
        const n = utf8Len(input, i);
        var need: u32 = 1;
        if (n >= 2) {
            const cp = std.unicode.utf8Decode(input[i..][0..n]) catch 0xFFFD;
            need = @max(EastAsian.cellWidth(cp), 1);
        }
        if (cursor.col >= width or (cursor.col > 0 and cursor.col + need > width)) {
            if (i > start.*) try pushLine(allocator, lines, start.*, i);
            start.* = i;
            cursor.row += 1;
            cursor.col = 0;
        }
        if (need == 2 and n == 3 and cursor.col + 2 <= width) {
            const room = width - cursor.col;
            var take: usize = 1;
            const max_chars = @min((to - i) / 3, room / 2);
            var k = i + 3;
            while (take < max_chars) {
                if (utf8Len(input, k) != 3) break;
                const cp = std.unicode.utf8Decode(input[k..][0..3]) catch break;
                if (EastAsian.cellWidth(cp) != 2) break;
                k += 3;
                take += 1;
            }
            cursor.col += @as(u32, @intCast(take * 2));
            i += take * 3;
            continue;
        }
        cursor.col += need;
        i += n;
    }
}

fn advanceAtom(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    cursor: *Cursor,
    input: []const u8,
    start: *usize,
    at: usize,
    cols: u16,
) std.mem.Allocator.Error!usize {
    const c = input[at];
    switch (c) {
        '\r' => {
            cursor.col = 0;
            return at + 1;
        },
        0x08 => {
            cursor.col -|= 1;
            return at + 1;
        },
        '\t' => {
            cursor.col += 8 - (cursor.col % 8);
            if (cursor.col >= cols) cursor.col = cols - 1;
            return at + 1;
        },
        else => {
            if (c < 0x20) return at + 1;
            var n: usize = 1;
            var need: u32 = 1;
            if (c >= 0x80) {
                n = utf8Len(input, at);
                const cp = std.unicode.utf8Decode(input[at..][0..n]) catch 0xFFFD;
                need = @max(EastAsian.cellWidth(cp), 1);
            }
            if (cursor.col >= cols or (cursor.col > 0 and cursor.col + need > cols)) {
                if (at > start.*) try pushLine(allocator, lines, start.*, at);
                start.* = at;
                cursor.row += 1;
                cursor.col = 0;
            }
            cursor.col += need;
            return at + n;
        },
    }
}

fn utf8Len(bytes: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return 1;
    if (i + n > bytes.len) return 1;
    return n;
}

/// Incremental NL split of unparsed bytes. When `whitelist` is set, payload-
/// bearing ESC is skipped so interior newlines do not become lines, and an
/// incomplete sequence stops the consume. Off (default) treats ESC as a byte.
/// Returns bytes consumed.
pub fn consume(buf: *CircBuffer, whitelist: bool) usize {
    const src = buf.unparsed();
    const base = buf.parsed;
    var start: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c >= 0x20 and c < 0x7f) {
            i = skipAsciiPrintable(src, i);
            continue;
        }
        if (c == 0x0a) {
            buf.pushLine(base + start, @intCast(i - start));
            i += 1;
            start = i;
            continue;
        }
        if (c == 0x1b) {
            if (!whitelist) {
                i += 1;
                continue;
            }
            const seq = parseSeq(src, i);
            if (!seq.complete) break;
            i = seq.end;
            continue;
        }
        if (c >= 0x80) {
            const raw = skipHighBit(src, i);
            const end = utf8AvailableEnd(src, i, raw);
            if (end == i) break;
            i = end;
            continue;
        }
        i += 1;
    }
    if (start < i) buf.pushLine(base + start, @intCast(i - start));
    buf.advanceParsed(i);
    return i;
}

fn applyCsi(seq: []const u8, cursor: *Cursor, cols: u16) void {
    var params: [2]u16 = .{ 0, 0 };
    const nparams = csiParams(seq, &params);
    const final = seq[seq.len - 1];
    const n: u32 = if (params[0] == 0) 1 else params[0];
    switch (final) {
        'A' => cursor.row -|= n,
        'B' => cursor.row += n,
        'C' => {
            cursor.col += n;
            if (cursor.col >= cols) cursor.col = cols - 1;
        },
        'D' => cursor.col -|= n,
        'E' => {
            cursor.row += n;
            cursor.col = 0;
        },
        'F' => {
            cursor.row -|= n;
            cursor.col = 0;
        },
        'G', '`' => {
            cursor.col = n -| 1;
            if (cursor.col >= cols) cursor.col = cols - 1;
        },
        'a' => {
            cursor.col += n;
            if (cursor.col >= cols) cursor.col = cols - 1;
        },
        'e' => cursor.row += n,
        'H', 'f' => {
            const r: u32 = if (nparams < 1 or params[0] == 0) 1 else params[0];
            const c: u32 = if (nparams < 2 or params[1] == 0) 1 else params[1];
            cursor.row = r -| 1;
            cursor.col = c -| 1;
            if (cursor.col >= cols) cursor.col = cols - 1;
        },
        'd' => {
            cursor.row = n -| 1;
        },
        else => {},
    }
}

test "split newlines" {
    const gpa = std.testing.allocator;
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    const cursor = try scan(gpa, "a\nb\n", 80, &lines);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("a", "a\nb\n"[lines.items[0].off..][0..lines.items[0].len]);
    try std.testing.expectEqualStrings("b", "a\nb\n"[lines.items[1].off..][0..lines.items[1].len]);
    try std.testing.expectEqual(@as(u32, 2), cursor.row);
    try std.testing.expectEqual(@as(u32, 0), cursor.col);
}

test "osc interior newlines do not split" {
    const gpa = std.testing.allocator;
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    const src = "hello\x1b]0;title\nwith\nnl\x07world";
    const cursor = try scan(gpa, src, 80, &lines);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(u32, 0), cursor.row);
    try std.testing.expectEqual(@as(u32, 10), cursor.col);
}

test "csi cup" {
    const gpa = std.testing.allocator;
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    const cursor = try scan(gpa, "\x1b[10;5H", 80, &lines);
    try std.testing.expectEqual(@as(u32, 9), cursor.row);
    try std.testing.expectEqual(@as(u32, 4), cursor.col);
}

test "csi hpa hpr vpr" {
    const gpa = std.testing.allocator;
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    const cursor = try scan(gpa, "\x1b[10`\x1b[3a\x1b[2e", 80, &lines);
    try std.testing.expectEqual(@as(u32, 2), cursor.row);
    try std.testing.expectEqual(@as(u32, 12), cursor.col);
}

test "csi intermediate" {
    try std.testing.expectEqual(@as(u8, '!'), csiIntermediate("\x1b[!p"));
    try std.testing.expectEqual(@as(u8, ' '), csiIntermediate("\x1b[2 q"));
    try std.testing.expectEqual(@as(u8, '$'), csiIntermediate("\x1b[?25$p"));
    try std.testing.expectEqual(@as(u8, 0), csiIntermediate("\x1b[2q"));
    try std.testing.expectEqual(@as(u8, 0), csiIntermediate("\x1b[31m"));
}

test "csi colon params" {
    var params: [8]u16 = @splat(0);
    const n = csiParams("\x1b[38:2::10:20:30m", &params);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqual(@as(u16, 38), params[0]);
    try std.testing.expectEqual(@as(u16, 2), params[1]);
    try std.testing.expectEqual(@as(u16, 0), params[2]);
    try std.testing.expectEqual(@as(u16, 10), params[3]);
    try std.testing.expectEqual(@as(u16, 20), params[4]);
    try std.testing.expectEqual(@as(u16, 30), params[5]);
}

test "vector path long line" {
    const gpa = std.testing.allocator;
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    const src = "0123456789abcdef0123456789abcdef0123456789\nxyz";
    _ = try scan(gpa, src, 80, &lines);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("xyz", src[lines.items[1].off..][0..lines.items[1].len]);
}

test "soft wrap splits visual rows" {
    const gpa = std.testing.allocator;
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    const src = "abcdefghij";
    _ = try scan(gpa, src, 4, &lines);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("abcd", src[lines.items[0].off..][0..lines.items[0].len]);
    try std.testing.expectEqualStrings("efgh", src[lines.items[1].off..][0..lines.items[1].len]);
    try std.testing.expectEqualStrings("ij", src[lines.items[2].off..][0..lines.items[2].len]);
}

test "soft wrap does not repeat the prefix" {
    const gpa = std.testing.allocator;
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    const src = "aaaabbbbcc";
    _ = try scan(gpa, src, 4, &lines);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("aaaa", src[lines.items[0].off..][0..lines.items[0].len]);
    try std.testing.expectEqualStrings("bbbb", src[lines.items[1].off..][0..lines.items[1].len]);
    try std.testing.expectEqualStrings("cc", src[lines.items[2].off..][0..lines.items[2].len]);
}

test "esc charset designation is one sequence" {
    const seq = parseSeq("\x1b(0", 0);
    try std.testing.expectEqual(Class.simple, seq.class);
    try std.testing.expectEqual(@as(usize, 3), seq.end);
    try std.testing.expect(seq.complete);
    const ris = parseSeq("\x1bc", 0);
    try std.testing.expectEqual(Class.simple, ris.class);
    try std.testing.expectEqual(@as(usize, 2), ris.end);
}

test "soft wrap then newline does not add an empty row" {
    const gpa = std.testing.allocator;
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    const src = "abcd\nxy";
    _ = try scan(gpa, src, 4, &lines);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("abcd", src[lines.items[0].off..][0..lines.items[0].len]);
    try std.testing.expectEqualStrings("xy", src[lines.items[1].off..][0..lines.items[1].len]);
}

test "consume splits NL and skips osc interior" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.init(gpa, 64);
    defer buf.deinit();
    buf.write("ab\ncd\n");
    _ = consume(&buf, true);
    try std.testing.expectEqual(@as(u32, 2), buf.line_n);
    buf.write("hello\x1b]0;title\nwith\nnl\x07world");
    _ = consume(&buf, true);
    try std.testing.expectEqual(@as(u32, 3), buf.line_n);
}

test "consume without whitelist splits osc interior NL" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.init(gpa, 64);
    defer buf.deinit();
    buf.write("hello\x1b]0;title\nwith\nnl\x07world");
    _ = consume(&buf, false);
    try std.testing.expectEqual(@as(u32, 3), buf.line_n);
}

test "skipHighBit stops at ascii" {
    const src = "汉字ab";
    try std.testing.expectEqual(@as(usize, 6), skipHighBit(src, 0));
    try std.testing.expectEqual(@as(usize, src.len), skipAsciiPrintable(src, 6));
}
