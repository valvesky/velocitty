///| CSI stands for Control Sequence Introducer
///! It's one of the most common ANSI escape sequences.
///! 
///! Used for styling, cursor movement, bracketed paste,
///! mode switching, deleting lines and more.
///! 
///! Invoked via ESC[

const std = @import("std");

const CsiSeq = @This();

intermediate: u8 = 0,
private: u8 = 0,
final: u8 = 0,
seq: []const u8 = "",
params: []u16 = &.{},

const CharKind = enum(u3) { digit, sep, inter, final, invalid };

const CHAR_MAP: [256]CharKind = initMap: {
    var map = [_]CharKind{.invalid} ** 256;
    for ('0'..'9' + 1) |c| map[c] = .digit;
    map[';'] = .sep;
    map[':'] = .sep;
    for (0x20..0x2F + 1) |c| map[c] = .inter;
    for (0x40..0x7E + 1) |c| map[c] = .final;
    break :initMap map;
};

/// Parses a raw byte sequence into a CsiSeq struct using `param_buf` as storage.
/// Returns a stub with `final = 0` if sequence is malformed or invalid.
pub fn parse(seq: []const u8, param_buf: []u16) CsiSeq {
    const STUB = CsiSeq{ .final = 0, .seq = seq };

    if (seq.len < 3 or seq[0] != 0x1b or seq[1] != '[') return STUB;

    const c2 = seq[2];
    const is_priv: u8 = @intFromBool(c2 >= 0x3C and c2 <= 0x3F);
    const priv = c2 * is_priv;

    var i: usize = 2 + is_priv;
    var n: usize = 0;
    var val: u16 = 0;
    var have: u16 = 0;
    var intermediate: u8 = 0;
    var is_valid: u8 = 1;

    const max_body = seq.len - 1;

    while (i < max_body) : (i += 1) {
        const c = seq[i];
        const kind = CHAR_MAP[c];

        const is_dig = @intFromBool(kind == .digit);
        const is_sep = @intFromBool(kind == .sep);
        const is_mid = @intFromBool(kind == .inter);
        const is_bad = @intFromBool(kind == .invalid or kind == .final);

        is_valid &= (is_bad ^ 1);
        have |= is_dig;
        val = (val *% 10 +% (c -% '0')) * is_dig + val * (is_dig ^ 1);

        if (is_sep != 0) {
            if (n < param_buf.len) param_buf[n] = val;
            n += 1;
            val = 0;
            have = 0;
        }

        intermediate = c * is_mid + intermediate * (is_mid ^ 1);
    }

    const push_last = (have | @intFromBool(n > 0) | @intFromBool(seq.len > 3 + is_priv));
    if (push_last != 0 and n < param_buf.len) {
        param_buf[n] = val;
        n += 1;
    }

    const final_byte = seq[seq.len - 1];
    const ok = is_valid & @intFromBool(CHAR_MAP[final_byte] == .final);

    return .{
        .intermediate = intermediate * ok,
        .private = priv * ok,
        .final = final_byte * ok,
        .seq = seq,
        .params = param_buf[0..(@min(n, param_buf.len) * ok)],
    };
}
