//! Cross-platform event management and xterm input encoding.

const std = @import("std");

pub const Mods = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
};

pub const Button = enum {
    none,
    left,
    middle,
    right,
    wheel_up,
    wheel_down,
    wheel_left,
    wheel_right,
};

pub const KeySym = enum(u32) {
    unknown = 0,
    enter = 0x0d,
    escape = 0x1b,
    backspace = 0x08,
    tab = 0x09,
    space = 0x20,
    delete = 0x7f,
    insert = 0x100,
    home,
    end,
    page_up,
    page_down,
    up,
    down,
    right,
    left,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const Key = struct {
    code: u32,
    mods: Mods = .{},
    text: []const u8 = &.{},
};

pub const MouseAction = enum { press, release, drag, move };

pub const Mouse = struct {
    x: i32,
    y: i32,
    button: Button,
    action: MouseAction,
    mods: Mods = .{},
};

pub const Resize = struct {
    cols: u16,
    rows: u16,
    px_w: u32,
    px_h: u32,
};

pub const Event = union(enum) {
    key: Key,
    mouse: Mouse,
    resize: Resize,
    paste: []const u8,
    focus: bool,
    close,
};

pub const MouseTracking = enum {
    off,
    x10,
    btn,
    drag,
    any,
};

pub const InputMode = struct {
    app_cursor: bool = false,
    app_keypad: bool = false,
    mouse: MouseTracking = .off,
    mouse_sgr: bool = false,
    mouse_urxvt: bool = false,
    mouse_pixels: bool = false,
    focus_event: bool = false,
    bracket_paste: bool = false,
    alt_scroll: bool = false,
    modify_other_keys: u8 = 0,
};

pub const MouseProto = struct {
    tracking: MouseTracking = .off,
    sgr: bool = false,
    urxvt: bool = false,
    pixels: bool = false,
};

pub fn encodeKey(out: *[32]u8, key: Key, mode: InputMode) []const u8 {
    if (key.text.len != 0 and !key.mods.ctrl) {
        if (key.mods.alt) {
            out[0] = 0x1b;
            const n = @min(key.text.len, out.len - 1);
            @memcpy(out[1..][0..n], key.text[0..n]);
            return out[0 .. 1 + n];
        }
        const n = @min(key.text.len, out.len);
        @memcpy(out[0..n], key.text[0..n]);
        return out[0..n];
    }

    const mods = key.mods;
    if (key.code >= 0x20 and key.code < 0x7f) {
        return encodeAscii(out, @intCast(key.code), mods);
    }

    const sym: KeySym = keySym(key.code);
    return switch (sym) {
        .unknown => &.{},
        .enter => encodeC0(out, '\r', mods),
        .escape => encodeC0(out, 0x1b, mods),
        .backspace => encodeC0(out, 0x7f, mods),
        .tab => if (mods.shift and !mods.ctrl and !mods.alt)
            write(out, "\x1b[Z")
        else
            encodeC0(out, '\t', mods),
        .space => encodeAscii(out, ' ', mods),
        .delete => tilde(out, 3, mods),
        .insert => tilde(out, 2, mods),
        .page_up => tilde(out, 5, mods),
        .page_down => tilde(out, 6, mods),
        .home => csiArrow(out, 'H', mods, mode.app_cursor),
        .end => csiArrow(out, 'F', mods, mode.app_cursor),
        .up => csiArrow(out, 'A', mods, mode.app_cursor),
        .down => csiArrow(out, 'B', mods, mode.app_cursor),
        .right => csiArrow(out, 'C', mods, mode.app_cursor),
        .left => csiArrow(out, 'D', mods, mode.app_cursor),
        .f1 => ss3(out, 'P', 11, mods),
        .f2 => ss3(out, 'Q', 12, mods),
        .f3 => ss3(out, 'R', 13, mods),
        .f4 => ss3(out, 'S', 14, mods),
        .f5 => tilde(out, 15, mods),
        .f6 => tilde(out, 17, mods),
        .f7 => tilde(out, 18, mods),
        .f8 => tilde(out, 19, mods),
        .f9 => tilde(out, 20, mods),
        .f10 => tilde(out, 21, mods),
        .f11 => tilde(out, 23, mods),
        .f12 => tilde(out, 24, mods),
    };
}

pub fn encodeMouse(out: *[32]u8, ev: Mouse, col: u16, row: u16, proto: MouseProto) []const u8 {
    if (!mouseWanted(ev, proto.tracking)) return &.{};

    var btn: u16 = switch (ev.button) {
        .none => 3,
        .left => 0,
        .middle => 1,
        .right => 2,
        .wheel_up => 64,
        .wheel_down => 65,
        .wheel_left => 66,
        .wheel_right => 67,
    };
    if (ev.mods.shift) btn += 4;
    if (ev.mods.alt) btn += 8;
    if (ev.mods.ctrl) btn += 16;
    if (ev.action == .drag or ev.action == .move) btn += 32;

    const x = @max(col, 1);
    const y = @max(row, 1);
    const wheel = switch (ev.button) {
        .wheel_up, .wheel_down, .wheel_left, .wheel_right => true,
        else => false,
    };
    if (proto.pixels or proto.sgr) {
        const px: u32 = @as(u32, @intCast(@max(ev.x, 0))) + 1;
        const py: u32 = @as(u32, @intCast(@max(ev.y, 0))) + 1;
        const mx = if (proto.pixels) px else x;
        const my = if (proto.pixels) py else y;
        const final: u8 = if (ev.action == .release and !wheel) 'm' else 'M';
        return std.fmt.bufPrint(out, "\x1b[<{d};{d};{d}{c}", .{ btn, mx, my, final }) catch &.{};
    }
    if (proto.urxvt) {
        var cb = btn;
        if (ev.action == .release and !wheel) cb = 3;
        return std.fmt.bufPrint(out, "\x1b[{d};{d};{d}M", .{ 32 + cb, x, y }) catch &.{};
    }

    if (ev.action == .release and ev.button != .wheel_up and ev.button != .wheel_down) {
        btn = 3;
        if (ev.mods.shift) btn += 4;
        if (ev.mods.alt) btn += 8;
        if (ev.mods.ctrl) btn += 16;
    }
    const b: u8 = @intCast(32 + @min(btn, 223));
    const cx: u8 = @intCast(32 + @min(x, 223));
    const cy: u8 = @intCast(32 + @min(y, 223));
    out[0] = 0x1b;
    out[1] = '[';
    out[2] = 'M';
    out[3] = b;
    out[4] = cx;
    out[5] = cy;
    return out[0..6];
}

pub fn encodeFocus(on: bool) []const u8 {
    return if (on) "\x1b[I" else "\x1b[O";
}

pub const paste_start = "\x1b[200~";
pub const paste_end = "\x1b[201~";

pub fn encodePaste(out: []u8, bytes: []const u8, bracket: bool) []const u8 {
    if (!bracket) {
        const n = filterPaste(out, bytes, false);
        return out[0..n.out];
    }
    if (paste_start.len + paste_end.len > out.len) return &.{};
    @memcpy(out[0..paste_start.len], paste_start);
    const n = filterPaste(out[paste_start.len .. out.len - paste_end.len], bytes, true);
    const end = paste_start.len + n.out;
    @memcpy(out[end..][0..paste_end.len], paste_end);
    return out[0 .. end + paste_end.len];
}

/// Copy `src` into `out`. Drops C0 except tab/CR/LF; maps LF to CR.
/// Unbracketed pastes drop ESC. Bracketed pastes strip the end sequence.
pub fn filterPaste(out: []u8, src: []const u8, bracket: bool) struct { in: usize, out: usize } {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len and o < out.len) {
        const c = src[i];
        if (c == 0x1b) {
            if (bracket and i + paste_end.len <= src.len and std.mem.eql(u8, src[i .. i + paste_end.len], paste_end)) {
                i += paste_end.len;
                continue;
            }
            if (!bracket) {
                i += 1;
                continue;
            }
        }
        if (c < 0x20) {
            if (c == '\n') {
                out[o] = '\r';
                o += 1;
            } else if (c == '\r' or c == '\t') {
                out[o] = c;
                o += 1;
            }
            i += 1;
            continue;
        }
        if (c == 0x7f) {
            i += 1;
            continue;
        }
        out[o] = c;
        o += 1;
        i += 1;
    }
    return .{ .in = i, .out = o };
}

