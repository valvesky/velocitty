//! C0 controls (0x00..0x1F, plus space/DEL as classified by the run splitter).

const Vt = @import("vt.zig").VtState;

pub fn dispatch(vt: *Vt, byte: u8) void {
    switch (byte) {
        0x07 => {}, // BEL
        0x08 => vt.backspace(),
        0x09 => vt.tab(),
        // Peak's PTY clears OPOST, so the kernel does not turn NL into CR NL.
        // Unix apps send LF alone and expect column 0 on the next row.
        0x0A => {
            vt.carriageReturn();
            vt.index();
        },
        0x0B, 0x0C => vt.index(),
        0x0D => vt.carriageReturn(),
        0x0E => vt.gl = 1,
        0x0F => vt.gl = 0,
        // Run splitter treats 0x20 as C0 (outside 0x21..0x7E).
        0x20 => vt.printCodepoint(' '),
        0x7F => {}, // DEL
        else => {},
    }
}
