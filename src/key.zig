//! PTY key encoding: xterm modifiers, modifyOtherKeys, kitty keyboard protocol.

const std = @import("std");
const Platform = @import("platform/platform.zig");

const KeyCode = Platform.Event.KeyCode;
const KeyMod = Platform.Event.KeyMod;

const KITTY_DISAMBIGUATE: u16 = 0x1;
const KITTY_ALL_KEYS: u16 = 0x8;

pub fn encode(
    key: KeyCode,
    mods: KeyMod,
    app_cursor: bool,
    kitty: u16,
    modify_other_keys: u8,
    cp: u21,
    buf: *[64]u8,
) []const u8 {
    const m = modNumber(mods);
    if (useKitty(key, m, kitty)) {
        return encodeKitty(key, m, kitty, cp, buf);
    }
    return encodeLegacy(key, mods, m, app_cursor, modify_other_keys, cp, buf);
}

fn modNumber(mods: KeyMod) u8 {
    var m: u8 = 1;
    if (mods.shift) m += 1;
    if (mods.alt) m += 2;
    if (mods.ctrl) m += 4;
    if (mods.super) m += 8;
    return m;
}

fn useKitty(key: KeyCode, mod: u8, kitty: u16) bool {
    if (kitty == 0) return false;
    if (kitty & KITTY_ALL_KEYS != 0) return true;
    if (kitty & KITTY_DISAMBIGUATE != 0) {
        if (key == .escape) return true;
        if (mod > 1) return true;
    }
    return false;
}

const KittyKey = struct { n: u16, final: u8 };

fn kittyKey(key: KeyCode, cp: u21) ?KittyKey {
    return switch (key) {
        .escape => .{ .n = 27, .final = 'u' },
        .enter => .{ .n = 13, .final = 'u' },
        .tab => .{ .n = 9, .final = 'u' },
        .backspace => .{ .n = 127, .final = 'u' },
        .space => .{ .n = 32, .final = 'u' },
        .insert => .{ .n = 2, .final = '~' },
        .delete => .{ .n = 3, .final = '~' },
        .page_up => .{ .n = 5, .final = '~' },
        .page_down => .{ .n = 6, .final = '~' },
        .home => .{ .n = 1, .final = 'H' },
        .end => .{ .n = 1, .final = 'F' },
        .arrow_up => .{ .n = 1, .final = 'A' },
        .arrow_down => .{ .n = 1, .final = 'B' },
        .arrow_right => .{ .n = 1, .final = 'C' },
        .arrow_left => .{ .n = 1, .final = 'D' },
        .f1 => .{ .n = 1, .final = 'P' },
        .f2 => .{ .n = 1, .final = 'Q' },
        .f3 => .{ .n = 1, .final = 'R' },
        .f4 => .{ .n = 1, .final = 'S' },
        .f5 => .{ .n = 15, .final = '~' },
        .f6 => .{ .n = 17, .final = '~' },
        .f7 => .{ .n = 18, .final = '~' },
        .f8 => .{ .n = 19, .final = '~' },
        .f9 => .{ .n = 20, .final = '~' },
        .f10 => .{ .n = 21, .final = '~' },
        .f11 => .{ .n = 23, .final = '~' },
        .f12 => .{ .n = 24, .final = '~' },
        else => blk: {
            const n = unicodeOf(key, cp) orelse break :blk null;
            if (n == 0 or n > 0xffff) break :blk null;
            break :blk .{ .n = @intCast(n), .final = 'u' };
        },
    };
}

fn encodeKitty(key: KeyCode, mod: u8, kitty: u16, cp: u21, buf: *[64]u8) []const u8 {
    _ = kitty;
    const info = kittyKey(key, cp) orelse return "";
    // Press is the default event type; we do not emit releases.
    return writeCsi(buf, info.n, mod, false, info.final);
}

fn writeCsi(buf: *[64]u8, n: u16, mod: u8, event: bool, final: u8) []const u8 {
    if (event) {
        return std.fmt.bufPrint(buf, "\x1b[{d};{d}:1{c}", .{ n, mod, final }) catch "";
    }
    if (mod > 1) {
        if (n == 1 and final != 'u' and final != '~') {
            return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ mod, final }) catch "";
        }
        return std.fmt.bufPrint(buf, "\x1b[{d};{d}{c}", .{ n, mod, final }) catch "";
    }
    if (final == 'u' or final == '~') {
        return std.fmt.bufPrint(buf, "\x1b[{d}{c}", .{ n, final }) catch "";
    }
    return std.fmt.bufPrint(buf, "\x1b[{c}", .{final}) catch "";
}

