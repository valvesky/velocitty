const std = @import("std");

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
