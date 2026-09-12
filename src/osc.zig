//! OSC (ESC ]) — titles, colors, OSC 8 hyperlinks. Other OSCs are ignored.

const std = @import("std");
const Vt = @import("vt.zig").VtState;
const Color = @import("vt.zig").Color;

pub fn dispatch(vt: *Vt, bytes: []const u8) void {
    if (bytes.len < 3 or bytes[0] != 0x1b or bytes[1] != ']') return;

    var i: usize = 2;
    var id: u16 = 0;
    var have = false;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c >= '0' and c <= '9') {
            have = true;
            id = id *% 10 +% (c - '0');
        } else break;
    }
    if (!have) return;
    if (i < bytes.len and bytes[i] == ';') i += 1;
    const payload = stripSt(bytes[i..]);

    switch (id) {
        0, 2 => vt.setTitle(payload),
        1, 22, 30 => {},
        4 => osc4(vt, payload, bytes),
        7 => {}, // cwd
        8 => osc8(vt, payload),
        9, 99, 777, 555, 176, 133 => {},
        10 => oscColor(vt, payload, bytes, .fg, 10),
        11 => oscColor(vt, payload, bytes, .bg, 11),
        12 => oscColor(vt, payload, bytes, .cursor, 12),
        17, 19 => {}, // selection colors
        52 => {}, // clipboard
        104 => osc104(vt, payload),
        110 => {
            vt.scheme.fg = vt.orig.fg;
            vt.markDirtyAll();
        },
        111 => {
            vt.scheme.bg = vt.orig.bg;
            vt.markDirtyAll();
        },
        112 => vt.scheme.cursor = vt.orig.cursor,
        117, 119, 105 => {},
        else => {},
    }
}

fn stripSt(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == 0x07) return s[0 .. s.len - 1];
    if (s.len >= 2 and s[s.len - 2] == 0x1b and s[s.len - 1] == '\\') return s[0 .. s.len - 2];
    return s;
}

fn terminator(bytes: []const u8) []const u8 {
    if (bytes.len > 0 and bytes[bytes.len - 1] == 0x07) return "\x07";
    return "\x1b\\";
}

fn osc8(vt: *Vt, payload: []const u8) void {
    // id=...;URI  — empty URI closes
    var i: usize = 0;
    while (i < payload.len and payload[i] != ';') i += 1;
    if (i >= payload.len) {
        vt.flags.osc8 = false;
        return;
    }
    const uri = payload[i + 1 ..];
    vt.flags.osc8 = uri.len > 0;
}

fn osc4(vt: *Vt, payload: []const u8, raw: []const u8) void {
    var rest = payload;
    while (rest.len > 0) {
        const idx_end = std.mem.indexOfScalar(u8, rest, ';') orelse break;
        const idx = std.fmt.parseInt(u16, rest[0..idx_end], 10) catch break;
        rest = rest[idx_end + 1 ..];
        const spec_end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const spec = rest[0..spec_end];
        if (idx > 255) break;
        if (spec.len == 1 and spec[0] == '?') {
            const c = vt.table[idx];
            vt.respondFmt("\x1b]4;{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}", .{
                idx, c.r, c.r, c.g, c.g, c.b, c.b, terminator(raw),
            });
        } else if (parseColorSpec(spec)) |c| {
            vt.table[idx] = c;
            if (idx < 16) vt.scheme.palette[idx] = c;
            vt.markDirtyAll();
        }
        if (spec_end == rest.len) break;
        rest = rest[spec_end + 1 ..];
    }
}

fn osc104(vt: *Vt, payload: []const u8) void {
    if (payload.len == 0) {
        vt.initTable();
        vt.markDirtyAll();
        return;
    }
    var it = std.mem.splitScalar(u8, payload, ';');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const idx = std.fmt.parseInt(u16, part, 10) catch continue;
        if (idx > 255) continue;
        const orig = makeOrigIndex(vt.orig, idx);
        vt.table[idx] = orig;
        if (idx < 16) vt.scheme.palette[idx] = orig;
    }
    vt.markDirtyAll();
}

fn makeOrigIndex(scheme: @import("vt.zig").Scheme, i: u16) Color {
    if (i < 16) return scheme.palette[i];
    if (i < 232) {
        const x = i - 16;
        const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
        return .{ .r = levels[x / 36], .g = levels[(x % 36) / 6], .b = levels[x % 6] };
    }
    const v: u8 = 8 + 10 * @as(u8, @intCast(i - 232));
    return .{ .r = v, .g = v, .b = v };
}

const Which = enum { fg, bg, cursor };

fn oscColor(vt: *Vt, payload: []const u8, raw: []const u8, which: Which, id: u16) void {
    if (payload.len == 1 and payload[0] == '?') {
        const c = switch (which) {
            .fg => vt.scheme.fg,
            .bg => vt.scheme.bg,
            .cursor => vt.scheme.cursor,
        };
        vt.respondFmt("\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}", .{
            id, c.r, c.r, c.g, c.g, c.b, c.b, terminator(raw),
        });
        return;
    }
    const c = parseColorSpec(payload) orelse return;
    switch (which) {
        .fg => vt.scheme.fg = c,
        .bg => vt.scheme.bg = c,
        .cursor => vt.scheme.cursor = c,
    }
    vt.markDirtyAll();
}

fn parseColorSpec(s: []const u8) ?Color {
    var t = std.mem.trim(u8, s, " \t");
    if (std.mem.startsWith(u8, t, "rgb:")) {
        t = t[4..];
        var it = std.mem.splitScalar(u8, t, '/');
        const rs = it.next() orelse return null;
        const gs = it.next() orelse return null;
        const bs = it.next() orelse return null;
        return .{
            .r = hexComp(rs) orelse return null,
            .g = hexComp(gs) orelse return null,
            .b = hexComp(bs) orelse return null,
        };
    }
    if (t.len > 0 and t[0] == '#') t = t[1..];
    return switch (t.len) {
        3 => Color{
            .r = (hexNibble(t[0]) orelse return null) * 17,
            .g = (hexNibble(t[1]) orelse return null) * 17,
            .b = (hexNibble(t[2]) orelse return null) * 17,
        },
        6 => Color{
            .r = hexByte(t[0..2]) orelse return null,
            .g = hexByte(t[2..4]) orelse return null,
            .b = hexByte(t[4..6]) orelse return null,
        },
        12 => Color{
            .r = hexByte(t[0..2]) orelse return null,
            .g = hexByte(t[4..6]) orelse return null,
            .b = hexByte(t[8..10]) orelse return null,
        },
        else => null,
    };
}

fn hexComp(s: []const u8) ?u8 {
    const v = std.fmt.parseInt(u32, s, 16) catch return null;
    return switch (s.len) {
        1 => @intCast(v * 17),
        2 => @truncate(v),
        3 => @truncate(v >> 4),
        4 => @truncate(v >> 8),
        else => null,
    };
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexByte(s: []const u8) ?u8 {
    const hi = hexNibble(s[0]) orelse return null;
    const lo = hexNibble(s[1]) orelse return null;
    return (hi << 4) | lo;
}
