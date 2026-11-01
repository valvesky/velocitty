//! CSI parameter parsing, shared by the drain's scanner (which parses every
//! CSI once and keeps the result for the VT: `CircBuffer.preparser.csis`) and
//! `csi.zig` (which applies it). No dependency on the VT.

const std = @import("std");

pub const max_params = 16;
/// Subparameters of one CSI (at most 8 per parameter).
pub const max_subs = max_params * max_param_subs;
pub const max_param_subs = 8;

/// One `;`-separated parameter; its `:` subparameters are
/// `subs[sub_off..][0..sub_len]` of the sequence.
pub const Param = struct {
    value: u32 = 0,
    sub_off: u8 = 0,
    sub_len: u8 = 0,
};

/// A parsed CSI. `final` is 0 when the bytes are not a valid CSI (the VT
/// ignores it).
pub const Seq = struct {
    /// Packed intermediates/privates (LSB = first), matching foot.
    private: u32 = 0,
    final: u8 = 0,
    params: []const Param = &.{},
    subs: []const u32 = &.{},

    /// Value of parameter `i`, 0 when absent.
    pub inline fn value(self: Seq, i: usize) u32 {
        return if (i < self.params.len) self.params[i].value else 0;
    }

    /// The subparameters of `p` (a parameter of this sequence).
    pub inline fn subsOf(self: Seq, p: Param) []const u32 {
        return self.subs[p.sub_off..][0..p.sub_len];
    }
};

/// Stack buffers for one parse.
pub const Bufs = struct {
    params: [max_params]Param = undefined,
    subs: [max_subs]u32 = undefined,
};

const CharKind = enum(u3) { digit, semi, colon, collect, final, invalid };

const char_map: [256]CharKind = blk: {
    var map: [256]CharKind = @splat(.invalid);
    for ('0'..'9' + 1) |c| map[c] = .digit;
    map[';'] = .semi;
    map[':'] = .colon;
    for (0x20..0x2F + 1) |c| map[c] = .collect;
    for (0x3C..0x3F + 1) |c| map[c] = .collect;
    for (0x40..0x7E + 1) |c| map[c] = .final;
    break :blk map;
};

/// Parse `seq` (ESC [ ... final) into `params`/`subs` (at least
/// `max_params`/`max_subs` long); the result's slices point into them.
/// Values wrap on overflow; parameters past `max_params`, more than
/// `max_param_subs` subparameters of one parameter and subparameters past
/// `max_subs` are dropped.
pub fn parse(seq: []const u8, params: []Param, subs: []u32) Seq {
    if (seq.len < 3 or seq[0] != 0x1b or seq[1] != '[') return .{};
    const r = scan(seq, params, subs);
    return if (r.len == seq.len) r.seq else .{};
}

pub const Scanned = struct {
    /// Bytes of the sequence through its final byte; 0: no final byte yet.
    len: u32,
    seq: Seq,
};

/// Find the end of the CSI at the start of `rest` (ESC [, then up to the
/// first byte in 0x40..0x7E, as the drain cuts sequences) and parse it in
/// the same pass. A sequence holding any other byte (C0, DEL, >= 0x80)
/// still ends there but parses as invalid (`final` 0).
pub inline fn scan(rest: []const u8, param_storage: []Param, sub_storage: []u32) Scanned {
    // The drain passes spare array capacity, not fixed-size stack buffers.
    // Keep the same limits regardless of how much capacity is available.
    const params = param_storage[0..max_params];
    const subs = sub_storage[0..max_subs];
    var private: u32 = 0;
    var priv_n: u5 = 0;
    var n: usize = 0;
    var ns: usize = 0;
    var val: u32 = 0;
    var have = false;
    var in_sub = false;
    var bad = false;
    var i: usize = 2;
    while (i < rest.len) {
        const c = rest[i];
        i += 1;
        // Digits come in runs: take the whole run here.
        if (c -% '0' < 10) {
            var v = val *% 10 +% (c - '0');
            while (i < rest.len and rest[i] -% '0' < 10) : (i += 1) v = v *% 10 +% (rest[i] - '0');
            val = v;
            have = true;
            continue;
        }
        switch (char_map[c]) {
            .digit => unreachable,
            .semi => {
                push(params, subs, &n, &ns, val, in_sub);
                if (n < params.len) {
                    params[n] = .{};
                    n += 1;
                }
                val = 0;
                have = false;
                in_sub = false;
            },
            .colon => {
                if (n == 0) {
                    params[0] = .{};
                    n = 1;
                }
                const p = &params[n - 1];
                if (!in_sub) {
                    p.value = val;
                    in_sub = true;
                } else addSub(p, subs, &ns, val);
                val = 0;
                have = false;
            },
            .collect => {
                if (priv_n < 4) {
                    private |= @as(u32, c) << (8 * priv_n);
                    priv_n += 1;
                }
            },
            .invalid => bad = true,
            .final => {
                const len: u32 = @intCast(i);
                if (bad) return .{ .len = len, .seq = .{} };
                if (have or in_sub or n > 0 or i > 3) push(params, subs, &n, &ns, val, in_sub);
                return .{ .len = len, .seq = .{ .private = private, .final = c, .params = params[0..n], .subs = subs[0..ns] } };
            },
        }
    }
    return .{ .len = 0, .seq = .{} };
}

