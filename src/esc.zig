//! ESC (not CSI/OSC/DCS/APC) sequences: charset, cursor save, index, RIS.

const vt_mod = @import("vt.zig");
const Vt = vt_mod.VtState;

pub const EscSeq = struct {
    cmd: u8,
    arg: u8 = 0,

    pub fn parse(bytes: []const u8) ?EscSeq {
        if (bytes.len < 2 or bytes[0] != 0x1b) return null;
        return .{
            .cmd = bytes[1],
            .arg = if (bytes.len >= 3) bytes[2] else 0,
        };
    }
};

pub fn dispatch(vt: *Vt, bytes: []const u8) void {
    const seq = EscSeq.parse(bytes) orelse return;
    switch (seq.cmd) {
        'D' => vt.index(),
        'E' => {
            vt.grid().cursor.col = 0;
            vt.index();
        },
        'H' => vt.setTab(),
        'M' => vt.reverseIndex(),
        'N' => { // SS2
            vt.ss = 2;
            vt.ss_active = true;
        },
        'O' => { // SS3
            vt.ss = 3;
            vt.ss_active = true;
        },
        '7' => vt.saveCursor(),
        '8' => vt.restoreCursor(),
        'c' => vt.reset(),
        'n' => vt.gl = 2, // LS2
        'o' => vt.gl = 3, // LS3
        '=' => vt.flags.app_keypad = true,
        '>' => vt.flags.app_keypad = false,
        '(' => if (bytes.len >= 3) {
            vt.g0 = charsetOf(bytes[2]);
        },
        ')' => if (bytes.len >= 3) {
            vt.g1 = charsetOf(bytes[2]);
        },
        '*' => if (bytes.len >= 3) {
            vt.g2 = charsetOf(bytes[2]);
        },
        '+' => if (bytes.len >= 3) {
            vt.g3 = charsetOf(bytes[2]);
        },
        '#' => if (seq.arg == '8') vt.decaln(),
        else => {},
    }
}

pub fn charsetOf(c: u8) vt_mod.Charset {
    return if (c == '0') .dec_special else .ascii;
}

pub fn mapDecSpecial(cp: u21) u21 {
    return switch (cp) {
        '`' => 0x25C6,
        'a' => 0x2592,
        'f' => 0x00B0,
        'g' => 0x00B1,
        'j' => 0x2518,
        'k' => 0x2510,
        'l' => 0x250C,
        'm' => 0x2514,
        'n' => 0x253C,
        'o' => 0x23BA,
        'p' => 0x23BB,
        'q' => 0x2500,
        'r' => 0x23BC,
        's' => 0x23BD,
        't' => 0x251C,
        'u' => 0x2524,
        'v' => 0x2534,
        'w' => 0x252C,
        'x' => 0x2502,
        'y' => 0x2264,
        'z' => 0x2265,
        '{' => 0x03C0,
        '|' => 0x2260,
        '}' => 0x00A3,
        '~' => 0x00B7,
        '_' => 0x00A0,
        else => cp,
    };
}
