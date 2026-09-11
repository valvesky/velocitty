const std = @import("std");
const builtin = @import("builtin");

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode == .Debug) {
        std.log.debug(fmt, args);
    }
}
