//! Extended grapheme clusters (UAX #29, Unicode 18) and the per-codepoint
//! cell width the VT prints with. One two-stage table lookup (generated
//! into `grapheme_table.zig` by scripts/gen_grapheme.py) gives the width
//! (`EastAsian.cellWidth`, or 0 for code points that join the previous
//! cell), the break class and whether VS15/VS16 may follow.
const std = @import("std");
const Table = @import("grapheme_table.zig");
const EastAsian = @import("eastasian.zig");

/// Grapheme_Cluster_Break with the Indic_Conjunct_Break distinctions GB9c
/// needs. Order is the generator's `CLASSES`.
pub const Class = enum(u5) {
    other,
    control,
    cr,
    lf,
    prepend,
    spacing_mark,
    l,
    v,
    t,
    lv,
    lvt,
    regional_indicator,
    ext_pict,
    zwj,
    /// GCB=Extend, InCB=None (ZWNJ and a few others).
    extend,
    /// GCB=Extend, InCB=Extend.
    extend_incb,
    /// GCB=Extend, InCB=Linker (viramas).
    extend_linker,
    /// GCB=Other, InCB=Consonant.
    consonant,
    /// InCB=Linker that is not Extend.
    linker_other,
    linker_spacing,
    _,
};

pub const Props = packed struct(u8) {
    /// Cells: 0 joins the previous cell (marks, ZWJ, variation selectors,
    /// other default ignorables, Hangul V/T), else 1 or 2.
    width: u2,
    class: Class,
    /// Has a VS15/VS16 sequence (emoji-variation-sequences.txt).
    vs_base: bool,
};

const mask: u21 = (1 << Table.shift) - 1;

/// Two loads; any u21 is in range (past U+10FFFF: width 1, Other).
pub inline fn props(cp: u21) Props {
    const block: u32 = Table.stage1[cp >> Table.shift];
    return @bitCast(Table.stage2[(block << Table.shift) | (cp & mask)]);
}

pub inline fn isExtend(c: Class) bool {
    return c == .extend or c == .extend_incb or c == .extend_linker;
}

inline fn isLinker(c: Class) bool {
    return c == .extend_linker or c == .linker_other or c == .linker_spacing;
}

inline fn isControl(c: Class) bool {
    return c == .control or c == .cr or c == .lf;
}

/// What the rules need to know about the text before a boundary, as
/// sequences ending at the last code point.
pub const State = packed struct(u8) {
    /// ExtPict Extend* (GB11).
    pict: bool = false,
    /// ExtPict Extend* ZWJ (GB11).
    pict_zwj: bool = false,
    /// An odd number of regional indicators (GB12/13).
    ri: bool = false,
    /// InCB=Linker [InCB=Extend InCB=Linker]* (GB9c).
    linker: bool = false,
    _pad: u4 = 0,

    /// The state after a code point of class `c` that follows `s`.
    pub inline fn advance(s: State, c: Class) State {
        return .{
            .pict = c == .ext_pict or (isExtend(c) and s.pict),
            .pict_zwj = c == .zwj and s.pict,
            .ri = c == .regional_indicator and !s.ri,
            .linker = isLinker(c) or ((c == .extend_incb or c == .zwj) and s.linker),
        };
    }

    /// The state after a code point that starts a cluster.
    pub inline fn start(c: Class) State {
        return advance(.{}, c);
    }
};

/// Is there a boundary between `c1` and `c2`, where `s` describes the text
/// ending with `c1`?
pub fn breaks(s: State, c1: Class, c2: Class) bool {
    if (c1 == .cr and c2 == .lf) return false; // GB3
    if (isControl(c1) or isControl(c2)) return true; // GB4, GB5
    switch (c1) { // GB6-8
        .l => if (c2 == .l or c2 == .v or c2 == .lv or c2 == .lvt) return false,
        .lv, .v => if (c2 == .v or c2 == .t) return false,
        .lvt, .t => if (c2 == .t) return false,
        else => {},
    }
    if (isExtend(c2) or c2 == .zwj) return false; // GB9
    if (c2 == .spacing_mark or c2 == .linker_spacing) return false; // GB9a
    if (c1 == .prepend) return false; // GB9b
    if (s.linker and c2 == .consonant) return false; // GB9c
    if (s.pict_zwj and c2 == .ext_pict) return false; // GB11
    if (s.ri and c1 == .regional_indicator and c2 == .regional_indicator) return false; // GB12/13
    return true; // GB999
}

