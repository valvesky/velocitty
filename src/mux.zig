//! Tiling multiplexer.

const std = @import("std");
const assert = std.debug.assert;

pub const Split = enum { horizontal, vertical };

pub const PaneId = enum(u32) { _ };
pub const NodeId = enum(u32) { _ };

pub const Node = union(enum) {
    pane: PaneId,
    split: struct {
        dir: Split,
        ratio: u8,
        a: NodeId,
        b: NodeId,
    },
};

pub const Tile = struct {
    pane: PaneId,
    col: u16,
    row: u16,
    cols: u16,
    rows: u16,
};

pub const Mux = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node),
    root: NodeId,
    focused: PaneId,
    next_pane: u32,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Mux {
        var nodes: std.ArrayList(Node) = .empty;
        try nodes.append(allocator, .{ .pane = @enumFromInt(0) });
        return .{
            .allocator = allocator,
            .nodes = nodes,
            .root = @enumFromInt(0),
            .focused = @enumFromInt(0),
            .next_pane = 1,
        };
    }

    pub fn deinit(self: *Mux) void {
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn splitFocused(self: *Mux, dir: Split) std.mem.Allocator.Error!PaneId {
        const node_id = self.findPaneNode(self.focused);
        const new_pane: PaneId = @enumFromInt(self.next_pane);
        self.next_pane += 1;
        const a = try self.push(.{ .pane = self.focused });
        const b = try self.push(.{ .pane = new_pane });
        self.nodes.items[@intFromEnum(node_id)] = .{ .split = .{
            .dir = dir,
            .ratio = 50,
            .a = a,
            .b = b,
        } };
        self.focused = new_pane;
        return new_pane;
    }

    pub fn attachPane(self: *Mux, pane: PaneId, dir: Split) std.mem.Allocator.Error!void {
        const node_id = self.findPaneNode(self.focused);
        const a = try self.push(.{ .pane = self.focused });
        const b = try self.push(.{ .pane = pane });
        self.nodes.items[@intFromEnum(node_id)] = .{ .split = .{
            .dir = dir,
            .ratio = 50,
            .a = a,
            .b = b,
        } };
        self.focused = pane;
    }

    pub fn tiles(self: *const Mux, cols: u16, rows: u16, out: *std.ArrayList(Tile)) std.mem.Allocator.Error!void {
        assert(cols > 0);
        assert(rows > 0);
        try self.walk(self.root, 0, 0, cols, rows, out);
    }

    fn walk(
        self: *const Mux,
        id: NodeId,
        col: u16,
        row: u16,
        cols: u16,
        rows: u16,
        out: *std.ArrayList(Tile),
    ) std.mem.Allocator.Error!void {
        switch (self.nodes.items[@intFromEnum(id)]) {
            .pane => |pane| try out.append(self.allocator, .{
                .pane = pane,
                .col = col,
                .row = row,
                .cols = cols,
                .rows = rows,
            }),
            .split => |s| switch (s.dir) {
                .horizontal => {
                    const w: u16 = @intCast(@max(@as(u32, 1), @as(u32, cols) * s.ratio / 100));
                    const rest = cols -| w;
                    try self.walk(s.a, col, row, w, rows, out);
                    try self.walk(s.b, col + w, row, if (rest == 0) 1 else rest, rows, out);
                },
                .vertical => {
                    const h: u16 = @intCast(@max(@as(u32, 1), @as(u32, rows) * s.ratio / 100));
                    const rest = rows -| h;
                    try self.walk(s.a, col, row, cols, h, out);
                    try self.walk(s.b, col, row + h, cols, if (rest == 0) 1 else rest, out);
                },
            },
        }
    }

    fn push(self: *Mux, node: Node) std.mem.Allocator.Error!NodeId {
        const id: NodeId = @enumFromInt(@as(u32, @intCast(self.nodes.items.len)));
        try self.nodes.append(self.allocator, node);
        return id;
    }

    fn findPaneNode(self: *const Mux, pane: PaneId) NodeId {
        for (self.nodes.items, 0..) |n, i| {
            switch (n) {
                .pane => |p| if (p == pane) return @enumFromInt(@as(u32, @intCast(i))),
                .split => {},
            }
        }
        unreachable;
    }
};

test "one pane fills" {
    const gpa = std.testing.allocator;
    var mux = try Mux.init(gpa);
    defer mux.deinit();
    var out: std.ArrayList(Tile) = .empty;
    defer out.deinit(gpa);
    try mux.tiles(80, 24, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(u16, 80), out.items[0].cols);
    try std.testing.expectEqual(@as(u16, 24), out.items[0].rows);
}

test "vertical split halves rows" {
    const gpa = std.testing.allocator;
    var mux = try Mux.init(gpa);
    defer mux.deinit();
    _ = try mux.splitFocused(.vertical);
    var out: std.ArrayList(Tile) = .empty;
    defer out.deinit(gpa);
    try mux.tiles(80, 24, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(@as(u16, 12), out.items[0].rows);
    try std.testing.expectEqual(@as(u16, 12), out.items[1].rows);
    try std.testing.expectEqual(@as(u16, 12), out.items[1].row);
}