fn encodeLegacy(
    key: KeyCode,
    mods: KeyMod,
    m: u8,
    app_cursor: bool,
    modify_other_keys: u8,
    cp: u21,
    buf: *[64]u8,
) []const u8 {
    const any = m > 1;
    switch (key) {
        .enter => {
            if (!any) return "\r";
            if (onlyAlt(mods)) return escPrefix("\r", buf);
            if (modify_other_keys >= 1) return mok(13, m, buf);
            return "\r";
        },
        .tab => {
            if (!any) return "\t";
            if (mods.shift and m == 2) return "\x1b[Z";
            if (modify_other_keys >= 1) return mok(9, m, buf);
            if (mods.shift) return "\x1b[Z";
            return "\t";
        },
        .escape => {
            if (!any) return "\x1b";
            if (modify_other_keys >= 1) return mok(27, m, buf);
            return "\x1b";
        },
        .backspace => {
            if (mods.ctrl and !mods.alt and !mods.super) return "\x08";
            if (onlyAlt(mods)) return "\x1b\x7f";
            if (any and modify_other_keys >= 1) return mok(127, m, buf);
            return "\x7f";
        },
        .space => {
            if (!any) return " ";
            if (mods.ctrl and !mods.alt and !mods.super) {
                buf[0] = 0;
                return buf[0..1];
            }
            if (onlyAlt(mods)) return escPrefix(" ", buf);
            if (modify_other_keys >= 1) return mok(32, m, buf);
            return " ";
        },
        .arrow_up => return cursor('A', m, app_cursor, buf),
        .arrow_down => return cursor('B', m, app_cursor, buf),
        .arrow_right => return cursor('C', m, app_cursor, buf),
        .arrow_left => return cursor('D', m, app_cursor, buf),
        .home => return cursor('H', m, app_cursor, buf),
        .end => return cursor('F', m, app_cursor, buf),
        .insert => return tilde(2, m, buf),
        .delete => return tilde(3, m, buf),
        .page_up => return tilde(5, m, buf),
        .page_down => return tilde(6, m, buf),
        .f1 => return fkeySS3('P', 11, m, buf),
        .f2 => return fkeySS3('Q', 12, m, buf),
        .f3 => return fkeySS3('R', 13, m, buf),
        .f4 => return fkeySS3('S', 14, m, buf),
        .f5 => return tilde(15, m, buf),
        .f6 => return tilde(17, m, buf),
        .f7 => return tilde(18, m, buf),
        .f8 => return tilde(19, m, buf),
        .f9 => return tilde(20, m, buf),
        .f10 => return tilde(21, m, buf),
        .f11 => return tilde(23, m, buf),
        .f12 => return tilde(24, m, buf),
        else => return encodeChar(key, mods, m, modify_other_keys, cp, buf),
    }
}

fn onlyAlt(mods: KeyMod) bool {
    return mods.alt and !mods.ctrl and !mods.super and !mods.shift;
}

fn cursor(final: u8, m: u8, app_cursor: bool, buf: *[64]u8) []const u8 {
    if (m > 1) return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ m, final }) catch "";
    if (app_cursor) {
        buf[0] = 0x1b;
        buf[1] = 'O';
        buf[2] = final;
        return buf[0..3];
    }
    buf[0] = 0x1b;
    buf[1] = '[';
    buf[2] = final;
    return buf[0..3];
}

fn tilde(n: u16, m: u8, buf: *[64]u8) []const u8 {
    if (m > 1) return std.fmt.bufPrint(buf, "\x1b[{d};{d}~", .{ n, m }) catch "";
    return std.fmt.bufPrint(buf, "\x1b[{d}~", .{n}) catch "";
}

fn fkeySS3(final: u8, n: u16, m: u8, buf: *[64]u8) []const u8 {
    if (m > 1) return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ m, final }) catch "";
    buf[0] = 0x1b;
    buf[1] = 'O';
    buf[2] = final;
    _ = n;
    return buf[0..3];
}

fn mok(code: u16, m: u8, buf: *[64]u8) []const u8 {
    return std.fmt.bufPrint(buf, "\x1b[27;{d};{d}~", .{ m, code }) catch "";
}

fn escPrefix(s: []const u8, buf: *[64]u8) []const u8 {
    if (s.len == 0 or 1 + s.len > buf.len) return s;
    buf[0] = 0x1b;
    @memcpy(buf[1 .. 1 + s.len], s);
    return buf[0 .. 1 + s.len];
}

