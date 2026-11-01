//! TrueType / sfnt parser and glyph rasterizer (stb_truetype).

const std = @import("std");
const assert = std.debug.assert;
const Cbdt = @import("cbdt.zig");

const c = struct {
    extern fn zt_stb_init(storage: *anyopaque, data: [*]const u8, len: c_int, offset: c_int) callconv(.c) c_int;
    extern fn zt_stb_vmetrics(storage: *const anyopaque, ascent: *c_int, descent: *c_int, line_gap: *c_int, upem: *c_int) callconv(.c) void;
    extern fn zt_stb_num_glyphs(storage: *const anyopaque) callconv(.c) c_int;
    extern fn zt_stb_find_glyph(storage: *const anyopaque, codepoint: c_int) callconv(.c) c_int;
    extern fn zt_stb_advance(storage: *const anyopaque, glyph: c_int) callconv(.c) c_int;
    extern fn zt_stb_glyph_box(storage: *const anyopaque, glyph: c_int, size_px: f32, x0: *c_int, y0: *c_int, x1: *c_int, y1: *c_int) callconv(.c) void;
    extern fn zt_stb_make_glyph(storage: *const anyopaque, glyph: c_int, size_px: f32, out: [*]u8, w: c_int, h: c_int) callconv(.c) void;
    extern fn zt_stb_glyph_empty(storage: *const anyopaque, glyph: c_int) callconv(.c) c_int;
};

const info_cap = 256;

pub const Error = error{
    InvalidFont,
    UnsupportedTable,
    GlyphNotFound,
    Unimplemented,
} || std.mem.Allocator.Error;

pub const Bitmap = struct {
    width: u16,
    height: u16,
    bearing_x: i16,
    bearing_y: i16,
    advance: u16,
    pixels: []u8,
    color: bool = false,
};

pub const Metrics = struct {
    ascender: f32,
    descender: f32,
    line_gap: f32,
    units_per_em: u16,
};

