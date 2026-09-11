//! libxev loop. Waits on events. 1/hz timer only after EAGAIN.

const std = @import("std");
const xev = @import("xev");
const Engine = @import("engine.zig").Engine;
const Debug = @import("debug.zig");

/// The loop struct exists so that it's easier to understand
/// and test very specific behaviour of VT.
pub const Loop = struct {

    allocator: std.mem.Allocator,
    pool: *xev.ThreadPool,
    inner: xev.Loop,
    timer: xev.Timer,
    timer_c: xev.Completion = .{},
    engine: ?*Engine = null,
    userdata: ?*anyopaque = null,
    on_frame: ?*const fn (*Loop) void = null,
    armed: bool = false,
    stopped: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Loop {
        const pool = try allocator.create(xev.ThreadPool);
        errdefer allocator.destroy(pool);
        pool.* = xev.ThreadPool.init(.{});
        errdefer {
            pool.shutdown();
            pool.deinit();
        }
        const inner = try xev.Loop.init(.{ .thread_pool = pool });
        errdefer inner.deinit();
        return .{
            .allocator = allocator,
            .pool = pool,
            .inner = inner,
            .timer = try xev.Timer.init(),
        };
    }

    pub fn deinit(self: *Loop) void {
        self.inner.deinit();
        self.timer.deinit();
        self.pool.shutdown();
        self.pool.deinit();
        self.allocator.destroy(self.pool);
        self.* = undefined;
    }

    pub fn run(self: *Loop) !void {
        try self.inner.run(.until_done);
    }

    pub fn tick(self: *Loop) !void {
        try self.inner.run(.once);
    }

    pub fn stop(self: *Loop) void {
        self.stopped = true;
        self.inner.stop();
    }

    /// Buffer bytes. Caller kicks once on EAGAIN.
    pub fn ingest(self: *Loop, bytes: []const u8) void {
        self.engine.?.ingest(bytes);
    }

    /// Drain a readable source until EAGAIN. Firehose truncates; paint on EAGAIN.
    pub fn drain(self: *Loop, reader: anytype) void {
        const Clock = struct {
            pub fn now(_: @This()) i128 {
                return nowNs();
            }
        };
        const Ctx = struct {
            loop: *Loop,
            pub fn onFrame(c: @This(), _: *Engine) void {
                if (c.loop.on_frame) |f| f(c.loop);
            }
        };
        _ = self.engine.?.pump(reader, Clock{}, Ctx{ .loop = self }) catch |err| {
            Debug.log("pty: {}", .{err});
            self.stop();
            return;
        };
        if (self.engine.?.buffer.available() != 0) self.kick();
    }

    /// EAGAIN: refresh if 1/hz has passed, otherwise arm a one-shot timer.
    pub fn kick(self: *Loop) void {
        const engine = self.engine.?;
        if (engine.buffer.available() == 0) return;
        const now = nowNs();
        const did = engine.onWouldBlock(now) catch unreachable;
        if (did) {
            if (self.on_frame) |f| f(self);
        } else {
            self.arm(now);
        }
    }

    fn arm(self: *Loop, now_ns: i128) void {
        if (self.armed) return;
        const engine = self.engine.?;
        const period: i128 = @divTrunc(1_000_000_000, engine.hz);
        var delay_ms: u64 = 1;
        if (engine.last_refresh_ns) |last| {
            const left = period - (now_ns - last);
            if (left > 0) delay_ms = @intCast(@divTrunc(left + 999_999, 1_000_000));
        }
        delay_ms = @max(delay_ms, 1);
        self.armed = true;
        self.timer.run(&self.inner, &self.timer_c, delay_ms, Loop, self, &onTimer);
    }

    fn onTimer(
        ud: ?*Loop,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        const self = ud.?;
        self.armed = false;
        _ = r catch return .disarm;
        if (self.stopped) return .disarm;
        const engine = self.engine.?;
        const now = nowNs();
        const did = if (engine.buffer.available() != 0)
            engine.onWouldBlock(now) catch unreachable
        else
            false;
        if (did) {
            if (self.on_frame) |f| f(self);
        } else if (engine.buffer.available() != 0) {
            self.arm(now);
        }
        return .disarm;
    }
};

fn nowNs() i128 {
    return @intCast(std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds);
}

test "ingest refreshes" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    var loop = try Loop.init(gpa);
    defer loop.deinit();
    loop.engine = &engine;
    loop.ingest("ab\ncd");
    loop.kick();
    try loop.run();
    try std.testing.expectEqual(@as(u21, 'a'), engine.screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), engine.screen.cell(1, 0).codepoint);
}

test "timer refreshes after period" {
    const gpa = std.testing.allocator;
    var engine = try Engine.init(gpa, .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
        .hz = 60,
    });
    defer engine.deinit();
    var loop = try Loop.init(gpa);
    defer loop.deinit();
    loop.engine = &engine;
    loop.ingest("ab\n");
    loop.kick();
    try std.testing.expectEqual(@as(u21, 'a'), engine.screen.cell(0, 0).codepoint);
    loop.ingest("cd");
    loop.kick();
    try std.testing.expectEqual(@as(u21, 'a'), engine.screen.cell(0, 0).codepoint);
    try loop.run();
    try std.testing.expectEqual(@as(u21, 'c'), engine.screen.cell(1, 0).codepoint);
}
