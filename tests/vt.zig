const std = @import("std");
const harness = @import("harness.zig");

test "vt fixtures dump cells" {
    const gpa = std.testing.allocator;
    const dir_io = harness.io();
    var dir = try std.Io.Dir.cwd().openDir(dir_io, "tests/vt", .{ .iterate = true });
    defer dir.close(dir_io);

    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(dir_io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".in")) continue;
        n += 1;
        try runFixture(gpa, entry.name);
    }
    try std.testing.expect(n >= 5);
}

fn runFixture(gpa: std.mem.Allocator, name: []const u8) !void {
    var in_buf: [128]u8 = undefined;
    const in_path = try std.fmt.bufPrint(&in_buf, "tests/vt/{s}", .{name});
    const raw = try std.Io.Dir.cwd().readFileAlloc(harness.io(), in_path, gpa, .unlimited);
    defer gpa.free(raw);
    const nl = std.mem.indexOfScalar(u8, raw, '\n') orelse return error.InvalidFixture;
    var dim_it = std.mem.tokenizeScalar(u8, raw[0..nl], ' ');
    const cols = try std.fmt.parseInt(u16, dim_it.next() orelse return error.InvalidFixture, 10);
    const rows = try std.fmt.parseInt(u16, dim_it.next() orelse return error.InvalidFixture, 10);
    const src = raw[nl + 1 ..];

    var screen = try harness.feedScreen(gpa, cols, rows, src);
    defer screen.deinit();

    const dump = try screen.dumpAlloc(gpa);
    defer gpa.free(dump);
    const cells = try screen.dumpCellsAlloc(gpa);
    defer gpa.free(cells);

    const stem = name[0 .. name.len - 3];
    var dump_buf: [128]u8 = undefined;
    const dump_path = try std.fmt.bufPrint(&dump_buf, "tests/vt/{s}.dump", .{stem});
    var cells_buf: [128]u8 = undefined;
    const cells_path = try std.fmt.bufPrint(&cells_buf, "tests/vt/{s}.cells", .{stem});
    try harness.expectTextFile(gpa, dump_path, dump);
    try harness.expectTextFile(gpa, cells_path, cells);
}
