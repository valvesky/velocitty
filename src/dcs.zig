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
        '+' => {}, // XTGETTCAP: no terminfo database
        else => {},
    }
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
