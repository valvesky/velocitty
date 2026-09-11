//! Type rasterizes TrueType fonts into a cached atlas.
//!
//! UTF-8 in, glyphs and metrics out. Multiple faces, fallbacks, weight,
//! style, ligatures, CJK, and emoji are in scope.
//!
//!
//! CJK and emoji classification for layout.
//!
//! BMP lookups are a 64 KiB property table painted from the UAX ranges.
//! Plane 1 uses a 256-entry page map to compact bitmaps (emoji / kana).
//! Planes 2+ (CJK unified) keep binary search on the same ranges.
//!
//! Resources:
//! - East Asian Width - UAX#11 - https://www.unicode.org/reports/tr11/
//! - Unicode Emoji - UAX#51 - https://www.unicode.org/reports/tr51/


const std = @import("std");
const assert = std.debug.assert;

pub const TrueType = @import("type/truetype.zig");
pub const Atlas = @import("type/atlas.zig").Atlas;
pub const Cache = @import("type/cache.zig");


const std = @import("std");

pub const Width = enum {
    narrow,
    wide,
    ambiguous,
    neutral,
};

const Range = struct {
    lo: u21,
    hi: u21,
};

const wide_ranges = [_]Range{
    .{ .lo = 0x1100, .hi = 0x115F },
    .{ .lo = 0x2329, .hi = 0x232A },
    .{ .lo = 0x2E80, .hi = 0x303E },
    .{ .lo = 0x3040, .hi = 0xA4CF },
    .{ .lo = 0xAC00, .hi = 0xD7A3 },
    .{ .lo = 0xF900, .hi = 0xFAFF },
    .{ .lo = 0xFE10, .hi = 0xFE19 },
    .{ .lo = 0xFE30, .hi = 0xFE6F },
    .{ .lo = 0xFF00, .hi = 0xFF60 },
    .{ .lo = 0xFFE0, .hi = 0xFFE6 },
    .{ .lo = 0x1AFF0, .hi = 0x1B122 },
    .{ .lo = 0x1B130, .hi = 0x1B152 },
    .{ .lo = 0x1B164, .hi = 0x1B167 },
    .{ .lo = 0x1B170, .hi = 0x1B2FF },
    .{ .lo = 0x20000, .hi = 0x2FFFD },
    .{ .lo = 0x30000, .hi = 0x3FFFD },
};

