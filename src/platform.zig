//! Host window lifecycle. No window-system calls.

const std = @import("std");
const Engine = @import("engine.zig").Engine;
const EngineOptions = @import("engine.zig").Options;

pub const WindowId = enum(u32) { _ };

pub const Options = struct {
    title: []const u8 = "zt",
    engine: EngineOptions = .{},
};

pub const Window = struct {
    id: WindowId,
    title: []const u8,
    engine: Engine,
};

pub const Platform = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(Window),
    next_id: u32,

    pub fn init(allocator: std.mem.Allocator) Platform {
        return .{
            .allocator = allocator,
            .windows = .empty,
            .next_id = 0,
        };
    }

    pub fn deinit(self: *Platform) void {
        for (self.windows.items) |*w| w.engine.deinit();
        self.windows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn open(self: *Platform, options: Options) std.mem.Allocator.Error!WindowId {
        const id: WindowId = @enumFromInt(self.next_id);
        self.next_id += 1;
        var engine = try Engine.init(self.allocator, options.engine);
        errdefer engine.deinit();
        try self.windows.append(self.allocator, .{
            .id = id,
            .title = options.title,
            .engine = engine,
        });
        return id;
    }

    pub fn close(self: *Platform, id: WindowId) void {
        const i = self.indexOf(id);
        self.windows.items[i].engine.deinit();
        _ = self.windows.orderedRemove(i);
    }

    pub fn get(self: *Platform, id: WindowId) *Window {
        return &self.windows.items[self.indexOf(id)];
    }

    fn indexOf(self: *const Platform, id: WindowId) usize {
        for (self.windows.items, 0..) |w, i| {
            if (w.id == id) return i;
        }
        unreachable;
    }
};

test "open and close" {
    const gpa = std.testing.allocator;
    var host = Platform.init(gpa);
    defer host.deinit();
    const opts: Options = .{ .engine = .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
    } };
    const a = try host.open(opts);
    try std.testing.expectEqual(@as(usize, 1), host.windows.items.len);
    try std.testing.expectEqualStrings("zt", host.get(a).title);
    try std.testing.expectEqual(@as(u16, 8), host.get(a).engine.screen.cols);
    const b = try host.open(.{ .title = "other", .engine = opts.engine });
    try std.testing.expectEqual(@as(usize, 2), host.windows.items.len);
    host.close(a);
    try std.testing.expectEqual(@as(usize, 1), host.windows.items.len);
    try std.testing.expectEqual(b, host.windows.items[0].id);
    try std.testing.expectEqualStrings("other", host.get(b).title);
    host.close(b);
    try std.testing.expectEqual(@as(usize, 0), host.windows.items.len);
}

test "deinit closes remaining" {
    const gpa = std.testing.allocator;
    var host = Platform.init(gpa);
    _ = try host.open(.{ .engine = .{
        .cols = 8,
        .rows = 2,
        .buf_cap = 64,
        .cell_w = 2,
        .cell_h = 2,
    } });
    host.deinit();
}
