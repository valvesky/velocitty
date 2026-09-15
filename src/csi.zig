//! CSI (ESC [) parse + apply, following foot's ctlseqs.

const std = @import("std");
const Vt = @import("vt.zig").VtState;
const Color = @import("vt.zig").Color;

const CsiSeq = @This();

pub const Param = struct {
    value: u32 = 0,
    sub: [8]u32 = @splat(0),
    sub_len: u8 = 0,
};

/// Packed intermediates/privates (LSB = first), matching foot.
private: u32 = 0,
final: u8 = 0,
seq: []const u8 = "",
params: []Param = &.{},

const CharKind = enum(u3) { digit, semi, colon, collect, final, invalid };

const CHAR_MAP: [256]CharKind = initMap: {
    var map = [_]CharKind{.invalid} ** 256;
    for ('0'..'9' + 1) |c| map[c] = .digit;
    map[';'] = .semi;
    map[':'] = .colon;
    for (0x20..0x2F + 1) |c| map[c] = .collect;
    for (0x3C..0x3F + 1) |c| map[c] = .collect;
    for (0x40..0x7E + 1) |c| map[c] = .final;
    break :initMap map;
};

pub fn parse(seq: []const u8, param_buf: []Param) CsiSeq {
    const stub = CsiSeq{ .final = 0, .seq = seq };
    if (seq.len < 3 or seq[0] != 0x1b or seq[1] != '[') return stub;

    var private: u32 = 0;
    var priv_n: u5 = 0;
    var n: usize = 0;
    var val: u32 = 0;
    var have: bool = false;
    var in_sub: bool = false;
    var ok: bool = true;

    const max_body = seq.len - 1;
    var i: usize = 2;
    while (i < max_body) : (i += 1) {
        const c = seq[i];
        switch (CHAR_MAP[c]) {
            .digit => {
                have = true;
                val = val *% 10 +% (c - '0');
            },
            .semi => {
                pushValue(param_buf, &n, &val, &have, &in_sub);
                if (n < param_buf.len) {
                    param_buf[n] = .{};
                    n += 1;
                }
                val = 0;
                have = false;
                in_sub = false;
            },
            .colon => {
                ensureParam(param_buf, &n, have or in_sub or n == 0);
                if (n > 0) {
                    var p = &param_buf[n - 1];
                    if (!in_sub) {
                        p.value = val;
                        in_sub = true;
                    } else if (p.sub_len < p.sub.len) {
                        p.sub[p.sub_len] = val;
                        p.sub_len += 1;
                    }
                }
                val = 0;
                have = false;
            },
            .collect => {
                if (priv_n < 4) {
                    private |= @as(u32, c) << (8 * priv_n);
                    priv_n += 1;
                }
            },
            .final, .invalid => ok = false,
        }
    }

    if (have or in_sub or n > 0 or seq.len > 3) {
        pushValue(param_buf, &n, &val, &have, &in_sub);
    }

    const final_byte = seq[seq.len - 1];
    if (!ok or CHAR_MAP[final_byte] != .final) return stub;

    return .{
        .private = private,
        .final = final_byte,
        .seq = seq,
        .params = param_buf[0..n],
    };
}

fn ensureParam(buf: []Param, n: *usize, needed: bool) void {
    if (!needed) return;
    if (n.* == 0 and buf.len > 0) {
        buf[0] = .{};
        n.* = 1;
    }
}

fn pushValue(buf: []Param, n: *usize, val: *u32, have: *bool, in_sub: *bool) void {
    if (n.* == 0) {
        if (buf.len == 0) return;
        buf[0] = .{};
        n.* = 1;
    }
    var p = &buf[n.* - 1];
    if (in_sub.*) {
        if (p.sub_len < p.sub.len) {
            p.sub[p.sub_len] = val.*;
            p.sub_len += 1;
        }
    } else {
        p.value = val.*;
    }
    _ = have;
}

