const std = @import("std");
const vt_rand = @import("vt_rand.zig");

pub fn main(init: std.process.Init) !void {
    var iters: u32 = 10000;
    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();
    _ = it.next();
    if (it.next()) |a| {
        iters = try std.fmt.parseInt(u32, a, 10);
    }
    try vt_rand.run(init.gpa, iters, 0xB0BA_CAFE);
    std.debug.print("fuzz-render: {d} iters ok\n", .{iters});
}
