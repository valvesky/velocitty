//! Type rasterizes TrueType fonts into a cached atlas.
//!
//! UTF-8 in, glyphs and metrics out. Multiple faces, fallbacks, weight,
//! style, ligatures, CJK, and emoji are in scope.

const std = @import("std");
const assert = std.debug.assert;

pub const TrueType = @import("type/truetype.zig");
pub const Atlas = @import("type/atlas.zig").Atlas;
pub const Cache = @import("type/cache.zig");
pub const EastAsian = @import("type/east_asian.zig");

pub const Error = error{
    InvalidFont,
    UnsupportedTable,
    GlyphNotFound,
    AtlasFull,
    InvalidUtf8,
    Unimplemented,
} || std.mem.Allocator.Error;

pub const FontId = enum(u32) { _ };

pub const Weight = enum(u16) {
    thin = 100,
    extra_light = 200,
    light = 300,
    regular = 400,
    medium = 500,
    semi_bold = 600,
    bold = 700,
    extra_bold = 800,
    black = 900,
    _,
};

pub const Style = packed struct {
    italic: bool = false,
    bold: bool = false,
};

pub const FaceOptions = struct {
    weight: ?Weight = null,
    style: Style = .{},
};

pub const Options = struct {
    atlas_width: u32 = 1024,
    atlas_height: u32 = 1024,
    cache_capacity: u32 = 2048,
    ligatures: bool = true,
    color_emoji: bool = true,
};

pub const Glyph = struct {
    font_id: FontId,
    glyph_id: u16,
    advance: f32,
    bearing_x: f32,
    bearing_y: f32,
    width: u16,
    height: u16,
    atlas_x: u16,
    atlas_y: u16,
};

pub const Cell = struct {
    glyph: Glyph,
    x: f32,
    y: f32,
    codepoint: u21,
};

pub const GlyphKey = struct {
    font_id: u32,
    glyph_id: u32,
    size_px: u16,
    flags: u16,
};

pub const ascii_lo: u21 = 32;
pub const ascii_hi: u21 = 126;
const ascii_n = ascii_hi - ascii_lo + 1;

pub const Face = struct {
    id: FontId,
    font: TrueType.Font,
    weight: Weight,
    style: Style,
};

pub const GlyphStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    raster_ns: u64 = 0,
    atlas_ns: u64 = 0,
};