pub fn apply(self: CsiSeq, vt: *Vt) void {
    if (self.final == 0) return;
    const params = self.params;

    switch (self.private) {
        0 => applyAnsi(self.final, params, vt),
        '?' => applyDec(self.final, params, vt),
        '>' => applyGt(self.final, params, vt),
        '<' => applyLt(self.final, params, vt),
        ' ' => applySpace(self.final, params, vt),
        '!' => if (self.final == 'p') vt.softReset(),
        '=' => applyEq(self.final, params, vt),
        '$' => applyDollar(self.final, params, vt),
        '#' => applyHash(self.final, params, vt),
        0x243F => applyDecDollar(self.final, params, vt),
        else => {},
    }
}

fn pget(params: []const Param, idx: usize, default: u32) u32 {
    if (idx >= params.len) return default;
    const v = params[idx].value;
    return if (v != 0) v else default;
}

fn sat16(v: u32) u16 {
    return @intCast(@min(v, 65535));
}

fn applyAnsi(final: u8, params: []const Param, vt: *Vt) void {
    const p0 = sat16(if (params.len > 0) params[0].value else 0);
    const n1 = sat16(pget(params, 0, 1));

    switch (final) {
        'b' => vt.rep(n1),
        'c' => if (p0 == 0) vt.respond("\x1b[?62;22;28c"),
        'd' => vt.cup(n1, vt.grid().cursor.col + 1),
        'm' => sgr(params, vt),
        'n' => switch (p0) {
            5 => vt.respond("\x1b[0n"),
            6 => respondCursor(vt),
            else => {},
        },
        'A' => vt.cuu(n1),
        'e', 'B' => vt.cud(n1),
        'a', 'C' => vt.cuf(n1),
        'D' => vt.cub(n1),
        'E' => {
            vt.cud(n1);
            vt.carriageReturn();
        },
        'F' => {
            vt.cuu(n1);
            vt.carriageReturn();
        },
        'g' => vt.tabClear(p0),
        '`', 'G' => vt.setCol(n1 -| 1),
        'f', 'H' => vt.cup(n1, sat16(pget(params, 1, 1))),
        'J' => vt.ed(p0),
        'K' => vt.el(p0),
        'L' => {
            vt.il(n1);
            vt.carriageReturn();
        },
        'M' => {
            vt.dl(n1);
            vt.carriageReturn();
        },
        'P' => vt.dch(n1),
        '@' => vt.ich(n1),
        'S' => vt.regionScrollUp(n1),
        'T' => vt.regionScrollDown(n1),
        'X' => vt.ech(n1),
        'I' => vt.tabForward(n1),
        'Z' => vt.tabBackN(n1),
        'h' => {
            var buf: [16]u32 = undefined;
            vt.setMode(copyParams(params, &buf), true);
        },
        'l' => {
            var buf: [16]u32 = undefined;
            vt.setMode(copyParams(params, &buf), false);
        },
        'r' => vt.decstbm(p0, sat16(if (params.len > 1) params[1].value else 0)),
        's' => vt.saveCursor(),
        'u' => vt.restoreCursor(),
        't' => windowOp(params, vt),
        else => {},
    }
}

fn applyDec(final: u8, params: []const Param, vt: *Vt) void {
    const p0 = if (params.len > 0) params[0].value else 0;
    switch (final) {
        'h' => {
            var buf: [16]u32 = undefined;
            vt.setPrivate(copyParams(params, &buf), true);
        },
        'l' => {
            var buf: [16]u32 = undefined;
            vt.setPrivate(copyParams(params, &buf), false);
        },
        's' => {
            var buf: [16]u32 = undefined;
            vt.savePrivate(copyParams(params, &buf));
        },
        'r' => {
            var buf: [16]u32 = undefined;
            vt.restorePrivate(copyParams(params, &buf));
        },
        'n' => switch (p0) {
            6 => respondCursor(vt),
            996 => vt.respond(if (vt.dark_theme) "\x1b[?997;1n" else "\x1b[?997;2n"),
            998 => vt.respond(if (vt.visible) "\x1b[?999;1n" else "\x1b[?999;2n"),
            else => {},
        },
        'm' => xtqmodkeys(params, vt),
        'u' => vt.kittyKbdQuery(),
        'p' => {
            // ANSI DECRQM without '$' is not this branch.
        },
        else => {},
    }
}

