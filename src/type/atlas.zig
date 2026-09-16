//! There are possibly billions of UNICODE characters out there.
//! 
//! We will use an LRU Cache to keep the atlas updated.
//!
//! Coverage atlas with a shelf packer.

const std = @import("std");
const assert = std.debug.assert;

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const Atlas = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u8,
    shelf_x: u32,
    shelf_y: u32,
    shelf_h: u32,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) std.mem.Allocator.Error!Atlas {
        assert(width > 0);
        assert(height > 0);
        const pixels = try allocator.alloc(u8, width * height);
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
            .shelf_x = 0,
            .shelf_y = 0,
            .shelf_h = 0,
        };
    }

    pub fn deinit(self: *Atlas) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn pack(self: *Atlas, w: u32, h: u32) ?Rect {
        assert(w > 0);
        assert(h > 0);
        if (w > self.width or h > self.height) return null;
        if (self.shelf_x + w > self.width) {
            self.shelf_y += self.shelf_h;
            self.shelf_x = 0;
            self.shelf_h = 0;
        }
        if (self.shelf_y + h > self.height) return null;
        const rect: Rect = .{ .x = self.shelf_x, .y = self.shelf_y, .w = w, .h = h };
        self.shelf_x += w;
        if (h > self.shelf_h) self.shelf_h = h;
        return rect;
    }

    pub fn blit(self: *Atlas, rect: Rect, src: []const u8) void {
        assert(src.len == rect.w * rect.h);
        var row: u32 = 0;
        while (row < rect.h) : (row += 1) {
            const dst_off = (rect.y + row) * self.width + rect.x;
            const src_off = row * rect.w;
            @memcpy(self.pixels[dst_off..][0..rect.w], src[src_off..][0..rect.w]);
        }
    }

    pub fn clear(self: *Atlas) void {
        @memset(self.pixels, 0);
        self.shelf_x = 0;
        self.shelf_y = 0;
        self.shelf_h = 0;
    }
};

/// RGBA atlas (AARRGGBB) for color-bitmap glyphs.
pub const AtlasRgba = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u32,
    shelf_x: u32,
    shelf_y: u32,
    shelf_h: u32,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) std.mem.Allocator.Error!AtlasRgba {
        assert(width > 0);
        assert(height > 0);
        const pixels = try allocator.alloc(u32, width * height);
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
            .shelf_x = 0,
            .shelf_y = 0,
            .shelf_h = 0,
        };
    }

    pub fn deinit(self: *AtlasRgba) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn pack(self: *AtlasRgba, w: u32, h: u32) ?Rect {
        assert(w > 0);
        assert(h > 0);
        if (w > self.width or h > self.height) return null;
        if (self.shelf_x + w > self.width) {
            self.shelf_y += self.shelf_h;
            self.shelf_x = 0;
            self.shelf_h = 0;
        }
        if (self.shelf_y + h > self.height) return null;
        const rect: Rect = .{ .x = self.shelf_x, .y = self.shelf_y, .w = w, .h = h };
        self.shelf_x += w;
        if (h > self.shelf_h) self.shelf_h = h;
        return rect;
    }

    pub fn blit(self: *AtlasRgba, rect: Rect, src: []const u8) void {
        assert(src.len == rect.w * rect.h * 4);
        var row: u32 = 0;
        while (row < rect.h) : (row += 1) {
            var col: u32 = 0;
            while (col < rect.w) : (col += 1) {
                const si = (@as(usize, row) * rect.w + col) * 4;
                const r = src[si];
                const g = src[si + 1];
                const b = src[si + 2];
                const a = src[si + 3];
                self.pixels[(rect.y + row) * self.width + (rect.x + col)] =
                    (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
            }
        }
    }

    pub fn clear(self: *AtlasRgba) void {
        @memset(self.pixels, 0);
        self.shelf_x = 0;
        self.shelf_y = 0;
        self.shelf_h = 0;
    }
};

test "shelf pack wrap and fill" {
    const gpa = std.testing.allocator;
    var atlas = try Atlas.init(gpa, 8, 8);
    defer atlas.deinit();

    const a = atlas.pack(5, 3).?;
    try std.testing.expectEqual(@as(u32, 0), a.x);
    try std.testing.expectEqual(@as(u32, 0), a.y);
    const b = atlas.pack(4, 3).?;
    try std.testing.expectEqual(@as(u32, 0), b.x);
    try std.testing.expectEqual(@as(u32, 3), b.y);
    try std.testing.expect(atlas.pack(8, 8) == null);
    atlas.clear();
    try std.testing.expect(atlas.pack(8, 8) != null);
}

test "blit writes coverage" {
    const gpa = std.testing.allocator;
    var atlas = try Atlas.init(gpa, 4, 2);
    defer atlas.deinit();
    const rect = atlas.pack(2, 1).?;
    atlas.blit(rect, &.{ 9, 8 });
    try std.testing.expectEqual(@as(u8, 9), atlas.pixels[0]);
    try std.testing.expectEqual(@as(u8, 8), atlas.pixels[1]);
    try std.testing.expectEqual(@as(u8, 0), atlas.pixels[2]);
}