fn keySym(code: u32) KeySym {
    const last = @intFromEnum(KeySym.f12);
    if (code >= @intFromEnum(KeySym.insert) and code <= last) return @enumFromInt(code);
    return switch (code) {
        @intFromEnum(KeySym.enter) => .enter,
        @intFromEnum(KeySym.escape) => .escape,
        @intFromEnum(KeySym.backspace) => .backspace,
        @intFromEnum(KeySym.tab) => .tab,
        @intFromEnum(KeySym.space) => .space,
        @intFromEnum(KeySym.delete) => .delete,
        else => .unknown,
    };
}

fn mouseWanted(ev: Mouse, tracking: MouseTracking) bool {
    return switch (tracking) {
        .off => false,
        .x10 => ev.action == .press,
        .btn => ev.action == .press or ev.action == .release,
        .drag => ev.action != .move,
        .any => true,
    };
}

fn encodeAscii(out: *[32]u8, ch: u8, mods: Mods) []const u8 {
    if (mods.ctrl) {
        const b: u8 = switch (ch) {
            ' ', '2', '`', '@' => 0x00,
            '3' => 0x1b,
            '4' => 0x1c,
            '5' => 0x1d,
            '6', '^' => 0x1e,
            '7', '/', '_' => 0x1f,
            '8', '?' => 0x7f,
            'a'...'z' => ch - 'a' + 1,
            'A'...'Z' => ch - 'A' + 1,
            '['...']' => ch - '@',
            else => return &.{},
        };
        return encodeC0(out, b, .{ .alt = mods.alt, .super = mods.super });
    }
    if (mods.alt) {
        out[0] = 0x1b;
        out[1] = ch;
        return out[0..2];
    }
    out[0] = ch;
    return out[0..1];
}

