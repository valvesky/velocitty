const std = @import("std");
const Term = @import("term.zig").Term;

pub const C0 = struct {
    pub fn apply(bytes: []const u8, term: *Term) void {
        for (bytes) |c| {
            switch (c) {
                '\n', 0x0b, 0x0c => term.lineFeed(),
                '\r' => term.grid().cursor.col = 0,
                0x08 => term.grid().cursor.col -|= 1,
                '\t' => {
                    const g = term.grid();
                    g.cursor.col = @min(term.cols - 1, g.cursor.col + 8 - (g.cursor.col % 8));
                },
                0x0e => term.gl = 1,
                0x0f => term.gl = 0,
                else => {},
            }
        }
    }
};