const ambiguous_ranges = [_]Range{
    .{ .lo = 0x00A1, .hi = 0x00A1 },
    .{ .lo = 0x00A4, .hi = 0x00A4 },
    .{ .lo = 0x00A7, .hi = 0x00A8 },
    .{ .lo = 0x00AA, .hi = 0x00AA },
    .{ .lo = 0x00AD, .hi = 0x00AE },
    .{ .lo = 0x00B0, .hi = 0x00B4 },
    .{ .lo = 0x00B6, .hi = 0x00BA },
    .{ .lo = 0x00BC, .hi = 0x00BF },
    .{ .lo = 0x00C6, .hi = 0x00C6 },
    .{ .lo = 0x00D0, .hi = 0x00D0 },
    .{ .lo = 0x00D7, .hi = 0x00D8 },
    .{ .lo = 0x00DE, .hi = 0x00E1 },
    .{ .lo = 0x00E6, .hi = 0x00E6 },
    .{ .lo = 0x00E8, .hi = 0x00EA },
    .{ .lo = 0x00EC, .hi = 0x00ED },
    .{ .lo = 0x00F0, .hi = 0x00F0 },
    .{ .lo = 0x00F2, .hi = 0x00F3 },
    .{ .lo = 0x00F7, .hi = 0x00FA },
    .{ .lo = 0x00FC, .hi = 0x00FC },
    .{ .lo = 0x00FE, .hi = 0x00FE },
    .{ .lo = 0x0101, .hi = 0x0101 },
    .{ .lo = 0x2010, .hi = 0x2010 },
    .{ .lo = 0x2013, .hi = 0x2016 },
    .{ .lo = 0x2018, .hi = 0x2019 },
    .{ .lo = 0x201C, .hi = 0x201D },
    .{ .lo = 0x2020, .hi = 0x2022 },
    .{ .lo = 0x2024, .hi = 0x2027 },
    .{ .lo = 0x2030, .hi = 0x2030 },
    .{ .lo = 0x2032, .hi = 0x2033 },
    .{ .lo = 0x2035, .hi = 0x2035 },
    .{ .lo = 0x203B, .hi = 0x203B },
    .{ .lo = 0x203E, .hi = 0x203E },
    .{ .lo = 0x2074, .hi = 0x2074 },
    .{ .lo = 0x207F, .hi = 0x207F },
    .{ .lo = 0x2081, .hi = 0x2084 },
    .{ .lo = 0x20A9, .hi = 0x20A9 },
    .{ .lo = 0x2103, .hi = 0x2103 },
    .{ .lo = 0x2105, .hi = 0x2105 },
    .{ .lo = 0x2109, .hi = 0x2109 },
    .{ .lo = 0x2113, .hi = 0x2113 },
    .{ .lo = 0x2116, .hi = 0x2116 },
    .{ .lo = 0x2121, .hi = 0x2122 },
    .{ .lo = 0x2126, .hi = 0x2126 },
    .{ .lo = 0x212B, .hi = 0x212B },
    .{ .lo = 0x2153, .hi = 0x2154 },
    .{ .lo = 0x215B, .hi = 0x215E },
    .{ .lo = 0x2160, .hi = 0x216B },
    .{ .lo = 0x2170, .hi = 0x2179 },
    .{ .lo = 0x2189, .hi = 0x2189 },
    .{ .lo = 0x2190, .hi = 0x2199 },
    .{ .lo = 0x21B8, .hi = 0x21B9 },
    .{ .lo = 0x21D2, .hi = 0x21D2 },
    .{ .lo = 0x21D4, .hi = 0x21D4 },
    .{ .lo = 0x21E7, .hi = 0x21E7 },
    .{ .lo = 0x2200, .hi = 0x2200 },
    .{ .lo = 0x2202, .hi = 0x2203 },
    .{ .lo = 0x2207, .hi = 0x2208 },
    .{ .lo = 0x220B, .hi = 0x220B },
    .{ .lo = 0x220F, .hi = 0x220F },
    .{ .lo = 0x2211, .hi = 0x2211 },
    .{ .lo = 0x2215, .hi = 0x2215 },
    .{ .lo = 0x221A, .hi = 0x221A },
    .{ .lo = 0x221D, .hi = 0x2220 },
    .{ .lo = 0x2223, .hi = 0x2223 },
    .{ .lo = 0x2225, .hi = 0x2225 },
    .{ .lo = 0x2227, .hi = 0x222C },
    .{ .lo = 0x222E, .hi = 0x222E },
    .{ .lo = 0x2234, .hi = 0x2237 },
    .{ .lo = 0x223C, .hi = 0x223D },
    .{ .lo = 0x2248, .hi = 0x2248 },
    .{ .lo = 0x224C, .hi = 0x224C },
    .{ .lo = 0x2252, .hi = 0x2252 },
    .{ .lo = 0x2260, .hi = 0x2261 },
    .{ .lo = 0x2264, .hi = 0x2267 },
    .{ .lo = 0x226A, .hi = 0x226B },
    .{ .lo = 0x226E, .hi = 0x226F },
    .{ .lo = 0x2282, .hi = 0x2283 },
    .{ .lo = 0x2286, .hi = 0x2287 },
    .{ .lo = 0x2295, .hi = 0x2295 },
    .{ .lo = 0x2299, .hi = 0x2299 },
    .{ .lo = 0x22A5, .hi = 0x22A5 },
    .{ .lo = 0x22BF, .hi = 0x22BF },
    .{ .lo = 0x2312, .hi = 0x2312 },
    .{ .lo = 0x2460, .hi = 0x24E9 },
    .{ .lo = 0x24EB, .hi = 0x254B },
    .{ .lo = 0x2550, .hi = 0x2573 },
    .{ .lo = 0x2580, .hi = 0x258F },
    .{ .lo = 0x2592, .hi = 0x2595 },
    .{ .lo = 0x25A0, .hi = 0x25A1 },
    .{ .lo = 0x25A3, .hi = 0x25A9 },
    .{ .lo = 0x25B2, .hi = 0x25B3 },
    .{ .lo = 0x25B6, .hi = 0x25B7 },
    .{ .lo = 0x25BC, .hi = 0x25BD },
    .{ .lo = 0x25C0, .hi = 0x25C1 },
    .{ .lo = 0x25C6, .hi = 0x25C8 },
    .{ .lo = 0x25CB, .hi = 0x25CB },
    .{ .lo = 0x25CE, .hi = 0x25D1 },
    .{ .lo = 0x25E2, .hi = 0x25E5 },
    .{ .lo = 0x25EF, .hi = 0x25EF },
    .{ .lo = 0x2605, .hi = 0x2606 },
    .{ .lo = 0x2609, .hi = 0x2609 },
    .{ .lo = 0x260E, .hi = 0x260F },
    .{ .lo = 0x261C, .hi = 0x261C },
    .{ .lo = 0x261E, .hi = 0x261E },
    .{ .lo = 0x2640, .hi = 0x2640 },
    .{ .lo = 0x2642, .hi = 0x2642 },
    .{ .lo = 0x2660, .hi = 0x2661 },
    .{ .lo = 0x2663, .hi = 0x2665 },
    .{ .lo = 0x2667, .hi = 0x266A },
    .{ .lo = 0x266C, .hi = 0x266D },
    .{ .lo = 0x266F, .hi = 0x266F },
    .{ .lo = 0x269E, .hi = 0x269F },
    .{ .lo = 0x26BF, .hi = 0x26BF },
    .{ .lo = 0x26C6, .hi = 0x26CD },
    .{ .lo = 0x26CF, .hi = 0x26D3 },
    .{ .lo = 0x26D5, .hi = 0x26E1 },
    .{ .lo = 0x26E3, .hi = 0x26E3 },
    .{ .lo = 0x26E8, .hi = 0x26E9 },
    .{ .lo = 0x26EB, .hi = 0x26F1 },
    .{ .lo = 0x26F4, .hi = 0x26F4 },
    .{ .lo = 0x26F6, .hi = 0x26F9 },
    .{ .lo = 0x26FB, .hi = 0x26FC },
    .{ .lo = 0x26FE, .hi = 0x26FF },
    .{ .lo = 0x273D, .hi = 0x273D },
    .{ .lo = 0x2776, .hi = 0x277F },
    .{ .lo = 0x2B56, .hi = 0x2B59 },
    .{ .lo = 0x3248, .hi = 0x324F },
    .{ .lo = 0xE000, .hi = 0xF8FF },
    .{ .lo = 0xFFFD, .hi = 0xFFFD },
};