pub const Font = struct {
    bytes: []const u8,
    index: u32 = 0,
    info: [info_cap]u8 align(8) = undefined,
    outline: bool = false,
    color: ?Cbdt.ColorFont = null,

    pub fn open(bytes: []const u8) Error!Font {
        return openIndex(bytes, 0);
    }

    pub fn openIndex(bytes: []const u8, index: u32) Error!Font {
        const offset = collectionOffset(bytes, index) orelse return error.InvalidFont;
        if (bytes.len > std.math.maxInt(c_int)) return error.InvalidFont;
        var font: Font = .{ .bytes = bytes, .index = index };
        font.outline = c.zt_stb_init(&font.info, bytes.ptr, @intCast(bytes.len), @intCast(offset)) != 0;
        font.color = Cbdt.ColorFont.parseAt(bytes, offset);
        if (!font.outline and font.color == null) return error.InvalidFont;
        return font;
    }

    fn storage(self: *const Font) *const anyopaque {
        return &self.info;
    }

    pub fn metrics(self: Font, size_px: f32) Error!Metrics {
        assert(size_px > 0);
        if (self.outline) {
            var ascent: c_int = 0;
            var descent: c_int = 0;
            var line_gap: c_int = 0;
            var upem: c_int = 0;
            c.zt_stb_vmetrics(self.storage(), &ascent, &descent, &line_gap, &upem);
            if (upem <= 0) return error.InvalidFont;
            const scale = size_px / @as(f32, @floatFromInt(upem));
            return .{
                .ascender = @as(f32, @floatFromInt(ascent)) * scale,
                .descender = @as(f32, @floatFromInt(descent)) * scale,
                .line_gap = @as(f32, @floatFromInt(line_gap)) * scale,
                .units_per_em = @intCast(upem),
            };
        }
        const col = self.color orelse return error.InvalidFont;
        if (col.units_per_em == 0) return error.InvalidFont;
        const scale = size_px / @as(f32, @floatFromInt(col.units_per_em));
        return .{
            .ascender = @as(f32, @floatFromInt(col.ascender)) * scale,
            .descender = @as(f32, @floatFromInt(col.descender)) * scale,
            .line_gap = @as(f32, @floatFromInt(col.line_gap)) * scale,
            .units_per_em = col.units_per_em,
        };
    }

    pub fn advanceWidth(self: Font, glyph_id: u16) Error!u16 {
        if (self.outline) {
            const n = c.zt_stb_num_glyphs(self.storage());
            if (glyph_id >= n) return error.GlyphNotFound;
            const adv = c.zt_stb_advance(self.storage(), glyph_id);
            if (adv < 0) return 0;
            return std.math.cast(u16, adv) orelse std.math.maxInt(u16);
        }
        const col = self.color orelse return error.GlyphNotFound;
        if (glyph_id >= col.num_glyphs) return error.GlyphNotFound;
        return col.advanceWidth(glyph_id);
    }

    pub fn glyphIndex(self: Font, codepoint: u21) Error!?u16 {
        if (self.color) |col| {
            if (col.glyphIndex(codepoint)) |g| {
                if (g != 0) return g;
            }
        }
        if (self.outline) {
            const g = c.zt_stb_find_glyph(self.storage(), @intCast(codepoint));
            if (g <= 0) return null;
            return std.math.cast(u16, g) orelse return error.InvalidFont;
        }
        return null;
    }

    pub fn hasDrawable(self: Font, glyph_id: u16) bool {
        if (self.color) |col| {
            if (col.hasBitmap(glyph_id)) return true;
        }
        if (self.outline) {
            return c.zt_stb_glyph_empty(self.storage(), glyph_id) == 0;
        }
        return false;
    }

    pub fn rasterize(self: Font, allocator: std.mem.Allocator, glyph_id: u16, size_px: f32) Error!Bitmap {
        assert(size_px > 0);
        if (self.color) |col| {
            if (try col.rasterize(allocator, glyph_id, size_px)) |bmp| return .{
                .width = bmp.width,
                .height = bmp.height,
                .bearing_x = bmp.bearing_x,
                .bearing_y = bmp.bearing_y,
                .advance = bmp.advance,
                .pixels = bmp.pixels,
                .color = true,
            };
        }
        if (!self.outline) {
            return .{
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = 0,
                .pixels = try allocator.alloc(u8, 0),
            };
        }
        const n = c.zt_stb_num_glyphs(self.storage());
        if (glyph_id >= n) return error.GlyphNotFound;
        const m = try self.metrics(size_px);
        const scale = size_px / @as(f32, @floatFromInt(m.units_per_em));
        const adv_fu = try self.advanceWidth(glyph_id);
        const adv: u16 = @intFromFloat(@max(0, @min(65535, @round(@as(f32, @floatFromInt(adv_fu)) * scale))));

        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        c.zt_stb_glyph_box(self.storage(), glyph_id, size_px, &x0, &y0, &x1, &y1);
        const w_i = x1 - x0;
        const h_i = y1 - y0;
        if (w_i <= 0 or h_i <= 0) {
            return .{
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = adv,
                .pixels = try allocator.alloc(u8, 0),
            };
        }
        const w: u16 = std.math.cast(u16, w_i) orelse return error.InvalidFont;
        const h: u16 = std.math.cast(u16, h_i) orelse return error.InvalidFont;
        const pixels = try allocator.alloc(u8, @as(usize, w) * @as(usize, h));
        errdefer allocator.free(pixels);
        c.zt_stb_make_glyph(self.storage(), glyph_id, size_px, pixels.ptr, w, h);
        return .{
            .width = w,
            .height = h,
            .bearing_x = clampI16(x0),
            .bearing_y = clampI16(-y0),
            .advance = adv,
            .pixels = pixels,
        };
    }
};