fn encodeC0(out: *[32]u8, b: u8, mods: Mods) []const u8 {
    if (mods.alt) {
        out[0] = 0x1b;
        out[1] = b;
        return out[0..2];
    }
    out[0] = b;
    return out[0..1];
}

fn modParam(mods: Mods) u16 {
    var p: u16 = 1;
    if (mods.shift) p += 1;
    if (mods.alt) p += 2;
    if (mods.ctrl) p += 4;
    if (mods.super) p += 8;
    return p;
}

fn write(out: *[32]u8, s: []const u8) []const u8 {
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
}

fn csiArrow(out: *[32]u8, final: u8, mods: Mods, app: bool) []const u8 {
    const m = modParam(mods);
    if (m == 1) {
        if (app) return std.fmt.bufPrint(out, "\x1bO{c}", .{final}) catch &.{};
        return std.fmt.bufPrint(out, "\x1b[{c}", .{final}) catch &.{};
    }
    return std.fmt.bufPrint(out, "\x1b[1;{d}{c}", .{ m, final }) catch &.{};
}

fn ss3(out: *[32]u8, final: u8, tilde_n: u16, mods: Mods) []const u8 {
    const m = modParam(mods);
    if (m == 1) return std.fmt.bufPrint(out, "\x1bO{c}", .{final}) catch &.{};
    return std.fmt.bufPrint(out, "\x1b[{d};{d}~", .{ tilde_n, m }) catch &.{};
}

fn tilde(out: *[32]u8, n: u16, mods: Mods) []const u8 {
    const m = modParam(mods);
    if (m == 1) return std.fmt.bufPrint(out, "\x1b[{d}~", .{n}) catch &.{};
    return std.fmt.bufPrint(out, "\x1b[{d};{d}~", .{ n, m }) catch &.{};
}

test "event tags" {
    const e: Event = .{ .focus = true };
    switch (e) {
        .focus => |on| if (!on) unreachable,
        else => unreachable,
    }
}