fn unicodeOf(key: KeyCode, cp: u21) ?u21 {
    if (cp != 0) {
        if (cp >= 'A' and cp <= 'Z') return cp + 32;
        return cp;
    }
    return switch (key) {
        .a => 'a',
        .b => 'b',
        .c => 'c',
        .d => 'd',
        .e => 'e',
        .f => 'f',
        .g => 'g',
        .h => 'h',
        .i => 'i',
        .j => 'j',
        .k => 'k',
        .l => 'l',
        .m => 'm',
        .n => 'n',
        .o => 'o',
        .p => 'p',
        .q => 'q',
        .r => 'r',
        .s => 's',
        .t => 't',
        .u => 'u',
        .v => 'v',
        .w => 'w',
        .x => 'x',
        .y => 'y',
        .z => 'z',
        .num_0 => '0',
        .num_1 => '1',
        .num_2 => '2',
        .num_3 => '3',
        .num_4 => '4',
        .num_5 => '5',
        .num_6 => '6',
        .num_7 => '7',
        .num_8 => '8',
        .num_9 => '9',
        .space => ' ',
        else => null,
    };
}

fn encodeChar(
    key: KeyCode,
    mods: KeyMod,
    m: u8,
    modify_other_keys: u8,
    cp: u21,
    buf: *[64]u8,
) []const u8 {
    const n21 = unicodeOf(key, cp) orelse return "";
    if (n21 == 0) return "";
    const n16: u16 = @intCast(@min(n21, 0xffff));
    if (n21 > 0xff) {
        if (m > 1 and modify_other_keys >= 1) return mok(n16, m, buf);
        return "";
    }
    var c: u8 = @intCast(n21);
    if (mods.shift and c >= 'a' and c <= 'z') c -= 32;

    const ctrl = mods.ctrl;
    const alt = mods.alt;
    const super = mods.super;

    if (super and modify_other_keys >= 1) return mok(n16, m, buf);
    if (ctrl and alt and modify_other_keys >= 1) return mok(n16, m, buf);

    if (ctrl and !alt and !super) {
        if (c == ' ') {
            buf[0] = 0;
            return buf[0..1];
        }
        if (c == '?') {
            buf[0] = 0x7f;
            return buf[0..1];
        }
        if (modify_other_keys >= 2) return mok(n16, m, buf);
        if ((c >= '@' and c <= '_') or (c >= 'a' and c <= 'z')) {
            buf[0] = c & 0x1f;
            return buf[0..1];
        }
        if (modify_other_keys >= 1) return mok(n16, m, buf);
        return "";
    }

    if (alt and !ctrl and !super) {
        buf[0] = 0x1b;
        buf[1] = c;
        return buf[0..2];
    }

    if (m > 1 and modify_other_keys >= 1) return mok(n16, m, buf);

    buf[0] = c;
    return buf[0..1];
}

fn enc(
    key: KeyCode,
    mods: KeyMod,
    kitty: u16,
    mok_mode: u8,
    cp: u21,
    buf: *[64]u8,
) []const u8 {
    return encode(key, mods, false, kitty, mok_mode, cp, buf);
}

test "shift+tab is CSI Z" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[Z", enc(.tab, .{ .shift = true }, 0, 1, 0, &buf));
    try std.testing.expectEqualStrings("\t", enc(.tab, .{}, 0, 1, 0, &buf));
}

test "shift+tab kitty disambiguate" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[9;2u", enc(.tab, .{ .shift = true }, 1, 1, 0, &buf));
}

test "shift+enter" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[27;2;13~", enc(.enter, .{ .shift = true }, 0, 1, 0, &buf));
    try std.testing.expectEqualStrings("\x1b[13;2u", enc(.enter, .{ .shift = true }, 1, 1, 0, &buf));
    try std.testing.expectEqualStrings("\r", enc(.enter, .{}, 0, 1, 0, &buf));
}

test "ctrl punctuation uses modifyOtherKeys" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[27;5;46~", enc(.unknown, .{ .ctrl = true }, 0, 1, '.', &buf));
    try std.testing.expectEqualStrings("\x1b[46;5u", enc(.unknown, .{ .ctrl = true }, 1, 1, '.', &buf));
}

test "ctrl letter stays C0 without kitty" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x01", enc(.a, .{ .ctrl = true }, 0, 1, 0, &buf));
    try std.testing.expectEqualStrings("\x1b[97;5u", enc(.a, .{ .ctrl = true }, 1, 1, 0, &buf));
}

test "alt letter is ESC prefix" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1ba", enc(.a, .{ .alt = true }, 0, 1, 0, &buf));
}

test "modified arrows" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[A", enc(.arrow_up, .{}, 0, 1, 0, &buf));
    try std.testing.expectEqualStrings("\x1b[1;5A", enc(.arrow_up, .{ .ctrl = true }, 0, 1, 0, &buf));
    try std.testing.expectEqualStrings("\x1b[1;2A", enc(.arrow_up, .{ .shift = true }, 0, 1, 0, &buf));
}
