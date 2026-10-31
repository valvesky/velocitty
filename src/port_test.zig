const std = @import("std");
const builtin = @import("builtin");
const Platform = @import("platform/platform.zig");
const CircBuffer = @import("circbuffer.zig").CircBuffer;

test {
    _ = @import("main.zig");
    _ = @import("circbuffer.zig");
    _ = @import("firehose_test.zig");
}

test "Peak PTY spawns, resizes, drains output and reports child exit" {
    const argv: []const [*:0]const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/d", "/c", "echo velocitty-port-ready" }
    else
        &.{ "/bin/sh", "-c", "printf velocitty-port-ready" };
    var pty = try Platform.Pty.open(.{ .cols = 80, .rows = 24 }, .{ .argv = argv });
    defer pty.close();
    pty.setWinsize(.{ .cols = 90, .rows = 30 });
    var buffer = try CircBuffer.create(std.testing.allocator, 65536);
    defer buffer.destroy();
    var eof = false;
    for (0..1000) |_| {
        buffer.readSource(Platform.PtySource{ .pty = &pty }, 200, null, null) catch {
            eof = true;
            break;
        };
    }
    try std.testing.expect(eof);
    const n: usize = @intCast(@min(buffer.head, buffer.capacity));
    if (std.mem.indexOf(u8, buffer.storage[0..n], "velocitty-port-ready") == null) {
        std.debug.print("PTY output ({d} bytes): {f}\n", .{ n, std.ascii.hexEscape(buffer.storage[0..n], .lower) });
        return error.TestUnexpectedResult;
    }
}

test "Windows PTY input backpressure and close do not block the UI" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var pty = try Platform.Pty.open(.{ .cols = 80, .rows = 24 }, .{
        .argv = &.{ "powershell.exe", "-NoLogo", "-NoProfile", "-Command", "Start-Sleep -Seconds 30" },
    });
    const payload = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    const start = std.Io.Timestamp.now(std.testing.io, .awake);
    pty.write(payload);
    const sent = std.Io.Timestamp.now(std.testing.io, .awake);
    pty.close();
    const closed = std.Io.Timestamp.now(std.testing.io, .awake);
    try std.testing.expect(sent.nanoseconds - start.nanoseconds < 500_000_000);
    try std.testing.expect(closed.nanoseconds - sent.nanoseconds < 5_000_000_000);
}
