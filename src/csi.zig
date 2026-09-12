//! CSI (ESC [) parse + apply.

const std = @import("std");
const Vt = @import("vt.zig").VtState;

const CsiSeq = @This();

intermediate: u8 = 0,
private: u8 = 0,
final: u8 = 0,
seq: []const u8 = "",
params: []u16 = &.{},

const CharKind = enum(u3) { digit, sep, inter, final, invalid };

const CHAR_MAP: [256]CharKind = initMap: {
    var map = [_]CharKind{.invalid} ** 256;
    for ('0'..'9' + 1) |c| map[c] = .digit;
    map[';'] = .sep;
    map[':'] = .sep;
    for (0x20..0x2F + 1) |c| map[c] = .inter;
    for (0x40..0x7E + 1) |c| map[c] = .final;
    break :initMap map;
};

/// Parses a raw byte sequence into a CsiSeq struct using `param_buf` as storage.
/// Returns a stub with `final = 0` if sequence is malformed or invalid.
pub fn parse(seq: []const u8, param_buf: []u16) CsiSeq {
    const STUB = CsiSeq{ .final = 0, .seq = seq };

    if (seq.len < 3 or seq[0] != 0x1b or seq[1] != '[') return STUB;

    const c2 = seq[2];
    const is_priv: u8 = @intFromBool(c2 >= 0x3C and c2 <= 0x3F);
    const priv = c2 * is_priv;

    var i: usize = 2 + is_priv;
    var n: usize = 0;
    var val: u16 = 0;
    var have: u16 = 0;
    var intermediate: u8 = 0;
    var is_valid: u8 = 1;

    const max_body = seq.len - 1;

    while (i < max_body) : (i += 1) {
        const c = seq[i];
        const kind = CHAR_MAP[c];

        const is_dig = @intFromBool(kind == .digit);
        const is_sep = @intFromBool(kind == .sep);
        const is_mid = @intFromBool(kind == .inter);
        const is_bad = @intFromBool(kind == .invalid or kind == .final);

        is_valid &= (is_bad ^ 1);
        have |= is_dig;
        val = (val *% 10 +% (c -% '0')) * is_dig + val * (is_dig ^ 1);

        if (is_sep != 0) {
            if (n < param_buf.len) param_buf[n] = val;
            n += 1;
            val = 0;
            have = 0;
        }

        intermediate = c * is_mid + intermediate * (is_mid ^ 1);
    }

    const push_last = (have | @intFromBool(n > 0) | @intFromBool(seq.len > 3 + is_priv));
    if (push_last != 0 and n < param_buf.len) {
        param_buf[n] = val;
        n += 1;
    }

    const final_byte = seq[seq.len - 1];
    const ok = is_valid & @intFromBool(CHAR_MAP[final_byte] == .final);

    return .{
        .intermediate = intermediate * ok,
        .private = priv * ok,
        .final = final_byte * ok,
        .seq = seq,
        .params = param_buf[0..(@min(n, param_buf.len) * ok)],
    };
}

pub fn apply(self: CsiSeq, vt: *Vt) void {
    const params = self.params;
    const p0 = if (params.len > 0) params[0] else 0;
    const n1: u16 = if (p0 == 0) 1 else p0;

    switch (self.private) {
        0 => switch (self.final) {
            0 => return,
            'c' => vt.respond("\x1b[?62;c"),
            'n' => if (p0 == 6) respondCursor(vt),
            'm' => self.sgr(vt),
            'h' => vt.setMode(params, true),
            'l' => vt.setMode(params, false),
            's' => vt.saveCursor(),
            'u' => vt.restoreCursor(),
            'r' => vt.decstbm(p0, if (params.len > 1) params[1] else 0),
            'p' => if (self.intermediate == '!') vt.softReset(),
            'q' => if (self.intermediate == 0 or self.intermediate == ' ') vt.setCursorStyle(p0),
            'H', 'f' => vt.cup(n1, if (params.len > 1 and params[1] != 0) params[1] else 1),
            'J' => vt.ed(p0),
            'K' => vt.el(p0),
            'A' => vt.cuu(n1),
            'B', 'e' => vt.cud(n1),
            'C', 'a' => vt.cuf(n1),
            'D' => vt.cub(n1),
            'E' => {
                vt.cud(n1);
                vt.grid().cursor.col = 0;
            },
            'F' => {
                vt.cuu(n1);
                vt.grid().cursor.col = 0;
            },
            'G', '`' => vt.grid().cursor.col = @min(n1 -| 1, vt.cols - 1),
            'd' => vt.cup(n1, vt.grid().cursor.col + 1),
            '@' => vt.ich(n1),
            'P' => vt.dch(n1),
            'X' => vt.ech(n1),
            'L' => vt.il(n1),
            'M' => vt.dl(n1),
            'S' => vt.regionScrollUp(n1),
            'T' => vt.regionScrollDown(n1),
            'b' => vt.rep(n1),
            'I' => {
                var k: u16 = 0;
                while (k < n1) : (k += 1) vt.tab();
            },
            'Z' => {
                var k: u16 = 0;
                while (k < n1) : (k += 1) vt.tabBack();
            },
            else => {},
        },
        '?' => switch (self.final) {
            'n' => if (p0 == 6) respondCursor(vt),
            'h' => vt.setPrivate(params, true),
            'l' => vt.setPrivate(params, false),
            's' => vt.savePrivate(params),
            'r' => vt.restorePrivate(params),
            else => {},
        },
        '>' => switch (self.final) {
            'c' => vt.respond("\x1b[>0;10;0c"),
            'm' => vt.setModifyKeys(params),
            else => {},
        },
        else => {},
    }
}