fn collectionOffset(bytes: []const u8, index: u32) ?usize {
    if (bytes.len < 12) return null;
    var offset: usize = 0;
    if (std.mem.eql(u8, bytes[0..4], "ttcf")) {
        const version = std.mem.readInt(u32, bytes[4..8], .big);
        if (version != 0x00010000 and version != 0x00020000) return null;
        const count = std.mem.readInt(u32, bytes[8..12], .big);
        if (index >= count or count > (bytes.len - 12) / 4) return null;
        const at = 12 + @as(usize, index) * 4;
        offset = std.mem.readInt(u32, bytes[at..][0..4], .big);
        if (offset > bytes.len - 12) return null;
    } else if (index != 0) return null;
    // Retain stb's sfnt signature gate before calling its unbounded table scan.
    switch (std.mem.readInt(u32, bytes[offset..][0..4], .big)) {
        0x00010000, 0x31000000, 0x74797031, 0x4f54544f, 0x74727565 => {},
        else => return null,
    }
    const tables = std.mem.readInt(u16, bytes[offset + 4 ..][0..2], .big);
    if (tables > (bytes.len - offset - 12) / 16) return null;
    for (0..tables) |table| {
        const entry = offset + 12 + table * 16;
        const start = std.mem.readInt(u32, bytes[entry + 8 ..][0..4], .big);
        const len = std.mem.readInt(u32, bytes[entry + 12 ..][0..4], .big);
        if (start > bytes.len or len > bytes.len - start) return null;
    }
    return offset;
}

fn clampI16(v: i32) i16 {
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return @intCast(v);
}

