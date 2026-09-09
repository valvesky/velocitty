//! Intrusive LRU: hashmap + doubly-linked list of `u32` slab indexes.
//!
//! After `init`, get/peek/put/evict do not allocate. Nodes live in one arena
//! allocation; the map is reserved to `capacity`.

const std = @import("std");
const assert = std.debug.assert;

pub fn Lru(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Map = std.AutoHashMapUnmanaged(K, u32);
        const none: u32 = std.math.maxInt(u32);

        const Node = struct {
            key: K,
            value: V,
            prev: u32 = none,
            next: u32 = none,
        };

        allocator: std.mem.Allocator,
        capacity: u32,
        nodes: []Node,
        map: Map,
        head: u32 = none,
        tail: u32 = none,
        len: u32 = 0,

        pub fn init(allocator: std.mem.Allocator, capacity: u32) std.mem.Allocator.Error!Self {
            assert(capacity > 0);
            const nodes = try allocator.alloc(Node, capacity);
            errdefer allocator.free(nodes);
            var map: Map = .empty;
            try map.ensureTotalCapacity(allocator, capacity);
            return .{
                .allocator = allocator,
                .capacity = capacity,
                .nodes = nodes,
                .map = map,
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit(self.allocator);
            self.allocator.free(self.nodes);
            self.* = undefined;
        }

        pub fn clear(self: *Self) void {
            self.head = none;
            self.tail = none;
            self.map.clearRetainingCapacity();
            self.len = 0;
        }

        pub fn get(self: *Self, key: K) ?*V {
            const i = self.map.get(key) orelse return null;
            self.touch(i);
            return &self.nodes[i].value;
        }

        /// Hit only. Does not move the LRU (vt fill peek).
        pub fn peek(self: *const Self, key: K) ?*V {
            const i = self.map.get(key) orelse return null;
            return &self.nodes[i].value;
        }

        pub fn put(self: *Self, key: K, value: V) void {
            if (self.map.get(key)) |i| {
                self.nodes[i].value = value;
                self.touch(i);
                return;
            }
            const i = if (self.len == self.capacity) self.evict() else blk: {
                const n = self.len;
                self.len += 1;
                break :blk n;
            };
            self.nodes[i] = .{ .key = key, .value = value };
            self.map.putAssumeCapacity(key, i);
            self.prepend(i);
        }

        fn evict(self: *Self) u32 {
            const i = self.tail;
            assert(i != none);
            self.unlink(i);
            _ = self.map.remove(self.nodes[i].key);
            return i;
        }

        fn touch(self: *Self, i: u32) void {
            self.unlink(i);
            self.prepend(i);
        }

        fn prepend(self: *Self, i: u32) void {
            self.nodes[i].prev = none;
            self.nodes[i].next = self.head;
            if (self.head != none) {
                self.nodes[self.head].prev = i;
            } else {
                self.tail = i;
            }
            self.head = i;
        }

        fn unlink(self: *Self, i: u32) void {
            const n = self.nodes[i];
            if (n.prev != none) {
                self.nodes[n.prev].next = n.next;
            } else {
                self.head = n.next;
            }
            if (n.next != none) {
                self.nodes[n.next].prev = n.prev;
            } else {
                self.tail = n.prev;
            }
        }
    };
}

test "lru evicts least recently used" {
    const gpa = std.testing.allocator;
    var cache = try Lru(u32, u32).init(gpa, 2);
    defer cache.deinit();

    cache.put(1, 10);
    cache.put(2, 20);
    cache.put(3, 30);
    try std.testing.expect(cache.get(1) == null);
    try std.testing.expectEqual(@as(u32, 20), cache.get(2).?.*);
    try std.testing.expectEqual(@as(u32, 30), cache.get(3).?.*);
}

test "lru peek does not refresh recency" {
    const gpa = std.testing.allocator;
    var cache = try Lru(u32, u32).init(gpa, 2);
    defer cache.deinit();

    cache.put(1, 10);
    cache.put(2, 20);
    try std.testing.expectEqual(@as(u32, 10), cache.peek(1).?.*);
    cache.put(3, 30);
    try std.testing.expect(cache.get(1) == null);
    try std.testing.expectEqual(@as(u32, 20), cache.get(2).?.*);
    try std.testing.expectEqual(@as(u32, 30), cache.get(3).?.*);
}

test "lru get refreshes recency" {
    const gpa = std.testing.allocator;
    var cache = try Lru(u32, u32).init(gpa, 2);
    defer cache.deinit();

    cache.put(1, 10);
    cache.put(2, 20);
    try std.testing.expectEqual(@as(u32, 10), cache.get(1).?.*);
    cache.put(3, 30);
    try std.testing.expect(cache.get(2) == null);
    try std.testing.expectEqual(@as(u32, 10), cache.get(1).?.*);
    try std.testing.expectEqual(@as(u32, 30), cache.get(3).?.*);
}

test "lru reuses slab past capacity" {
    const gpa = std.testing.allocator;
    var cache = try Lru(u32, u32).init(gpa, 4);
    defer cache.deinit();

    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        cache.put(i, i * 10);
    }
    try std.testing.expect(cache.get(0) == null);
    try std.testing.expect(cache.get(3) == null);
    try std.testing.expectEqual(@as(u32, 40), cache.get(4).?.*);
    try std.testing.expectEqual(@as(u32, 70), cache.get(7).?.*);
}