const emoji_ranges = [_]Range{
    .{ .lo = 0x231A, .hi = 0x231B },
    .{ .lo = 0x23E9, .hi = 0x23EC },
    .{ .lo = 0x23F0, .hi = 0x23F0 },
    .{ .lo = 0x23F3, .hi = 0x23F3 },
    .{ .lo = 0x25FD, .hi = 0x25FE },
    .{ .lo = 0x2614, .hi = 0x2615 },
    .{ .lo = 0x2648, .hi = 0x2653 },
    .{ .lo = 0x267F, .hi = 0x267F },
    .{ .lo = 0x2693, .hi = 0x2693 },
    .{ .lo = 0x26A1, .hi = 0x26A1 },
    .{ .lo = 0x26AA, .hi = 0x26AB },
    .{ .lo = 0x26BD, .hi = 0x26BE },
    .{ .lo = 0x26C4, .hi = 0x26C5 },
    .{ .lo = 0x26CE, .hi = 0x26CE },
    .{ .lo = 0x26D4, .hi = 0x26D4 },
    .{ .lo = 0x26EA, .hi = 0x26EA },
    .{ .lo = 0x26F2, .hi = 0x26F3 },
    .{ .lo = 0x26F5, .hi = 0x26F5 },
    .{ .lo = 0x26FA, .hi = 0x26FA },
    .{ .lo = 0x26FD, .hi = 0x26FD },
    .{ .lo = 0x2705, .hi = 0x2705 },
    .{ .lo = 0x270A, .hi = 0x270B },
    .{ .lo = 0x2728, .hi = 0x2728 },
    .{ .lo = 0x274C, .hi = 0x274C },
    .{ .lo = 0x274E, .hi = 0x274E },
    .{ .lo = 0x2753, .hi = 0x2755 },
    .{ .lo = 0x2757, .hi = 0x2757 },
    .{ .lo = 0x2795, .hi = 0x2797 },
    .{ .lo = 0x27B0, .hi = 0x27B0 },
    .{ .lo = 0x27BF, .hi = 0x27BF },
    .{ .lo = 0x2B1B, .hi = 0x2B1C },
    .{ .lo = 0x2B50, .hi = 0x2B50 },
    .{ .lo = 0x2B55, .hi = 0x2B55 },
    .{ .lo = 0x1F004, .hi = 0x1F004 },
    .{ .lo = 0x1F0CF, .hi = 0x1F0CF },
    .{ .lo = 0x1F18E, .hi = 0x1F18E },
    .{ .lo = 0x1F191, .hi = 0x1F19A },
    .{ .lo = 0x1F1E6, .hi = 0x1F1FF },
    .{ .lo = 0x1F201, .hi = 0x1F201 },
    .{ .lo = 0x1F21A, .hi = 0x1F21A },
    .{ .lo = 0x1F22F, .hi = 0x1F22F },
    .{ .lo = 0x1F232, .hi = 0x1F236 },
    .{ .lo = 0x1F238, .hi = 0x1F23A },
    .{ .lo = 0x1F250, .hi = 0x1F251 },
    .{ .lo = 0x1F300, .hi = 0x1F64F },
    .{ .lo = 0x1F680, .hi = 0x1F6FF },
    .{ .lo = 0x1F7E0, .hi = 0x1F7EB },
    .{ .lo = 0x1F7F0, .hi = 0x1F7F0 },
    .{ .lo = 0x1F900, .hi = 0x1F9FF },
    .{ .lo = 0x1FA70, .hi = 0x1FAFF },
};