fn applyGt(final: u8, params: []const Param, vt: *Vt) void {
    const p0 = if (params.len > 0) params[0].value else 0;
    switch (final) {
        'c' => if (p0 == 0) vt.respond("\x1b[>1;000001;0c"),
        'm' => {
            var buf: [16]u32 = undefined;
            vt.setModifyKeys(copyParams(params, &buf));
        },
        'n' => if (pget(params, 0, 2) == 4) {
            vt.modify_other_keys = 1;
        },
        'u' => vt.kittyKbdPush(p0),
        'q' => if (p0 == 0) vt.respond("\x1bP>|velocitty\x1b\\"),
        else => {},
    }
}

fn applyLt(final: u8, params: []const Param, vt: *Vt) void {
    if (final == 'u') vt.kittyKbdPop(pget(params, 0, 1));
}

fn applySpace(final: u8, params: []const Param, vt: *Vt) void {
    if (final == 'q') vt.setCursorStyle(if (params.len > 0) params[0].value else 0);
}

fn applyEq(final: u8, params: []const Param, vt: *Vt) void {
    switch (final) {
        'c' => if (pget(params, 0, 0) == 0) vt.respond("\x1bP!|464f4f54\x1b\\"),
        'u' => vt.kittyKbdSet(pget(params, 0, 0), pget(params, 1, 1)),
        else => {},
    }
}

fn applyDollar(final: u8, params: []const Param, vt: *Vt) void {
    switch (final) {
        'r' => vt.deccara(params),
        't' => vt.decrara(params),
        'v' => vt.deccra(params),
        'x' => vt.decfra(params),
        'z' => vt.decera(params),
        'p' => {
            const param = pget(params, 0, 0);
            const status: u16 = if (param == 4) vt.ansiMode(4) else 0;
            vt.respondFmt("\x1b[{d};{d}$y", .{ param, status });
        },
        else => {},
    }
}

fn applyHash(final: u8, params: []const Param, vt: *Vt) void {
    const p0 = pget(params, 0, 0);
    switch (final) {
        'P' => vt.xtPushColors(p0),
        'Q' => vt.xtPopColors(p0),
        'R' => vt.xtReportColors(),
        else => {},
    }
}

fn applyDecDollar(final: u8, params: []const Param, vt: *Vt) void {
    if (final != 'p') return;
    const param = pget(params, 0, 0);
    vt.respondFmt("\x1b[?{d};{d}$y", .{ param, vt.privateMode(param) });
}

fn xtqmodkeys(params: []const Param, vt: *Vt) void {
    const resource = pget(params, 0, 0);
    const value: u16 = switch (resource) {
        0 => 0,
        1, 2 => 1,
        4 => if (vt.modify_other_keys == 2) 2 else 1,
        else => return,
    };
    vt.respondFmt("\x1b[>{d};{d}m", .{ resource, value });
}

fn windowOp(params: []const Param, vt: *Vt) void {
    const op = pget(params, 0, 0);
    const p1 = if (params.len > 1) params[1].value else 0;
    switch (op) {
        11 => vt.respond("\x1b[1t"),
        13 => vt.respond("\x1b[3;0;0t"),
        14 => {
            const w = vt.pixelWidth(p1 == 2);
            const h = vt.pixelHeight(p1 == 2);
            vt.respondFmt("\x1b[4;{d};{d}t", .{ h, w });
        },
        15 => vt.respondFmt("\x1b[5;{d};{d}t", .{ vt.pixelHeight(true), vt.pixelWidth(true) }),
        16 => vt.respondFmt("\x1b[6;{d};{d}t", .{ vt.cell_px_h, vt.cell_px_w }),
        18 => vt.respondFmt("\x1b[8;{d};{d}t", .{ vt.rows, vt.cols }),
        19 => vt.respondFmt("\x1b[9;{d};{d}t", .{ vt.rows, vt.cols }),
        22 => if (p1 == 0 or p1 == 2) vt.pushTitle(),
        23 => if (p1 == 0 or p1 == 2) vt.popTitle(),
        else => {},
    }
}