/// Loaded faces, fallback order, coverage atlas, and glyph LRU.
pub const Context = struct {
    allocator: std.mem.Allocator,
    options: Options,
    faces: std.ArrayList(Face),
    fallbacks: std.ArrayList(FontId),
    primary: ?FontId,
    atlas: Atlas,
    cache: Cache.Lru(GlyphKey, Glyph),
    ascii: [ascii_n]?Glyph = @splat(null),
    replacement: ?Glyph = null,
    ascii_size: u16 = 0,
    stats: GlyphStats = .{},

    pub fn init(allocator: std.mem.Allocator, options: Options) Error!Context {
        assert(options.atlas_width > 0);
        assert(options.atlas_height > 0);
        assert(options.cache_capacity > 0);
        var atlas = try Atlas.init(allocator, options.atlas_width, options.atlas_height);
        errdefer atlas.deinit();
        const cache = try Cache.Lru(GlyphKey, Glyph).init(allocator, options.cache_capacity);
        return .{
            .allocator = allocator,
            .options = options,
            .faces = .empty,
            .fallbacks = .empty,
            .primary = null,
            .atlas = atlas,
            .cache = cache,
        };
    }

    pub fn deinit(self: *Context) void {
        self.cache.deinit();
        self.atlas.deinit();
        self.fallbacks.deinit(self.allocator);
        self.faces.deinit(self.allocator);
        self.* = undefined;
    }

    /// `bytes` must outlive this context. The first added face becomes primary.
    pub fn addFont(self: *Context, bytes: []const u8, options: FaceOptions) Error!FontId {
        const font = try TrueType.Font.open(bytes);
        const id: FontId = @enumFromInt(@as(u32, @intCast(self.faces.items.len)));
        try self.faces.append(self.allocator, .{
            .id = id,
            .font = font,
            .weight = options.weight orelse .regular,
            .style = options.style,
        });
        if (self.primary == null) self.primary = id;
        return id;
    }

    pub fn select(self: *Context, id: FontId) void {
        assert(@intFromEnum(id) < self.faces.items.len);
        self.primary = id;
    }

    pub fn setFallbacks(self: *Context, ids: []const FontId) Error!void {
        for (ids) |id| {
            assert(@intFromEnum(id) < self.faces.items.len);
        }
        self.fallbacks.clearRetainingCapacity();
        try self.fallbacks.appendSlice(self.allocator, ids);
    }

    pub fn atlasPixels(self: *const Context) []const u8 {
        return self.atlas.pixels;
    }

    /// Rasterize printable ASCII 32..126 into `ascii` at `ascii_size`.
    pub fn warmAscii(self: *Context) Error!void {
        if (self.primary == null or self.ascii_size == 0) return;
        var cp: u21 = ascii_lo;
        while (cp <= ascii_hi) : (cp += 1) {
            const slot = cp - ascii_lo;
            if (self.ascii[slot] != null) continue;
            self.ascii[slot] = try self.rasterize(cp, self.ascii_size);
        }
    }

    pub fn clearAtlas(self: *Context) void {
        self.resetGlyphCaches();
        self.warmAscii() catch {};
    }

    fn resetGlyphCaches(self: *Context) void {
        self.atlas.clear();
        self.cache.clear();
        self.ascii = @splat(null);
        self.replacement = null;
    }

    pub fn metrics(self: *const Context, size_px: f32) Error!TrueType.Metrics {
        assert(size_px > 0);
        const id = self.primary orelse return error.InvalidFont;
        return self.faces.items[@intFromEnum(id)].font.metrics(size_px);
    }

    /// Hot-path lookup. No stats, no raster, no LRU move.
    pub fn peekGlyph(self: *const Context, codepoint: u21, size_px: f32) ?Glyph {
        if (size_px <= 0) return null;
        const size_u: u16 = @intFromFloat(@max(1, @round(size_px)));
        if (size_u != self.ascii_size) return null;
        if (codepoint >= ascii_lo and codepoint <= ascii_hi) {
            return self.ascii[codepoint - ascii_lo];
        }
        if (codepoint == 0xFFFD) return self.replacement;
        const resolved = self.resolve(codepoint) catch return null;
        const key: GlyphKey = .{
            .font_id = @intFromEnum(resolved.id),
            .glyph_id = resolved.gid,
            .size_px = size_u,
            .flags = 0,
        };
        if (self.cache.peek(key)) |g| return g.*;
        return null;
    }

    pub fn ensureGlyph(self: *Context, codepoint: u21, size_px: f32) Error!Glyph {
        return self.glyph(codepoint, size_px);
    }

    pub fn glyph(self: *Context, codepoint: u21, size_px: f32) Error!Glyph {
        assert(size_px > 0);
        const size_u: u16 = @intFromFloat(@max(1, @round(size_px)));
        if (size_u != self.ascii_size) {
            self.ascii = @splat(null);
            self.replacement = null;
            self.ascii_size = size_u;
            try self.warmAscii();
        }
        if (codepoint >= ascii_lo and codepoint <= ascii_hi) {
            const slot = codepoint - ascii_lo;
            if (self.ascii[slot]) |g| {
                self.stats.hits += 1;
                return g;
            }
            const g = try self.rasterize(codepoint, size_u);
            self.ascii[slot] = g;
            return g;
        }
        if (codepoint == 0xFFFD) {
            if (self.replacement) |g| {
                self.stats.hits += 1;
                return g;
            }
            const g = try self.rasterize(codepoint, size_u);
            self.replacement = g;
            return g;
        }
        const resolved = try self.resolve(codepoint);
        const key: GlyphKey = .{
            .font_id = @intFromEnum(resolved.id),
            .glyph_id = resolved.gid,
            .size_px = size_u,
            .flags = 0,
        };
        if (self.cache.peek(key)) |g| {
            self.stats.hits += 1;
            return g.*;
        }
        const g = try self.rasterizeAt(resolved.id, resolved.gid, size_u);
        self.cache.put(key, g);
        return g;
    }

    fn rasterize(self: *Context, codepoint: u21, size_u: u16) Error!Glyph {
        const resolved = try self.resolve(codepoint);
        return self.rasterizeAt(resolved.id, resolved.gid, size_u);
    }

    fn rasterizeAt(self: *Context, id: FontId, gid: u16, size_u: u16) Error!Glyph {
        self.stats.misses += 1;
        const size: f32 = @floatFromInt(size_u);
        const face = self.faces.items[@intFromEnum(id)];
        const t0 = nowNs();
        const bmp = try face.font.rasterize(self.allocator, gid, size);
        defer self.allocator.free(bmp.pixels);
        const t1 = nowNs();
        const adv_fu = try face.font.advanceWidth(gid);
        const m = try face.font.metrics(size);
        const scale = size / @as(f32, @floatFromInt(m.units_per_em));
        const g = try self.pack(id, gid, bmp, @as(f32, @floatFromInt(adv_fu)) * scale);
        const t2 = nowNs();
        self.stats.raster_ns += @intCast(t1 - t0);
        self.stats.atlas_ns += @intCast(t2 - t1);
        return g;
    }

    pub fn layoutUtf8(self: *Context, text: []const u8, size_px: f32, out: *std.ArrayList(Cell)) Error!void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        assert(size_px > 0);
        var view = std.unicode.Utf8View.initUnchecked(text);
        var it = view.iterator();
        var x: f32 = 0;
        while (it.nextCodepoint()) |cp| {
            const g = try self.glyph(cp, size_px);
            try out.append(self.allocator, .{
                .glyph = g,
                .x = x,
                .y = 0,
                .codepoint = cp,
            });
            x += g.advance;
        }
    }

    fn resolve(self: *const Context, codepoint: u21) Error!struct { id: FontId, gid: u16 } {
        const primary = self.primary orelse return error.InvalidFont;
        if (try self.faces.items[@intFromEnum(primary)].font.glyphIndex(codepoint)) |g| {
            if (g != 0) return .{ .id = primary, .gid = g };
        }
        for (self.fallbacks.items) |id| {
            if (try self.faces.items[@intFromEnum(id)].font.glyphIndex(codepoint)) |g| {
                if (g != 0) return .{ .id = id, .gid = g };
            }
        }
        return .{ .id = primary, .gid = 0 };
    }

    fn pack(self: *Context, id: FontId, gid: u16, bmp: TrueType.Bitmap, advance: f32) Error!Glyph {
        if (bmp.width == 0 or bmp.height == 0) {
            return .{
                .font_id = id,
                .glyph_id = gid,
                .advance = advance,
                .bearing_x = @floatFromInt(bmp.bearing_x),
                .bearing_y = @floatFromInt(bmp.bearing_y),
                .width = 0,
                .height = 0,
                .atlas_x = 0,
                .atlas_y = 0,
            };
        }
        const rect = self.atlas.pack(bmp.width, bmp.height) orelse blk: {
            self.resetGlyphCaches();
            break :blk self.atlas.pack(bmp.width, bmp.height) orelse return error.AtlasFull;
        };
        self.atlas.blit(rect, bmp.pixels);
        return .{
            .font_id = id,
            .glyph_id = gid,
            .advance = advance,
            .bearing_x = @floatFromInt(bmp.bearing_x),
            .bearing_y = @floatFromInt(bmp.bearing_y),
            .width = bmp.width,
            .height = bmp.height,
            .atlas_x = @intCast(rect.x),
            .atlas_y = @intCast(rect.y),
        };
    }
};