const cjk_ranges = [_]Range{
    .{ .lo = 0x1100, .hi = 0x11FF },
    .{ .lo = 0x2E80, .hi = 0x9FFF },
    .{ .lo = 0xA960, .hi = 0xA97F },
    .{ .lo = 0xAC00, .hi = 0xD7FF },
    .{ .lo = 0xF900, .hi = 0xFAFF },
    .{ .lo = 0xFE10, .hi = 0xFE1F },
    .{ .lo = 0xFE30, .hi = 0xFE6F },
    .{ .lo = 0xFF00, .hi = 0xFFEF },
    .{ .lo = 0x20000, .hi = 0x2FFFD },
    .{ .lo = 0x30000, .hi = 0x3FFFD },
};

const wide_bit: u8 = 1 << 0;
const ambig_bit: u8 = 1 << 1;
const cjk_bit: u8 = 1 << 2;
const emoji_bit: u8 = 1 << 3;

fn paint(table: *[0x10000]u8, ranges: []const Range, bit: u8) void {
    for (ranges) |r| {
        var cp: u32 = r.lo;
        if (cp > 0xFFFF) continue;
        const last = @min(@as(u32, r.hi), 0xFFFF);
        while (cp <= last) : (cp += 1) {
            table[cp] |= bit;
        }
    }
}

const bmp: [0x10000]u8 = blk: {
    @setEvalBranchQuota(500_000);
    var t: [0x10000]u8 = @splat(0);
    paint(&t, &wide_ranges, wide_bit);
    paint(&t, &ambiguous_ranges, ambig_bit);
    paint(&t, &cjk_ranges, cjk_bit);
    paint(&t, &emoji_ranges, emoji_bit);
    break :blk t;
};

/// Plane 1 is 256 pages of 256 code points. `pages[p] == 0` means empty;
/// otherwise `pages[p] - 1` indexes a 256-bit (32-byte) bitmap.
fn Plane1Tables(comptime lists: anytype) type {
    const page_count = blk: {
        var used: [256]bool = @splat(false);
        var n: usize = 0;
        for (lists) |ranges| {
            for (ranges) |r| {
                if (r.hi < 0x10000 or r.lo > 0x1FFFF) continue;
                const lo = @max(@as(u32, r.lo), 0x10000);
                const hi = @min(@as(u32, r.hi), 0x1FFFF);
                var p = (lo >> 8) & 0xFF;
                const last = (hi >> 8) & 0xFF;
                while (p <= last) : (p += 1) {
                    if (!used[p]) {
                        used[p] = true;
                        n += 1;
                    }
                }
            }
        }
        break :blk n;
    };

    return struct {
        const Data = struct {
            pages: [256]u8,
            bits: [page_count][32]u8,
        };

        const data: Data = blk: {
            @setEvalBranchQuota(200_000);
            var pages: [256]u8 = @splat(0);
            var bits: [page_count][32]u8 = undefined;
            for (&bits) |*row| row.* = @splat(0);
            var next: u8 = 1;
            for (lists) |ranges| {
                for (ranges) |r| {
                    if (r.hi < 0x10000 or r.lo > 0x1FFFF) continue;
                    var cp: u32 = @max(@as(u32, r.lo), 0x10000);
                    const last = @min(@as(u32, r.hi), 0x1FFFF);
                    while (cp <= last) : (cp += 1) {
                        const page: u8 = @truncate(cp >> 8);
                        var idx = pages[page];
                        if (idx == 0) {
                            idx = next;
                            pages[page] = next;
                            next += 1;
                        }
                        const lo: u8 = @truncate(cp);
                        bits[idx - 1][lo >> 3] |= @as(u8, 1) << @as(u3, @truncate(lo));
                    }
                }
            }
            break :blk .{ .pages = pages, .bits = bits };
        };

        inline fn has(cp: u21) bool {
            const idx = data.pages[@as(u8, @truncate(cp >> 8))];
            if (idx == 0) return false;
            const lo: u8 = @truncate(cp);
            return data.bits[idx - 1][lo >> 3] & (@as(u8, 1) << @as(u3, @truncate(lo))) != 0;
        }
    };
}

const plane1_cell = Plane1Tables(.{ &emoji_ranges, &wide_ranges });
const plane1_emoji = Plane1Tables(.{ &emoji_ranges });

fn inRanges(cp: u21, ranges: []const Range) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