fn respondCursor(vt: *Vt) void {
    const row = vt.cursorReportRow();
    const col = @min(vt.grid().cursor.col, vt.cols - 1) + 1;
    vt.respondFmt("\x1b[{d};{d}R", .{ row, col });
}

fn copyParams(params: []const Param, buf: *[16]u32) []const u32 {
    const n = @min(params.len, buf.len);
    for (params[0..n], 0..) |p, i| buf[i] = p.value;
    return buf[0..n];
}

fn sgr(params: []const Param, vt: *Vt) void {
    if (params.len == 0) {
        vt.resetPen();
        return;
    }

    var i: usize = 0;
    while (i < params.len) {
        const p = params[i];
        const g = vt.grid();
        switch (p.value) {
            0 => vt.resetPen(),
            1 => g.attrs.bold = true,
            2 => g.attrs.dim = true,
            3 => g.attrs.italic = true,
            4 => sgrUnderline(vt, p),
            5 => g.attrs.blink = true,
            6 => {}, // rapid blink ignored (foot)
            7 => g.attrs.inverse = true,
            8 => g.attrs.hidden = true,
            9 => g.attrs.strikethrough = true,
            21 => {
                g.attrs.underline = true;
                g.attrs.underline_style = 2;
            },
            22 => {
                g.attrs.bold = false;
                g.attrs.dim = false;
            },
            23 => g.attrs.italic = false,
            24 => {
                g.attrs.underline = false;
                g.attrs.underline_style = 0;
            },
            25, 26 => g.attrs.blink = false,
            27 => g.attrs.inverse = false,
            28 => g.attrs.hidden = false,
            29 => g.attrs.strikethrough = false,
            30...37 => g.fg = vt.colorIndex(p.value - 30),
            39 => g.fg = vt.scheme.fg,
            40...47 => g.bg = vt.colorIndex(p.value - 40),
            49 => g.bg = vt.scheme.bg,
            38 => i += sgrColor(vt, params, i, .fg),
            48 => i += sgrColor(vt, params, i, .bg),
            58 => i += sgrColor(vt, params, i, .ul),
            59 => vt.clearUnderlineColor(),
            90...97 => g.fg = vt.colorIndex(p.value - 90 + 8),
            100...107 => g.bg = vt.colorIndex(p.value - 100 + 8),
            else => {},
        }
        i += 1;
    }
}

fn sgrUnderline(vt: *Vt, p: Param) void {
    const g = vt.grid();
    if (p.sub_len == 0) {
        g.attrs.underline = true;
        g.attrs.underline_style = 1;
        return;
    }
    const style = p.sub[0];
    switch (style) {
        0 => {
            g.attrs.underline = false;
            g.attrs.underline_style = 0;
        },
        1...5 => {
            g.attrs.underline = true;
            g.attrs.underline_style = @intCast(style);
        },
        else => {
            g.attrs.underline = true;
            g.attrs.underline_style = 1;
        },
    }
}

const ColorTarget = enum { fg, bg, ul };

fn sgrColor(vt: *Vt, params: []const Param, i: usize, target: ColorTarget) usize {
    const p = params[i];
    if (p.sub_len >= 2 and p.sub[0] == 5) {
        applyIndexed(vt, p.sub[1], target);
        return 0;
    }
    if (p.sub_len >= 4 and p.sub[0] == 2) {
        const have_cs = p.sub_len >= 5;
        const r_i: usize = if (have_cs) 2 else 1;
        applyRgb(vt, p.sub[r_i], p.sub[r_i + 1], p.sub[r_i + 2], target);
        return 0;
    }
    if (i + 1 >= params.len) return 0;
    if (params[i + 1].value == 5) {
        if (i + 2 >= params.len) return params.len - i - 1;
        applyIndexed(vt, params[i + 2].value, target);
        return 2;
    }
    if (params[i + 1].value == 2) {
        const rest = params.len - i - 1;
        if (rest >= 4) {
            applyRgb(vt, params[i + 2].value, params[i + 3].value, params[i + 4].value, target);
            return 4;
        }
        return rest;
    }
    return 1;
}

