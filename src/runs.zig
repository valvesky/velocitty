//! Split a visible line into typed runs.

const std = @import("std");
const Preparse = @import("preparse.zig");

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

pub const Run = struct {
    kind: Kind,
    off: u32,
    len: u32,
};

pub fn split(allocator: std.mem.Allocator, src: []const u8, out: *std.ArrayList(Run)) std.mem.Allocator.Error!void {
    _ = try splitAvailable(allocator, src, out);
}

/// Like `split`, but stops before an incomplete ESC / UTF-8 sequence.
/// Returns bytes consumed.
pub fn splitAvailable(allocator: std.mem.Allocator, src: []const u8, out: *std.ArrayList(Run)) std.mem.Allocator.Error!usize {
    var i: usize = 0;
    while (i < src.len) {
        const start = i;
        const b = src[i];
        if (b == 0x1b) {
            const seq = Preparse.parseSeq(src, i);
            if (!seq.complete) break;
            const kind = escKind(src, seq);
            try out.append(allocator, .{
                .kind = kind,
                .off = @intCast(start),
                .len = @intCast(seq.end - start),
            });
            i = seq.end;
            continue;
        }
        if (b >= 0x80) {
            const n = std.unicode.utf8ByteSequenceLength(b) catch {
                const kind = Kind.c1;
                i = endOfRun(src, start, kind);
                try out.append(allocator, .{
                    .kind = kind,
                    .off = @intCast(start),
                    .len = @intCast(i - start),
                });
                continue;
            };
            if (n >= 2 and start + n > src.len) break;
            const raw = Preparse.skipHighBit(src, start);
            const end = Preparse.utf8AvailableEnd(src, start, raw);
            if (end == start) break;
            try out.append(allocator, .{
                .kind = .utf8,
                .off = @intCast(start),
                .len = @intCast(end - start),
            });
            i = end;
            continue;
        }
        const kind = classify(src, i);
        i = endOfRun(src, i, kind);
        try out.append(allocator, .{
            .kind = kind,
            .off = @intCast(start),
            .len = @intCast(i - start),
        });
    }
    return i;
}

fn classify(src: []const u8, i: usize) Kind {
    const b = src[i];
    if (b == 0x1b) return escKind(src, Preparse.parseSeq(src, i));
    if (b < 0x20) return .c0;
    if (b < 0x7f) return .plain;
    if (b == 0x7f) return .c1;
    const n = std.unicode.utf8ByteSequenceLength(b) catch return .c1;
    if (n >= 2 and i + n <= src.len) return .utf8;
    return .c1;
}

fn escKind(src: []const u8, seq: Preparse.Seq) Kind {
    switch (seq.class) {
        .csi => return .csi,
        .osc => return .osc,
        .apc => {
            if (seq.start + 2 < src.len and src[seq.start + 2] == 'G') return .esc_kitty;
            return .str;
        },
        .dcs => {
            var j = seq.start + 2;
            while (j < seq.end and src[j] >= 0x30 and src[j] <= 0x3f) j += 1;
            while (j < seq.end and src[j] >= 0x20 and src[j] <= 0x2f) j += 1;
            if (j < seq.end and src[j] == 'q') return .esc_sixel;
            return .str;
        },
        .sos, .pm => return .str,
        .simple, .other => return .esc,
    }
}

fn endOfRun(src: []const u8, start: usize, kind: Kind) usize {
    var i = start;
    switch (kind) {
        .esc, .csi, .osc, .str, .esc_kitty, .esc_sixel => return Preparse.parseSeq(src, start).end,
        .plain => return Preparse.skipAsciiPrintable(src, start),
        .c0 => {
            while (i < src.len and src[i] < 0x20 and src[i] != 0x1b) i += 1;
        },
        .c1 => {
            while (i < src.len) : (i += 1) {
                if (classify(src, i) != .c1) break;
            }
        },
        .utf8 => {
            const raw = Preparse.skipHighBit(src, start);
            return Preparse.utf8AvailableEnd(src, start, raw);
        },
    }
    if (i == start) i += 1;
    return i;
}

test "plain and c0" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Run) = .empty;
    defer out.deinit(gpa);
    const src = "a\x07b";
    try split(gpa, src, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(Kind.plain, out.items[0].kind);
    try std.testing.expectEqual(Kind.c0, out.items[1].kind);
    try std.testing.expectEqual(Kind.plain, out.items[2].kind);
}

test "utf8" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Run) = .empty;
    defer out.deinit(gpa);
    try split(gpa, "é", &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(Kind.utf8, out.items[0].kind);
    try std.testing.expectEqual(@as(u32, 2), out.items[0].len);
}

test "csi osc str" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Run) = .empty;
    defer out.deinit(gpa);
    try split(gpa, "\x1b[0m", &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(Kind.csi, out.items[0].kind);
    out.clearRetainingCapacity();
    try split(gpa, "\x1b]0;title\x07", &out);
    try std.testing.expectEqual(Kind.osc, out.items[0].kind);
    out.clearRetainingCapacity();
    try split(gpa, "hello\x1b]0;title\nwith\nnl\x1b\\world", &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(Kind.plain, out.items[0].kind);
    try std.testing.expectEqual(Kind.osc, out.items[1].kind);
    try std.testing.expectEqual(Kind.plain, out.items[2].kind);
    out.clearRetainingCapacity();
    try split(gpa, "\x1b^payload\x1b\\", &out);
    try std.testing.expectEqual(Kind.str, out.items[0].kind);
}

test "incomplete esc is not consumed" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Run) = .empty;
    defer out.deinit(gpa);
    const n = try splitAvailable(gpa, "ab\x1b[31", &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(Kind.plain, out.items[0].kind);
}

test "kitty and sixel" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Run) = .empty;
    defer out.deinit(gpa);
    try split(gpa, "\x1b_Ga=T,f=24;AA\x1b\\", &out);
    try std.testing.expectEqual(Kind.esc_kitty, out.items[0].kind);
    out.clearRetainingCapacity();
    try split(gpa, "\x1bPq#0;2;0;0;0\x1b\\", &out);
    try std.testing.expectEqual(Kind.esc_sixel, out.items[0].kind);
}
