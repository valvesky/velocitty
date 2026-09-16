//! OSC (ESC ]) — titles, colors, OSC 8 hyperlinks. Other OSCs are ignored.

const std = @import("std");
const Debug = @import("debug.zig");
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
    vt.debug_osc_id = id;

    switch (id) {
        0, 2 => vt.setTitle(payload),
        1, 30 => {},
        4 => osc4(vt, payload, bytes),
        7 => osc7(vt, payload),
        8 => osc8(vt, payload),
        9 => osc9(vt, payload),
        99 => osc99(vt, payload),
        777 => osc777(vt, payload),
        556 => {
            Debug.applyOsc(&vt.debug_overlay, payload);
            vt.markDirtyAll();
        },
        176 => osc176(vt, payload),
        133 => {
            if (payload.len > 0) vt.shell_mark = payload[0];
        },
        10 => oscColor(vt, payload, bytes, .fg, 10),
        11 => oscColor(vt, payload, bytes, .bg, 11),
        12 => oscColor(vt, payload, bytes, .cursor, 12),
        17 => oscSel(vt, payload, bytes, .bg, 17),
        19 => oscSel(vt, payload, bytes, .fg, 19),
        22 => osc22(vt, payload),
        52 => osc52(vt, payload),
        66 => osc66(vt, payload),
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
        117 => {
            vt.have_sel_bg = false;
            vt.markDirtyAll();
        },
        119 => {
            vt.have_sel_fg = false;
            vt.markDirtyAll();
        },
        105 => {},
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

fn osc7(vt: *Vt, payload: []const u8) void {
    var path = payload;
    if (std.mem.startsWith(u8, path, "file://")) {
        path = path["file://".len..];
        if (std.mem.indexOfScalar(u8, path, '/')) |slash| path = path[slash..];
    }
    vt.cwd.clearRetainingCapacity();
    vt.cwd.appendSlice(vt.allocator, path) catch {};
}

fn osc176(vt: *Vt, payload: []const u8) void {
    vt.app_id.clearRetainingCapacity();
    vt.app_id.appendSlice(vt.allocator, payload) catch {};
    vt.app_id_dirty = true;
}

fn oscNotify(vt: *Vt, title: []const u8, body: []const u8) void {
    Debug.log("notify title={s} body={s}", .{ title, body });
    vt.notify_title.clearRetainingCapacity();
    vt.notify_body.clearRetainingCapacity();
    vt.notify_title.appendSlice(vt.allocator, title) catch {};
    vt.notify_body.appendSlice(vt.allocator, body) catch {};
    vt.notify_pending = true;
}

/// iTerm2 Growl: OSC 9 ; message. ConEmu/WT progress is OSC 9;4;... and cwd is OSC 9;9;path.
fn osc9(vt: *Vt, payload: []const u8) void {
    if (payload.len >= 2 and payload[0] == '4' and payload[1] == ';') {
        Debug.log("osc 9 progress {s}", .{payload});
        return;
    }
    if (payload.len >= 2 and payload[0] == '9' and payload[1] == ';') {
        osc7(vt, payload[2..]);
        return;
    }
    if (payload.len == 0) return;
    oscNotify(vt, "", payload);
}

fn osc99(vt: *Vt, payload: []const u8) void {
    if (payload.len == 0) return;
    const semi = std.mem.lastIndexOfScalar(u8, payload, ';');
    const params = if (semi) |n| payload[0..n] else payload;
    const text = if (semi) |n| payload[n + 1 ..] else payload;
    if (std.mem.indexOfScalar(u8, params, '=') != null) {
        if (kittyNotifyClose(params) or text.len == 0) return;
        if (kittyNotifyTitle(params)) oscNotify(vt, text, "") else oscNotify(vt, "", text);
        return;
    }
    if (semi) |n| {
        oscNotify(vt, payload[0..n], payload[n + 1 ..]);
    } else {
        oscNotify(vt, "", payload);
    }
}

fn kittyNotifyClose(params: []const u8) bool {
    var it = std.mem.splitScalar(u8, params, ':');
    while (it.next()) |kv| {
        if (kv.len >= 3 and kv[0] == 'd' and kv[1] == '=' and kv[2] == '2') return true;
    }
    return false;
}

fn kittyNotifyTitle(params: []const u8) bool {
    var it = std.mem.splitScalar(u8, params, ':');
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv, "p=title")) return true;
    }
    return false;
}

fn osc777(vt: *Vt, payload: []const u8) void {
    if (!std.mem.startsWith(u8, payload, "notify;")) return;
    const rest = payload["notify;".len..];
    if (std.mem.indexOfScalar(u8, rest, ';')) |n| {
        oscNotify(vt, rest[0..n], rest[n + 1 ..]);
    } else {
        oscNotify(vt, "", rest);
    }
}

fn osc22(vt: *Vt, payload: []const u8) void {
    const name = std.mem.trim(u8, payload, " \t");
    vt.pointer = pointerId(name);
    vt.pointer_dirty = true;
}