/// `always[c1] >> c2 & 1`: `breaks` holds for every state, so a printer can
/// start a new cell without tracking state.
const always: [32]u32 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [32]u32 = @splat(0);
    for (0..32) |a| for (0..32) |b| {
        var all = true;
        for (0..16) |bits| {
            const s: State = @bitCast(@as(u8, @intCast(bits)));
            if (!breaks(s, @enumFromInt(a), @enumFromInt(b))) all = false;
        }
        if (all) t[a] |= @as(u32, 1) << @intCast(b);
    };
    break :blk t;
};

pub inline fn alwaysBreaks(c1: Class, c2: Class) bool {
    return always[@intFromEnum(c1)] >> @intFromEnum(c2) & 1 != 0;
}

/// How a code point that continues a cluster (mode 2027) changes its width,
/// as Ghostty does it: VS16/VS15 after a variation base make the cluster
/// wide/narrow (after anything else they are dropped); a code point with
/// width of its own (not a mark, ZWJ, emoji modifier or Prepend) makes it
/// wide.
pub const Effect = enum { ignore, keep, wide, narrow };

pub inline fn effect(prev: Props, cp: u21, p: Props) Effect {
    if (cp == 0xFE0F or cp == 0xFE0E) {
        if (!prev.vs_base) return .ignore;
        return if (cp == 0xFE0F) .wide else .narrow;
    }
    if (p.width != 0 and p.class != .prepend and !(cp >= 0x1F3FB and cp <= 0x1F3FF)) return .wide;
    return .keep;
}

test "GraphemeBreakTest.txt" {
    for (Table.break_tests, 0..) |case, n| {
        var s: State = .{};
        var prev: Class = .control;
        for (case, 0..) |v, i| {
            const cp: u21 = @intCast(v & 0x1FFFFF);
            const want = v & 0x8000_0000 != 0;
            const c = props(cp).class;
            if (i != 0) {
                const got = breaks(s, prev, c);
                if (got != want) {
                    std.debug.print("case {d} index {d} U+{X:0>4}: want break={}\n", .{ n, i, cp, want });
                    return error.TestUnexpectedResult;
                }
                if (got) s = .{};
                // `always` never claims a break that a state would refuse.
                if (alwaysBreaks(prev, c)) try std.testing.expect(got);
            }
            s = s.advance(c);
            prev = c;
        }
    }
}

test "widths match EastAsian.cellWidth except zero width" {
    var cp: u21 = 0;
    while (cp < 0x110000) : (cp += 1) {
        const p = props(cp);
        if (p.width == 0) continue;
        if (p.width != EastAsian.cellWidth(cp)) {
            std.debug.print("U+{X:0>4}: table {d} cellWidth {d}\n", .{ cp, p.width, EastAsian.cellWidth(cp) });
            return error.TestUnexpectedResult;
        }
    }
}

test "classes and widths of a few code points" {
    try std.testing.expectEqual(Class.other, props('a').class);
    try std.testing.expectEqual(@as(u2, 1), props('a').width);
    try std.testing.expectEqual(@as(u2, 0), props(0x0301).width);
    try std.testing.expectEqual(@as(u2, 0), props(0x200D).width);
    try std.testing.expectEqual(Class.zwj, props(0x200D).class);
    try std.testing.expectEqual(@as(u2, 0), props(0xFE0F).width);
    try std.testing.expectEqual(@as(u2, 2), props(0x1F3FB).width);
    try std.testing.expectEqual(Class.regional_indicator, props(0x1F1FA).class);
    try std.testing.expectEqual(Class.ext_pict, props(0x1F600).class);
    try std.testing.expectEqual(@as(u2, 2), props(0x1F600).width);
    try std.testing.expectEqual(Class.l, props(0x1100).class);
    try std.testing.expectEqual(@as(u2, 0), props(0x1161).width);
    try std.testing.expectEqual(Class.lv, props(0xAC00).class);
    try std.testing.expect(props(0x2764).vs_base);
    try std.testing.expect(!props('a').vs_base);
    try std.testing.expectEqual(@as(u2, 1), props(0x00AD).width);
    try std.testing.expect(alwaysBreaks(.other, .other));
    try std.testing.expect(!alwaysBreaks(.prepend, .other));
    try std.testing.expect(!alwaysBreaks(.regional_indicator, .regional_indicator));
    try std.testing.expect(!alwaysBreaks(.zwj, .ext_pict));
}