fn nowNs() i128 {
    return @intCast(std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds);
}

test {
    _ = @import("type/truetype.zig");
    _ = @import("type/atlas.zig");
    _ = @import("type/cache.zig");
    _ = @import("type/east_asian.zig");
}

test "context init and addFont" {
    const gpa = std.testing.allocator;
    var ctx = try Context.init(gpa, .{
        .atlas_width = 64,
        .atlas_height = 64,
        .cache_capacity = 8,
    });
    defer ctx.deinit();

    var bytes: [12]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, bytes[4..6], 0, .big);
    std.mem.writeInt(u16, bytes[6..8], 0, .big);
    std.mem.writeInt(u16, bytes[8..10], 0, .big);
    std.mem.writeInt(u16, bytes[10..12], 0, .big);

    try std.testing.expectError(error.InvalidFont, ctx.addFont(&bytes, .{}));
    try std.testing.expectEqual(@as(usize, 64 * 64), ctx.atlasPixels().len);
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(gpa);
    try std.testing.expectError(error.InvalidUtf8, ctx.layoutUtf8("\x80", 16, &cells));
}

test "glyph and layout from system font" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io, "/usr/share/fonts/liberation/LiberationMono-Regular.ttf", .{}) catch return;
    defer file.close(io);
    const n = file.length(io) catch return;
    const bytes = try gpa.alloc(u8, n);
    defer gpa.free(bytes);
    _ = file.readPositionalAll(io, bytes, 0) catch return;

    var ctx = try Context.init(gpa, .{
        .atlas_width = 256,
        .atlas_height = 256,
        .cache_capacity = 32,
    });
    defer ctx.deinit();
    _ = try ctx.addFont(bytes, .{});
    const g = try ctx.glyph('A', 16);
    try std.testing.expect(g.advance > 0);
    try std.testing.expect(g.width > 0);
    try std.testing.expect(g.height > 0);
    var top: usize = 0;
    var bot: usize = 0;
    const mid = g.height / 2;
    var row: u16 = 0;
    while (row < g.height) : (row += 1) {
        var col: u16 = 0;
        while (col < g.width) : (col += 1) {
            const cover = ctx.atlas.pixels[@as(usize, g.atlas_y + row) * ctx.atlas.width + (g.atlas_x + col)];
            if (cover < 80) continue;
            if (row < mid) top += 1 else bot += 1;
        }
    }
    try std.testing.expect(bot > top);
    const again = try ctx.glyph('A', 16);
    try std.testing.expectEqual(g.atlas_x, again.atlas_x);
    try std.testing.expectEqual(g.atlas_y, again.atlas_y);

    ctx.clearAtlas();
    const hits_after_warm = ctx.stats.hits;
    const cached = try ctx.glyph('A', 16);
    try std.testing.expectEqual(hits_after_warm + 1, ctx.stats.hits);
    try std.testing.expect(cached.advance > 0);
    try std.testing.expect(cached.width > 0);
    try std.testing.expect(cached.height > 0);

    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(gpa);
    try ctx.layoutUtf8("A", 16, &cells);
    try std.testing.expectEqual(@as(usize, 1), cells.items.len);
    try std.testing.expectEqual(@as(u21, 'A'), cells.items[0].codepoint);
}
