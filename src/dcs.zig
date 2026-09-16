//! DCS (ESC P): DECRQSS, synchronized updates. Sixel/XTGETTCAP are ignored.

const std = @import("std");
const Vt = @import("vt.zig").VtState;

pub fn dispatch(vt: *Vt, bytes: []const u8) void {
    if (bytes.len < 3 or bytes[0] != 0x1b or bytes[1] != 'P') return;

    var i: usize = 2;
    var priv: u8 = 0;
    if (i < bytes.len and ((bytes[i] >= 0x20 and bytes[i] <= 0x2F) or (bytes[i] >= 0x3C and bytes[i] <= 0x3F))) {
        priv = bytes[i];
        i += 1;
    }

    switch (priv) {
        '$' => if (i < bytes.len and bytes[i] == 'q') decrqss(vt, payload(bytes, i + 1)),
        '=' => {
            // DCS = 1 s / DCS = 2 s  (iTerm synchronized updates)
            var p: u16 = 0;
            while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {
                p = p *% 10 +% (bytes[i] - '0');
            }
            if (i < bytes.len and bytes[i] == 's') {
                if (p == 1) vt.flags.sync_output = true;
                if (p == 2) vt.flags.sync_output = false;
            }
        },
        '+' => if (i < bytes.len and bytes[i] == 'q') xtgettcap(vt, payload(bytes, i + 1)),
        else => if (isSixel(bytes)) vt.feedSixel(bytes),
    }
}

fn isSixel(bytes: []const u8) bool {
    var i: usize = 2;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c == 'q') return true;
        if ((c >= '0' and c <= '9') or c == ';') continue;
        return false;
    }
    return false;
}

fn payload(bytes: []const u8, start: usize) []const u8 {
    var end = bytes.len;
    if (end > 0 and bytes[end - 1] == 0x07) {
        end -= 1;
    } else if (end >= 2 and bytes[end - 2] == 0x1b and bytes[end - 1] == '\\') {
        end -= 2;
    }
    if (start >= end) return &.{};
    return bytes[start..end];
}

fn decrqss(vt: *Vt, query: []const u8) void {
    if (query.len == 1 and query[0] == 'r') {
        const g = vt.grid();
        vt.respondFmt("\x1bP1$r{d};{d}r\x1b\\", .{ g.scroll_top + 1, g.scroll_bottom + 1 });
        return;
    }
    if (query.len == 1 and query[0] == 'm') {
        decrqssSgr(vt);
        return;
    }
    if (query.len == 2 and query[0] == ' ' and query[1] == 'q') {
        var mode: u16 = switch (vt.cursor_style) {
            .block => 2,
            .underline => 4,
            .bar => 6,
        };
        if (vt.flags.cursor_blink) mode -= 1;
        vt.respondFmt("\x1bP1$r{d} q\x1b\\", .{mode});
        return;
    }
    vt.respond("\x1bP0$r\x1b\\");
}

fn decrqssSgr(vt: *Vt) void {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    const a = vt.grid().attrs;
    n = append(buf[0..], n, "0");
    if (a.bold) n = append(buf[0..], n, "1");
    if (a.dim) n = append(buf[0..], n, "2");
    if (a.italic) n = append(buf[0..], n, "3");
    if (a.underline) {
        if (a.underline_style > 1) {
            var tmp: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "4:{d}", .{a.underline_style}) catch "4";
            n = append(buf[0..], n, s);
        } else n = append(buf[0..], n, "4");
    }
    if (a.blink) n = append(buf[0..], n, "5");
    if (a.inverse) n = append(buf[0..], n, "7");
    if (a.hidden) n = append(buf[0..], n, "8");
    if (a.strikethrough) n = append(buf[0..], n, "9");
    if (n > 0) n -= 1; // strip last ;
    if (n < buf.len) {
        buf[n] = 'm';
        n += 1;
    }
    vt.respond("\x1bP1$r");
    vt.respond(buf[0..n]);
    vt.respond("\x1b\\");
}

fn append(buf: []u8, n: usize, s: []const u8) usize {
    if (n + s.len + 1 > buf.len) return n;
    @memcpy(buf[n .. n + s.len], s);
    buf[n + s.len] = ';';
    return n + s.len + 1;
}

const Cap = struct { name: []const u8, value: []const u8 };

const caps = [_]Cap{
    .{ .name = "TN", .value = "xterm-256color" },
    .{ .name = "name", .value = "xterm-256color" },
    .{ .name = "Co", .value = "256" },
    .{ .name = "colors", .value = "256" },
    .{ .name = "RGB", .value = "8" },
    .{ .name = "Tc", .value = "" },
    .{ .name = "bce", .value = "" },
    .{ .name = "kmous", .value = "\x1b[<" },
    .{ .name = "sitm", .value = "\x1b[3m" },
    .{ .name = "ritm", .value = "\x1b[23m" },
    .{ .name = "smul", .value = "\x1b[4m" },
    .{ .name = "rmul", .value = "\x1b[24m" },
};

fn xtgettcap(vt: *Vt, query: []const u8) void {
    var it = std.mem.splitScalar(u8, query, ';');
    while (it.next()) |hexname| {
        if (hexname.len == 0) continue;
        var name_buf: [32]u8 = undefined;
        const name = hexDecode(hexname, &name_buf) orelse {
            vt.respond("\x1bP0+r");
            vt.respond(hexname);
            vt.respond("\x1b\\");
            continue;
        };
        var found: ?[]const u8 = null;
        for (caps) |cap| {
            if (std.mem.eql(u8, cap.name, name)) {
                found = cap.value;
                break;
            }
        }
        if (found) |val| {
            var hex_val: [64]u8 = undefined;
            const hv = hexEncode(val, &hex_val);
            vt.respond("\x1bP1+r");
            vt.respond(hexname);
            vt.respond("=");
            vt.respond(hv);
            vt.respond("\x1b\\");
        } else {
            vt.respond("\x1bP0+r");
            vt.respond(hexname);
            vt.respond("\x1b\\");
        }
    }
}

fn hexDecode(s: []const u8, out: []u8) ?[]u8 {
    if (s.len < 2 or s.len % 2 != 0 or s.len / 2 > out.len) return null;
    var i: usize = 0;
    while (i < s.len) : (i += 2) {
        const hi = hexNibble(s[i]) orelse return null;
        const lo = hexNibble(s[i + 1]) orelse return null;
        out[i / 2] = (hi << 4) | lo;
    }
    return out[0 .. s.len / 2];
}

fn hexEncode(s: []const u8, out: []u8) []u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (s) |b| {
        if (n + 2 > out.len) break;
        out[n] = hex[b >> 4];
        out[n + 1] = hex[b & 0xF];
        n += 2;
    }
    return out[0..n];
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}