test "open rejects junk" {
    try std.testing.expectError(error.InvalidFont, Font.open(&.{}));
    try std.testing.expectError(error.InvalidFont, Font.open("not a font"));
    try std.testing.expectError(error.InvalidFont, Font.open("this is not an sfnt font header"));
    try std.testing.expectError(error.InvalidFont, Font.open(&(@as([12]u8, @splat(0xff)))));
    var empty_dir: [12]u8 = undefined;
    std.mem.writeInt(u32, empty_dir[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, empty_dir[4..6], 0, .big);
    std.mem.writeInt(u16, empty_dir[6..8], 0, .big);
    std.mem.writeInt(u16, empty_dir[8..10], 0, .big);
    std.mem.writeInt(u16, empty_dir[10..12], 0, .big);
    try std.testing.expectError(error.InvalidFont, Font.open(&empty_dir));
    std.mem.writeInt(u16, empty_dir[4..6], 1, .big);
    try std.testing.expectError(error.InvalidFont, Font.open(&empty_dir));
}

/// Tiny bitmap-only sfnts, with distinct metrics and absolute table offsets,
/// let the collection tests run without an installed font or fontconfig.
pub const testing = if (@import("builtin").is_test) struct {
    pub const collection = blk: {
        var data: [528]u8 = @splat(0);
        @memcpy(data[0..4], "ttcf");
        std.mem.writeInt(u32, data[4..8], 0x00010000, .big);
        std.mem.writeInt(u32, data[8..12], 2, .big);
        const tags = [_]*const [4]u8{ "CBLC", "CBDT", "cmap", "head", "hhea", "hmtx", "maxp" };
        const lengths = [_]usize{ 56, 4, 4, 20, 36, 4, 6 };
        var at: usize = 268;
        for (0..2) |member| {
            const dir = 20 + member * 124;
            std.mem.writeInt(u32, data[12 + member * 4 ..][0..4], dir, .big);
            std.mem.writeInt(u32, data[dir..][0..4], 0x00010000, .big);
            std.mem.writeInt(u16, data[dir + 4 ..][0..2], 7, .big);
            for (tags, lengths, 0..) |tag, len, table| {
                const entry = dir + 12 + table * 16;
                @memcpy(data[entry..][0..4], tag);
                std.mem.writeInt(u32, data[entry + 8 ..][0..4], at, .big);
                std.mem.writeInt(u32, data[entry + 12 ..][0..4], len, .big);
                switch (table) {
                    0 => {
                        std.mem.writeInt(u32, data[at + 4 ..][0..4], 1, .big); // strike count
                        std.mem.writeInt(u32, data[at + 16 ..][0..4], 1, .big); // subtable count
                        data[at + 52] = 16; // strike ppem
                    },
                    3 => std.mem.writeInt(u16, data[at + 18 ..][0..2], @intCast(1000 * (member + 1)), .big),
                    4 => {
                        std.mem.writeInt(i16, data[at + 4 ..][0..2], @intCast(800 * (member + 1)), .big);
                        std.mem.writeInt(i16, data[at + 6 ..][0..2], -200, .big);
                        std.mem.writeInt(u16, data[at + 34 ..][0..2], 1, .big);
                    },
                    6 => std.mem.writeInt(u16, data[at + 4 ..][0..2], 1, .big),
                    else => {},
                }
                at += len;
            }
        }
        break :blk data;
    };
} else struct {};

test "collection selects the requested sfnt and bitmap tables" {
    const a = try Font.openIndex(&testing.collection, 0);
    const b = try Font.openIndex(&testing.collection, 1);
    try std.testing.expectEqual(@as(u32, 0), a.index);
    try std.testing.expectEqual(@as(u32, 1), b.index);
    try std.testing.expectEqual(@as(u16, 1000), (try a.metrics(16)).units_per_em);
    try std.testing.expectEqual(@as(u16, 2000), (try b.metrics(16)).units_per_em);
    try std.testing.expectError(error.InvalidFont, Font.openIndex(&testing.collection, 2));
    var truncated = testing.collection;
    std.mem.writeInt(u32, truncated[8..12], 200, .big);
    try std.testing.expectError(error.InvalidFont, Font.openIndex(&truncated, 1));
    var outside = testing.collection;
    std.mem.writeInt(u32, outside[16..20], outside.len, .big);
    try std.testing.expectError(error.InvalidFont, Font.openIndex(&outside, 1));
    var bad_version = testing.collection;
    std.mem.writeInt(u32, bad_version[4..8], 0x00030000, .big);
    try std.testing.expectError(error.InvalidFont, Font.openIndex(&bad_version, 1));
    var bad_signature = testing.collection;
    @memcpy(bad_signature[144..148], "junk");
    try std.testing.expectError(error.InvalidFont, Font.openIndex(&bad_signature, 1));
    var bad_directory = testing.collection;
    std.mem.writeInt(u16, bad_directory[148..150], 65535, .big);
    try std.testing.expectError(error.InvalidFont, Font.openIndex(&bad_directory, 1));
    var bad_table = testing.collection;
    std.mem.writeInt(u32, bad_table[164..168], bad_table.len, .big);
    try std.testing.expectError(error.InvalidFont, Font.openIndex(&bad_table, 1));
}

test "rasterize system font" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io, "/usr/share/fonts/liberation/LiberationMono-Regular.ttf", .{}) catch return;
    defer file.close(io);
    const n = file.length(io) catch return;
    const bytes = try gpa.alloc(u8, n);
    defer gpa.free(bytes);
    _ = file.readPositionalAll(io, bytes, 0) catch return;

    const font = try Font.open(bytes);
    const gid = (try font.glyphIndex('A')) orelse return error.GlyphNotFound;
    try std.testing.expect(gid != 0);
    try std.testing.expect((try font.advanceWidth(gid)) > 0);
    const m = try font.metrics(16);
    try std.testing.expect(m.units_per_em > 0);
    try std.testing.expect(m.ascender > 0);
    const bmp = try font.rasterize(gpa, gid, 16);
    defer gpa.free(bmp.pixels);
    try std.testing.expect(bmp.width > 0);
    try std.testing.expect(bmp.height > 0);
    var filled: usize = 0;
    for (bmp.pixels) |p| {
        if (p != 0) filled += 1;
    }
    try std.testing.expect(filled > 10);
}