inline fn push(params: []Param, subs: []u32, n: *usize, ns: *usize, val: u32, in_sub: bool) void {
    if (n.* == 0) {
        params[0] = .{};
        n.* = 1;
    }
    const p = &params[n.* - 1];
    if (in_sub) addSub(p, subs, ns, val) else p.value = val;
}

inline fn addSub(p: *Param, subs: []u32, ns: *usize, val: u32) void {
    if (p.sub_len >= max_param_subs or ns.* >= max_subs) return;
    if (p.sub_len == 0) p.sub_off = @intCast(ns.*);
    subs[ns.*] = val;
    ns.* += 1;
    p.sub_len += 1;
}

test "scanner capacity does not change parameter limits" {
    var params: [256]Param = undefined;
    var subs: [256]u32 = undefined;
    const many = "\x1b[1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;2m";
    const s = parse(many, &params, &subs);
    try std.testing.expectEqual(@as(usize, max_params), s.params.len);
    var fixed: Bufs = .{};
    const reference = parse(many, &fixed.params, &fixed.subs);
    for (s.params, reference.params) |got, want| try std.testing.expectEqual(want.value, got.value);

    // Preserve all eight subparameters for all sixteen parameters.
    const full = "\x1b[1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9;1:2:3:4:5:6:7:8:9m";
    const t = parse(full, &params, &subs);
    try std.testing.expectEqual(@as(usize, 128), t.subs.len);
    for (t.params) |p| try std.testing.expectEqualSlices(u32, &.{ 2, 3, 4, 5, 6, 7, 8, 9 }, t.subsOf(p));
}

test "parse cup" {
    var b: Bufs = .{};
    const s = parse("\x1b[1;3H", &b.params, &b.subs);
    try std.testing.expectEqual(@as(u8, 'H'), s.final);
    try std.testing.expectEqual(@as(u32, 0), s.private);
    try std.testing.expectEqual(@as(usize, 2), s.params.len);
    try std.testing.expectEqual(@as(u32, 1), s.value(0));
    try std.testing.expectEqual(@as(u32, 3), s.value(1));
    try std.testing.expectEqual(@as(u32, 0), s.value(2));
}

test "parse private mode and intermediates" {
    var b: Bufs = .{};
    const s = parse("\x1b[?1049h", &b.params, &b.subs);
    try std.testing.expectEqual(@as(u8, 'h'), s.final);
    try std.testing.expectEqual(@as(u32, '?'), s.private);
    try std.testing.expectEqual(@as(usize, 1), s.params.len);
    try std.testing.expectEqual(@as(u32, 1049), s.value(0));
    try std.testing.expectEqual(@as(u32, 0x243F), parse("\x1b[?25$p", &b.params, &b.subs).private);
    try std.testing.expectEqual(@as(u32, ' '), parse("\x1b[4 q", &b.params, &b.subs).private);
}

test "parse subparameters" {
    var b: Bufs = .{};
    const s = parse("\x1b[1;38:2:30:60:90;4:3m", &b.params, &b.subs);
    try std.testing.expectEqual(@as(usize, 3), s.params.len);
    try std.testing.expectEqual(@as(u32, 38), s.value(1));
    try std.testing.expectEqualSlices(u32, &.{ 2, 30, 60, 90 }, s.subsOf(s.params[1]));
    try std.testing.expectEqualSlices(u32, &.{3}, s.subsOf(s.params[2]));
    try std.testing.expectEqual(@as(usize, 0), s.subsOf(s.params[0]).len);
    // At most 8 per parameter.
    const t = parse("\x1b[4:1:2:3:4:5:6:7:8:9:10m", &b.params, &b.subs);
    try std.testing.expectEqual(@as(u8, 8), t.params[0].sub_len);
}

test "parse rejects bytes a CSI cannot hold" {
    var b: Bufs = .{};
    try std.testing.expectEqual(@as(u8, 0), parse("\x1b[2\x01J", &b.params, &b.subs).final);
    try std.testing.expectEqual(@as(u8, 0), parse("\x1b[", &b.params, &b.subs).final);
    try std.testing.expectEqual(@as(usize, 0), parse("\x1b[m", &b.params, &b.subs).params.len);
    try std.testing.expectEqual(@as(usize, 2), parse("\x1b[;m", &b.params, &b.subs).params.len);
}

test "scan finds the end and parses in one pass" {
    var b: Bufs = .{};
    const r = scan("\x1b[1;31mtext", &b.params, &b.subs);
    try std.testing.expectEqual(@as(u32, 7), r.len);
    try std.testing.expectEqual(@as(u8, 'm'), r.seq.final);
    try std.testing.expectEqual(@as(u32, 31), r.seq.value(1));
    try std.testing.expectEqual(@as(u32, 0), scan("\x1b[1;3", &b.params, &b.subs).len);
    const bad = scan("\x1b[2\x01Jx", &b.params, &b.subs);
    try std.testing.expectEqual(@as(u32, 5), bad.len);
    try std.testing.expectEqual(@as(u8, 0), bad.seq.final);
}