test "encode arrows" {
    var buf: [32]u8 = undefined;
    const up = encodeKey(&buf, .{ .code = @intFromEnum(KeySym.up) }, .{});
    try std.testing.expectEqualStrings("\x1b[A", up);
    const app = encodeKey(&buf, .{ .code = @intFromEnum(KeySym.up) }, .{ .app_cursor = true });
    try std.testing.expectEqualStrings("\x1bOA", app);
    const ctrl = encodeKey(&buf, .{
        .code = @intFromEnum(KeySym.up),
        .mods = .{ .ctrl = true },
    }, .{});
    try std.testing.expectEqualStrings("\x1b[1;5A", ctrl);
}

test "encode ctrl letter and alt" {
    var buf: [32]u8 = undefined;
    const c = encodeKey(&buf, .{ .code = 'c', .mods = .{ .ctrl = true } }, .{});
    try std.testing.expectEqualStrings("\x03", c);
    const alt = encodeKey(&buf, .{ .code = 'x', .mods = .{ .alt = true } }, .{});
    try std.testing.expectEqualStrings("\x1bx", alt);
    const tab = encodeKey(&buf, .{ .code = @intFromEnum(KeySym.tab) }, .{});
    try std.testing.expectEqualStrings("\t", tab);
    const bt = encodeKey(&buf, .{
        .code = @intFromEnum(KeySym.tab),
        .mods = .{ .shift = true },
    }, .{});
    try std.testing.expectEqualStrings("\x1b[Z", bt);
    const del = encodeKey(&buf, .{ .code = @intFromEnum(KeySym.delete) }, .{});
    try std.testing.expectEqualStrings("\x1b[3~", del);
    const f1 = encodeKey(&buf, .{ .code = @intFromEnum(KeySym.f1) }, .{});
    try std.testing.expectEqualStrings("\x1bOP", f1);
}

test "encode mouse sgr" {
    var buf: [32]u8 = undefined;
    const press = encodeMouse(&buf, .{
        .x = 0,
        .y = 0,
        .button = .left,
        .action = .press,
    }, 4, 2, .{ .tracking = .btn, .sgr = true });
    try std.testing.expectEqualStrings("\x1b[<0;4;2M", press);
    const rel = encodeMouse(&buf, .{
        .x = 0,
        .y = 0,
        .button = .left,
        .action = .release,
    }, 4, 2, .{ .tracking = .btn, .sgr = true });
    try std.testing.expectEqualStrings("\x1b[<0;4;2m", rel);
    const wheel = encodeMouse(&buf, .{
        .x = 0,
        .y = 0,
        .button = .wheel_up,
        .action = .press,
    }, 1, 1, .{ .tracking = .btn, .sgr = true });
    try std.testing.expectEqualStrings("\x1b[<64;1;1M", wheel);
    const skip = encodeMouse(&buf, .{
        .x = 0,
        .y = 0,
        .button = .left,
        .action = .press,
    }, 1, 1, .{ .tracking = .off, .sgr = true });
    try std.testing.expectEqual(@as(usize, 0), skip.len);
}

test "encode mouse urxvt and pixels" {
    var buf: [32]u8 = undefined;
    const urxvt = encodeMouse(&buf, .{
        .x = 0,
        .y = 0,
        .button = .left,
        .action = .press,
    }, 4, 2, .{ .tracking = .btn, .urxvt = true });
    try std.testing.expectEqualStrings("\x1b[32;4;2M", urxvt);
    const px = encodeMouse(&buf, .{
        .x = 10,
        .y = 20,
        .button = .left,
        .action = .press,
    }, 4, 2, .{ .tracking = .btn, .sgr = true, .pixels = true });
    try std.testing.expectEqualStrings("\x1b[<0;11;21M", px);
}

test "encode paste bracket and filter" {
    var buf: [64]u8 = undefined;
    const p = encodePaste(&buf, "hi\nthere", true);
    try std.testing.expectEqualStrings("\x1b[200~hi\rthere\x1b[201~", p);
    const q = encodePaste(&buf, "hi\x1b[201~x", true);
    try std.testing.expectEqualStrings("\x1b[200~hix\x1b[201~", q);
    const raw = encodePaste(&buf, "a\x1bx\nb", false);
    try std.testing.expectEqualStrings("ax\rb", raw);
}