fn respondCursor(vt: *Vt) void {
    var buf: [32]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
        vt.grid().cursor.row + 1,
        vt.grid().cursor.col + 1,
    }) catch return;
    vt.respond(resp);
}

fn sgr(self: CsiSeq, vt: *Vt) void {
    const params = self.params;
    if (params.len == 0) {
        vt.resetPen();
        return;
    }

    var i: usize = 0;
    while (i < params.len) {
        const p = params[i];
        i += 1;
        const g = vt.grid();
        switch (p) {
            0 => vt.resetPen(),
            1 => g.attrs.bold = true,
            2 => g.attrs.dim = true,
            3 => g.attrs.italic = true,
            4 => g.attrs.underline = true,
            5, 6 => g.attrs.blink = true,
            7 => g.attrs.inverse = true,
            8 => g.attrs.hidden = true,
            9 => g.attrs.strikethrough = true,
            21 => g.attrs.underline = true,
            22 => {
                g.attrs.bold = false;
                g.attrs.dim = false;
            },
            23 => g.attrs.italic = false,
            24 => g.attrs.underline = false,
            25, 26 => g.attrs.blink = false,
            27 => g.attrs.inverse = false,
            28 => g.attrs.hidden = false,
            29 => g.attrs.strikethrough = false,
            30...37 => g.fg = vt.scheme.palette[p - 30],
            39 => g.fg = vt.scheme.fg,
            40...47 => g.bg = vt.scheme.palette[p - 40],
            49 => g.bg = vt.scheme.bg,
            38 => i += vt.takeColor(params[i..], true),
            48 => i += vt.takeColor(params[i..], false),
            90...97 => g.fg = vt.scheme.palette[p - 90 + 8],
            100...107 => g.bg = vt.scheme.palette[p - 100 + 8],
            else => {},
        }
    }
}

test "parse cup" {
    var params: [16]u16 = undefined;
    const s = parse("\x1b[1;3H", &params);
    try std.testing.expectEqual(@as(u8, 'H'), s.final);
    try std.testing.expectEqual(@as(u8, 0), s.private);
    try std.testing.expectEqual(@as(usize, 2), s.params.len);
    try std.testing.expectEqual(@as(u16, 1), s.params[0]);
    try std.testing.expectEqual(@as(u16, 3), s.params[1]);
}

test "parse private mode" {
    var params: [16]u16 = undefined;
    const s = parse("\x1b[?1049h", &params);
    try std.testing.expectEqual(@as(u8, 'h'), s.final);
    try std.testing.expectEqual(@as(u8, '?'), s.private);
    try std.testing.expectEqual(@as(usize, 1), s.params.len);
    try std.testing.expectEqual(@as(u16, 1049), s.params[0]);
}

test "parse sgr truecolor" {
    var params: [16]u16 = undefined;
    const s = parse("\x1b[48;2;30;60;90m", &params);
    try std.testing.expectEqual(@as(u8, 'm'), s.final);
    try std.testing.expectEqualSlices(u16, &.{ 48, 2, 30, 60, 90 }, s.params);
}