pub fn width(cp: u21) Width {
    if (cp < 0x80) return .narrow;
    if (cp < 0x10000) {
        const p = bmp[cp];
        if (p & wide_bit != 0) return .wide;
        if (p & ambig_bit != 0) return .ambiguous;
        return .neutral;
    }
    if (inRanges(cp, &wide_ranges)) return .wide;
    if (inRanges(cp, &ambiguous_ranges)) return .ambiguous;
    return .neutral;
}

pub fn isCjk(cp: u21) bool {
    if (cp < 0x10000) return bmp[cp] & cjk_bit != 0;
    return inRanges(cp, &cjk_ranges);
}

pub fn isEmoji(cp: u21) bool {
    if (cp < 0x10000) return bmp[cp] & emoji_bit != 0;
    if (cp < 0x20000) return plane1_emoji.has(cp);
    return false;
}

pub fn cellWidth(cp: u21) u8 {
    if (cp < 0x10000) {
        return if (bmp[cp] & (wide_bit | emoji_bit) != 0) 2 else 1;
    }
    if (cp < 0x20000) {
        return if (plane1_cell.has(cp)) 2 else 1;
    }
    if (inRanges(cp, &wide_ranges)) return 2;
    return 1;
}

test "ascii narrow cjk wide emoji two cells" {
    try std.testing.expectEqual(Width.narrow, width('A'));
    try std.testing.expectEqual(@as(u8, 1), cellWidth('A'));
    try std.testing.expectEqual(Width.wide, width('字'));
    try std.testing.expectEqual(@as(u8, 2), cellWidth('字'));
    try std.testing.expect(isCjk('漢'));
    try std.testing.expect(isCjk('あ'));
    try std.testing.expect(isCjk('한'));
    try std.testing.expect(!isCjk('A'));
    try std.testing.expect(isEmoji(0x1F600));
    try std.testing.expectEqual(@as(u8, 2), cellWidth(0x1F600));
    try std.testing.expectEqual(Width.wide, width(0x20000));
    try std.testing.expectEqual(@as(u8, 2), cellWidth(0x20000));
    try std.testing.expect(isCjk(0x2FFFD));
    try std.testing.expect(!isEmoji('字'));
    try std.testing.expectEqual(Width.ambiguous, width(0x00A1));
    try std.testing.expectEqual(@as(u8, 1), cellWidth(0x00A1));
}

test "bmp table matches ranges" {
    var cp: u21 = 0;
    while (cp < 0x10000) : (cp += 1) {
        const p = bmp[cp];
        try std.testing.expectEqual(inRanges(cp, &wide_ranges), p & wide_bit != 0);
        try std.testing.expectEqual(inRanges(cp, &ambiguous_ranges), p & ambig_bit != 0);
        try std.testing.expectEqual(inRanges(cp, &cjk_ranges), p & cjk_bit != 0);
        try std.testing.expectEqual(inRanges(cp, &emoji_ranges), p & emoji_bit != 0);
        try std.testing.expectEqual(
            @as(u8, if (inRanges(cp, &emoji_ranges) or inRanges(cp, &wide_ranges)) 2 else 1),
            cellWidth(cp),
        );
    }
}

test "plane 1 page map matches ranges" {
    try std.testing.expectEqual(@as(u8, 2), cellWidth(0x1F600));
    try std.testing.expect(isEmoji(0x1F600));

    // U+1F000 Mahjong Tile East Wind: supplementary, neither emoji nor wide.
    try std.testing.expectEqual(inRanges(0x1F000, &emoji_ranges), isEmoji(0x1F000));
    try std.testing.expectEqual(
        @as(u8, if (inRanges(0x1F000, &emoji_ranges) or inRanges(0x1F000, &wide_ranges)) 2 else 1),
        cellWidth(0x1F000),
    );
    try std.testing.expectEqual(@as(u8, 1), cellWidth(0x1F000));
    try std.testing.expect(!isEmoji(0x1F000));

    // U+1B150 Small Hiragana Wo: plane-1 wide, not emoji.
    try std.testing.expect(inRanges(0x1B150, &wide_ranges));
    try std.testing.expect(!inRanges(0x1B150, &emoji_ranges));
    try std.testing.expectEqual(@as(u8, 2), cellWidth(0x1B150));
    try std.testing.expect(!isEmoji(0x1B150));

    var cp: u21 = 0x10000;
    while (cp < 0x20000) : (cp += 1) {
        try std.testing.expectEqual(inRanges(cp, &emoji_ranges), isEmoji(cp));
        try std.testing.expectEqual(
            @as(u8, if (inRanges(cp, &emoji_ranges) or inRanges(cp, &wide_ranges)) 2 else 1),
            cellWidth(cp),
        );
    }
}











pub const Error = error{
    InvalidFont,
    UnsupportedTable,
    GlyphNotFound,
    AtlasFull,
    InvalidUtf8,
    Unimplemented,
} || std.mem.Allocator.Error;

pub const FontId = enum(u32) { _ };