fn pointerId(name: []const u8) u8 {
    if (name.len == 0) return 0;
    if (eqlAny(name, &.{ "default", "arrow", "left_ptr" })) return 0;
    if (eqlAny(name, &.{ "text", "xterm", "ibeam", "IBeam" })) return 1;
    if (eqlAny(name, &.{ "pointer", "hand", "hand2", "pointing_hand" })) return 2;
    if (eqlAny(name, &.{ "wait", "watch", "progress" })) return 3;
    if (eqlAny(name, &.{ "crosshair", "cross" })) return 4;
    if (eqlAny(name, &.{ "not-allowed", "pirate", "X_cursor" })) return 5;
    if (eqlAny(name, &.{ "help", "question_arrow" })) return 6;
    return 0;
}

fn eqlAny(name: []const u8, opts: []const []const u8) bool {
    for (opts) |o| if (std.mem.eql(u8, name, o)) return true;
    return false;
}

fn osc52(vt: *Vt, payload: []const u8) void {
    const semi = std.mem.indexOfScalar(u8, payload, ';') orelse return;
    const which = payload[0..semi];
    const data = payload[semi + 1 ..];
    if (data.len == 1 and data[0] == '?') return; // query: ignored
    var kind: u8 = 0;
    if (which.len == 0 or std.mem.indexOfScalar(u8, which, 'c') != null) kind |= 1;
    if (std.mem.indexOfScalar(u8, which, 'p') != null or std.mem.indexOfScalar(u8, which, 's') != null) kind |= 2;
    if (kind == 0) kind = 1;
    const dec = decodeB64(vt.allocator, data) orelse return;
    vt.clip.clearRetainingCapacity();
    vt.clip.appendSlice(vt.allocator, dec) catch {};
    vt.allocator.free(dec);
    vt.clip_kind = kind;
}

fn decodeB64(allocator: std.mem.Allocator, src: []const u8) ?[]u8 {
    var n: usize = 0;
    for (src) |ch| {
        if (ch != ' ' and ch != '\n' and ch != '\r' and ch != '\t') n += 1;
    }
    if (n == 0) return null;
    const clean = allocator.alloc(u8, n + 3) catch return null;
    defer allocator.free(clean);
    var i: usize = 0;
    for (src) |ch| {
        if (ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t') continue;
        clean[i] = ch;
        i += 1;
    }
    while (i % 4 != 0) : (i += 1) clean[i] = '=';
    const dec = std.base64.standard.Decoder;
    const out_n = dec.calcSizeForSlice(clean[0..i]) catch return null;
    const out = allocator.alloc(u8, out_n) catch return null;
    dec.decode(out, clean[0..i]) catch {
        allocator.free(out);
        return null;
    };
    return out;
}

fn osc66(vt: *Vt, payload: []const u8) void {
    const semi = std.mem.indexOfScalar(u8, payload, ';') orelse return;
    const text = payload[semi + 1 ..];
    if (text.len == 0) return;
    if (std.unicode.Utf8View.init(text)) |view| {
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| vt.printCodepoint(cp);
    } else |_| {
        for (text) |b| vt.printCodepoint(b);
    }
}

fn oscSel(vt: *Vt, payload: []const u8, raw: []const u8, which: Which, id: u16) void {
    if (payload.len == 1 and payload[0] == '?') {
        const c = switch (which) {
            .fg => if (vt.have_sel_fg) vt.sel_fg else vt.scheme.fg,
            .bg => if (vt.have_sel_bg) vt.sel_bg else vt.scheme.bg,
            .cursor => vt.scheme.cursor,
        };
        vt.respondFmt("\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}{s}", .{
            id, c.r, c.r, c.g, c.g, c.b, c.b, terminator(raw),
        });
        return;
    }
    const c = parseColorSpec(payload) orelse return;
    switch (which) {
        .fg => {
            vt.sel_fg = c;
            vt.have_sel_fg = true;
        },
        .bg => {
            vt.sel_bg = c;
            vt.have_sel_bg = true;
        },
        .cursor => {},
    }
    vt.markDirtyAll();
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
    if (std.mem.startsWith(u8, t, "rgba:")) {
        t = t[5..];
        var it = std.mem.splitScalar(u8, t, '/');
        const rs = it.next() orelse return null;
        const gs = it.next() orelse return null;
        const bs = it.next() orelse return null;
        const as = it.next() orelse return null;
        return .{
            .r = hexComp(rs) orelse return null,
            .g = hexComp(gs) orelse return null,
            .b = hexComp(bs) orelse return null,
            .a = hexComp(as) orelse return null,
        };
    }
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
        8 => Color{
            .r = hexByte(t[0..2]) orelse return null,
            .g = hexByte(t[2..4]) orelse return null,
            .b = hexByte(t[4..6]) orelse return null,
            .a = hexByte(t[6..8]) orelse return null,
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
