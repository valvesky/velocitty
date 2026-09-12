const std = @import("std");
const Term = @import("term.zig").Term;

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

    pub fn apply(self: EscSeq, term: *Term) void {
        switch (self.cmd) {
            'D' => term.index(),
            'E' => term.lineFeed(),
            'M' => term.reverseIndex(),
            '7' => term.saveCursor(),
            '8' => term.restoreCursor(),
            'c' => term.clear(),
            '=' => term.flags.app_keypad = true,
            '>' => term.flags.app_keypad = false,
            '(' => term.g0 = charsetOf(self.arg),
            ')' => term.g1 = charsetOf(self.arg),
            else => {},
        }
    }
};

fn charsetOf(c: u8) @import("term.zig").Charset {
    return switch (c) {
        '0' => .dec_special,
        else => .ascii,
    };
}