pub const Weight = enum(u16) {
    thin = 100,
    extra_light = 200,
    light = 300,
    regular = 400,
    medium = 500,
    semi_bold = 600,
    bold = 700,
    extra_bold = 800,
    black = 900,
    _,
};

pub const Style = packed struct {
    italic: bool = false,
    bold: bool = false,
};

pub const FaceOptions = struct {
    weight: ?Weight = null,
    style: Style = .{},
};

pub const Options = struct {
    atlas_width: u32 = 1024,
    atlas_height: u32 = 1024,
    cache_capacity: u32 = 2048,
    ligatures: bool = true,
    color_emoji: bool = true,
};

pub const Glyph = struct {
    font_id: FontId,
    glyph_id: u16,
    advance: f32,
    bearing_x: f32,
    bearing_y: f32,
    width: u16,
    height: u16,
    atlas_x: u16,
    atlas_y: u16,
};

pub const Cell = struct {
    glyph: Glyph,
    x: f32,
    y: f32,
    codepoint: u21,
};

pub const GlyphKey = struct {
    font_id: u32,
    glyph_id: u32,
    size_px: u16,
    flags: u16,
};

pub const ascii_lo: u21 = 32;
pub const ascii_hi: u21 = 126;
const ascii_n = ascii_hi - ascii_lo + 1;

pub const Face = struct {
    id: FontId,
    font: TrueType.Font,
    weight: Weight,
    style: Style,
};

pub const GlyphStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    raster_ns: u64 = 0,
    atlas_ns: u64 = 0,
};

