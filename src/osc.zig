//! OSC (ESC ]) — OSC 8 hyperlinks. Other OSCs are ignored.

const Vt = @import("vt.zig").VtState;

pub fn dispatch(vt: *Vt, bytes: []const u8) void {
    if (bytes.len < 4 or bytes[0] != 0x1b or bytes[1] != ']') return;

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

    switch (id) {
        8 => osc8(vt, bytes, i),
        else => {},
    }
}

fn osc8(vt: *Vt, bytes: []const u8, start: usize) void {
    var i = start;
    if (i >= bytes.len or bytes[i] != ';') return;
    i += 1;
    while (i < bytes.len and bytes[i] != ';') i += 1;
    if (i >= bytes.len or bytes[i] != ';') return;
    i += 1;
    const uri_start = i;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == 0x07 or bytes[i] == 0x1b) break;
    }
    vt.flags.osc8 = i > uri_start;
}
