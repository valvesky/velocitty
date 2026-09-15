//! 8-bit C1 controls (0x80..0x9F).

const Vt = @import("vt.zig").VtState;

pub fn dispatch(vt: *Vt, byte: u8) void {
    switch (byte) {
        0x84 => vt.index(), // IND
        0x85 => { // NEL
            vt.carriageReturn();
            vt.index();
        },
        0x88 => {}, // HTS (fixed 8-col tabs)
        0x8D => vt.reverseIndex(), // RI
        else => {},
    }
}