/// Loaded faces, fallback order, coverage atlas, and glyph LRU.
pub const Context = struct {
    allocator: std.mem.Allocator,
    options: Options,
    faces: std.ArrayList(Face),
    fallbacks: std.ArrayList(FontId),
    primary: ?FontId,
    atlas: Atlas,
    cache: Cache.Lru(GlyphKey, Glyph),
    ascii: [ascii_n]?Glyph = @splat(null),
    replacement: ?Glyph = null,
    ascii_size: u16 = 0,
    stats: GlyphStats = .{},

    pub fn init(allocator: std.mem.Allocator, options: Options) Error!Context {
        assert(options.atlas_width > 0);
        assert(options.atlas_height > 0);
        assert(options.cache_capacity > 0);
        var atlas = try Atlas.init(allocator, options.atlas_width, options.atlas_height);
        errdefer atlas.deinit();
        const cache = try Cache.Lru(GlyphKey, Glyph).init(allocator, options.cache_capacity);
        return .{
            .allocator = allocator,
            .options = options,
            .faces = .empty,
            .fallbacks = .empty,
            .primary = null,
            .atlas = atlas,
            .cache = cache,
        };
    }

    pub fn deinit(self: *Context) void {
        self.cache.deinit();
        self.atlas.deinit();
        self.fallbacks.deinit(self.allocator);
        self.faces.deinit(self.allocator);
        self.* = undefined;
    }

    /// `bytes` must outlive this context. The first added face becomes primary.
    pub fn addFont(self: *Context, bytes: []const u8, options: FaceOptions) Error!FontId {
        const font = try TrueType.Font.open(bytes);
        const id: FontId = @enumFromInt(@as(u32, @intCast(self.faces.items.len)));
        try self.faces.append(self.allocator, .{
            .id = id,
            .font = font,
            .weight = options.weight orelse .regular,
            .style = options.style,
        });
        if (self.primary == null) self.primary = id;
        return id;
    }

    pub fn select(self: *Context, id: FontId) void {
        assert(@intFromEnum(id) < self.faces.items.len);
        self.primary = id;
    }

    pub fn setFallbacks(self: *Context, ids: []const FontId) Error!void {
        for (ids) |id| {
            assert(@intFromEnum(id) < self.faces.items.len);
        }
        self.fallbacks.clearRetainingCapacity();
        try self.fallbacks.appendSlice(self.allocator, ids);
    }

    pub fn atlasPixels(self: *const Context) []const u8 {
        return self.atlas.pixels;
    }

    /// Rasterize printable ASCII 32..126 into `ascii` at `ascii_size`.
    pub fn warmAscii(self: *Context) Error!void {
        if (self.primary == null or self.ascii_size == 0) return;
        var cp: u21 = ascii_lo;
        while (cp <= ascii_hi) : (cp += 1) {
            const slot = cp - ascii_lo;
            if (self.ascii[slot] != null) continue;
            self.ascii[slot] = try self.rasterize(cp, self.ascii_size);
        }
    }

    pub fn clearAtlas(self: *Context) void {
        self.resetGlyphCaches();
        self.warmAscii() catch {};
    }

    fn resetGlyphCaches(self: *Context) void {
        self.atlas.clear();
        self.cache.clear();
        self.ascii = @splat(null);
        self.replacement = null;
    }

    pub fn metrics(self: *const Context, size_px: f32) Error!TrueType.Metrics {
        assert(size_px > 0);
        const id = self.primary orelse return error.InvalidFont;
        return self.faces.items[@intFromEnum(id)].font.metrics(size_px);
    }

    /// Hot-path lookup. No stats, no raster, no LRU move.
    pub fn peekGlyph(self: *const Context, codepoint: u21, size_px: f32) ?Glyph {
        if (size_px <= 0) return null;
        const size_u: u16 = @intFromFloat(@max(1, @round(size_px)));
        if (size_u != self.ascii_size) return null;
        if (codepoint >= ascii_lo and codepoint <= ascii_hi) {
            return self.ascii[codepoint - ascii_lo];
        }
        if (codepoint == 0xFFFD) return self.replacement;
        const resolved = self.resolve(codepoint) catch return null;
        const key: GlyphKey = .{
            .font_id = @intFromEnum(resolved.id),
            .glyph_id = resolved.gid,
            .size_px = size_u,
            .flags = 0,
        };
        if (self.cache.peek(key)) |g| return g.*;
        return null;
    }

    pub fn ensureGlyph(self: *Context, codepoint: u21, size_px: f32) Error!Glyph {
        return self.glyph(codepoint, size_px);
    }

    pub fn glyph(self: *Context, codepoint: u21, size_px: f32) Error!Glyph {
        assert(size_px > 0);
        const size_u: u16 = @intFromFloat(@max(1, @round(size_px)));
        if (size_u != self.ascii_size) {
            self.ascii = @splat(null);
            self.replacement = null;
            self.ascii_size = size_u;
            try self.warmAscii();
        }
        if (codepoint >= ascii_lo and codepoint <= ascii_hi) {
            const slot = codepoint - ascii_lo;
            if (self.ascii[slot]) |g| {
                self.stats.hits += 1;
                return g;
            }
            const g = try self.rasterize(codepoint, size_u);
            self.ascii[slot] = g;
            return g;
        }
        if (codepoint == 0xFFFD) {
            if (self.replacement) |g| {
                self.stats.hits += 1;
                return g;
            }
            const g = try self.rasterize(codepoint, size_u);
            self.replacement = g;
            return g;
        }
        const resolved = try self.resolve(codepoint);
        const key: GlyphKey = .{
            .font_id = @intFromEnum(resolved.id),
            .glyph_id = resolved.gid,
            .size_px = size_u,
            .flags = 0,
        };
        if (self.cache.peek(key)) |g| {
            self.stats.hits += 1;
            return g.*;
        }
        const g = try self.rasterizeAt(resolved.id, resolved.gid, size_u);
        self.cache.put(key, g);
        return g;
    }

    fn rasterize(self: *Context, codepoint: u21, size_u: u16) Error!Glyph {
        const resolved = try self.resolve(codepoint);
        return self.rasterizeAt(resolved.id, resolved.gid, size_u);
    }

    fn rasterizeAt(self: *Context, id: FontId, gid: u16, size_u: u16) Error!Glyph {
        self.stats.misses += 1;
        const size: f32 = @floatFromInt(size_u);
        const face = self.faces.items[@intFromEnum(id)];
        const t0 = nowNs();
        const bmp = try face.font.rasterize(self.allocator, gid, size);
        defer self.allocator.free(bmp.pixels);
        const t1 = nowNs();
        const adv_fu = try face.font.advanceWidth(gid);
        const m = try face.font.metrics(size);
        const scale = size / @as(f32, @floatFromInt(m.units_per_em));
        const g = try self.pack(id, gid, bmp, @as(f32, @floatFromInt(adv_fu)) * scale);
        const t2 = nowNs();
        self.stats.raster_ns += @intCast(t1 - t0);
        self.stats.atlas_ns += @intCast(t2 - t1);
        return g;
    }

    pub fn layoutUtf8(self: *Context, text: []const u8, size_px: f32, out: *std.ArrayList(Cell)) Error!void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        assert(size_px > 0);
        var view = std.unicode.Utf8View.initUnchecked(text);
        var it = view.iterator();
        var x: f32 = 0;
        while (it.nextCodepoint()) |cp| {
            const g = try self.glyph(cp, size_px);
            try out.append(self.allocator, .{
                .glyph = g,
                .x = x,
                .y = 0,
                .codepoint = cp,
            });
            x += g.advance;
        }
    }

    fn resolve(self: *const Context, codepoint: u21) Error!struct { id: FontId, gid: u16 } {
        const primary = self.primary orelse return error.InvalidFont;
        if (try self.faces.items[@intFromEnum(primary)].font.glyphIndex(codepoint)) |g| {
            if (g != 0) return .{ .id = primary, .gid = g };
        }
        for (self.fallbacks.items) |id| {
            if (try self.faces.items[@intFromEnum(id)].font.glyphIndex(codepoint)) |g| {
                if (g != 0) return .{ .id = id, .gid = g };
            }
        }
        return .{ .id = primary, .gid = 0 };
    }

    fn pack(self: *Context, id: FontId, gid: u16, bmp: TrueType.Bitmap, advance: f32) Error!Glyph {
        if (bmp.width == 0 or bmp.height == 0) {
            return .{
                .font_id = id,
                .glyph_id = gid,
                .advance = advance,
                .bearing_x = @floatFromInt(bmp.bearing_x),
                .bearing_y = @floatFromInt(bmp.bearing_y),
                .width = 0,
                .height = 0,
                .atlas_x = 0,
                .atlas_y = 0,
            };
        }
        const rect = self.atlas.pack(bmp.width, bmp.height) orelse blk: {
            self.resetGlyphCaches();
            break :blk self.atlas.pack(bmp.width, bmp.height) orelse return error.AtlasFull;
        };
        self.atlas.blit(rect, bmp.pixels);
        return .{
            .font_id = id,
            .glyph_id = gid,
            .advance = advance,
            .bearing_x = @floatFromInt(bmp.bearing_x),
            .bearing_y = @floatFromInt(bmp.bearing_y),
            .width = bmp.width,
            .height = bmp.height,
            .atlas_x = @intCast(rect.x),
            .atlas_y = @intCast(rect.y),
        };
    }
};