fn applyIndexed(vt: *Vt, idx: u32, target: ColorTarget) void {
    const c = vt.colorIndex(idx);
    switch (target) {
        .fg => vt.grid().fg = c,
        .bg => vt.grid().bg = c,
        .ul => vt.setUnderlineColor(c),
    }
}

fn applyRgb(vt: *Vt, r: u32, g: u32, b: u32, target: ColorTarget) void {
    const c = Color{
        .r = clip(r),
        .g = clip(g),
        .b = clip(b),
    };
    switch (target) {
        .fg => vt.grid().fg = c,
        .bg => vt.grid().bg = c,
        .ul => vt.setUnderlineColor(c),
    }
}

fn clip(v: u32) u8 {
    return @truncate(@min(v, 255));
}

test "parse cup" {
    var params: [16]Param = undefined;
    const s = parse("\x1b[1;3H", &params);
    try std.testing.expectEqual(@as(u8, 'H'), s.final);
    try std.testing.expectEqual(@as(u32, 0), s.private);
    try std.testing.expectEqual(@as(usize, 2), s.params.len);
    try std.testing.expectEqual(@as(u32, 1), s.params[0].value);
    try std.testing.expectEqual(@as(u32, 3), s.params[1].value);
}

test "parse private mode" {
    var params: [16]Param = undefined;
    const s = parse("\x1b[?1049h", &params);
    try std.testing.expectEqual(@as(u8, 'h'), s.final);
    try std.testing.expectEqual(@as(u32, '?'), s.private);
    try std.testing.expectEqual(@as(usize, 1), s.params.len);
    try std.testing.expectEqual(@as(u32, 1049), s.params[0].value);
}

test "parse sgr truecolor" {
    var params: [16]Param = undefined;
    const s = parse("\x1b[48;2;30;60;90m", &params);
    try std.testing.expectEqual(@as(u8, 'm'), s.final);
    try std.testing.expectEqual(@as(usize, 5), s.params.len);
    try std.testing.expectEqual(@as(u32, 48), s.params[0].value);
    try std.testing.expectEqual(@as(u32, 2), s.params[1].value);
    try std.testing.expectEqual(@as(u32, 30), s.params[2].value);
    try std.testing.expectEqual(@as(u32, 60), s.params[3].value);
    try std.testing.expectEqual(@as(u32, 90), s.params[4].value);
}

test "parse sgr colon truecolor" {
    var params: [16]Param = undefined;
    const s = parse("\x1b[38:2:30:60:90m", &params);
    try std.testing.expectEqual(@as(u8, 'm'), s.final);
    try std.testing.expectEqual(@as(usize, 1), s.params.len);
    try std.testing.expectEqual(@as(u32, 38), s.params[0].value);
    try std.testing.expectEqual(@as(u8, 4), s.params[0].sub_len);
    try std.testing.expectEqual(@as(u32, 2), s.params[0].sub[0]);
    try std.testing.expectEqual(@as(u32, 30), s.params[0].sub[1]);
    try std.testing.expectEqual(@as(u32, 60), s.params[0].sub[2]);
    try std.testing.expectEqual(@as(u32, 90), s.params[0].sub[3]);
}

test "parse decrqm" {
    var params: [16]Param = undefined;
    const s = parse("\x1b[?25$p", &params);
    try std.testing.expectEqual(@as(u8, 'p'), s.final);
    try std.testing.expectEqual(@as(u32, 0x243F), s.private);
    try std.testing.expectEqual(@as(u32, 25), s.params[0].value);
}

test "parse decscusr" {
    var params: [16]Param = undefined;
    const s = parse("\x1b[4 q", &params);
    try std.testing.expectEqual(@as(u8, 'q'), s.final);
    try std.testing.expectEqual(@as(u32, ' '), s.private);
    try std.testing.expectEqual(@as(u32, 4), s.params[0].value);
}