fn nowNs() i128 {
    return @intCast(std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds);
}

test {
    _ = @import("type/truetype.zig");
    _ = @import("type/atlas.zig");
    _ = @import("type/cache.zig");
    _ = @import("type/east_asian.zig");
}

test "context init and addFont" {
    const gpa = std.testing.allocator;
    var ctx = try Context.init(gpa, .{
        .atlas_width = 64,
        .atlas_height = 64,
        .cache_capacity = 8,
    });
    defer ctx.deinit();

    var bytes: [12]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, bytes[4..6], 0, .big);
    std.mem.writeInt(u16, bytes[6..8], 0, .big);
    std.mem.writeInt(u16, bytes[8..10], 0, .big);
    std.mem.writeInt(u16, bytes[10..12], 0, .big);

    try std.testing.expectError(error.InvalidFont, ctx.addFont(&bytes, .{}));
    try std.testing.expectEqual(@as(usize, 64 * 64), ctx.atlasPixels().len);
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(gpa);
    try std.testing.expectError(error.InvalidUtf8, ctx.layoutUtf8("\x80", 16, &cells));
}

test "glyph and layout from system font" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io, "/usr/share/fonts/liberation/LiberationMono-Regular.ttf", .{}) catch return;
    defer file.close(io);
    const n = file.length(io) catch return;
    const bytes = try gpa.alloc(u8, n);
    defer gpa.free(bytes);
    _ = file.readPositionalAll(io, bytes, 0) catch return;

    var ctx = try Context.init(gpa, .{
        .atlas_width = 256,
        .atlas_height = 256,
        .cache_capacity = 32,
    });
    defer ctx.deinit();
    _ = try ctx.addFont(bytes, .{});
    const g = try ctx.glyph('A', 16);
    try std.testing.expect(g.advance > 0);
    try std.testing.expect(g.width > 0);
    try std.testing.expect(g.height > 0);
    var top: usize = 0;
    var bot: usize = 0;
    const mid = g.height / 2;
    var row: u16 = 0;
    while (row < g.height) : (row += 1) {
        var col: u16 = 0;
        while (col < g.width) : (col += 1) {
            const cover = ctx.atlas.pixels[@as(usize, g.atlas_y + row) * ctx.atlas.width + (g.atlas_x + col)];
            if (cover < 80) continue;
            if (row < mid) top += 1 else bot += 1;
        }
    }
    try std.testing.expect(bot > top);
    const again = try ctx.glyph('A', 16);
    try std.testing.expectEqual(g.atlas_x, again.atlas_x);
    try std.testing.expectEqual(g.atlas_y, again.atlas_y);

    ctx.clearAtlas();
    const hits_after_warm = ctx.stats.hits;
    const cached = try ctx.glyph('A', 16);
    try std.testing.expectEqual(hits_after_warm + 1, ctx.stats.hits);
    try std.testing.expect(cached.advance > 0);
    try std.testing.expect(cached.width > 0);
    try std.testing.expect(cached.height > 0);

    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(gpa);
    try ctx.layoutUtf8("A", 16, &cells);
    try std.testing.expectEqual(@as(usize, 1), cells.items.len);
    try std.testing.expectEqual(@as(u21, 'A'), cells.items[0].codepoint);
}
