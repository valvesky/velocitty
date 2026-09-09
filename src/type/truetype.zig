//! TrueType / sfnt parser and glyph rasterizer (stb_truetype).

const std = @import("std");
const assert = std.debug.assert;

const c = struct {
    extern fn zt_stb_init(storage: *anyopaque, data: [*]const u8, len: c_int) callconv(.c) c_int;
    extern fn zt_stb_vmetrics(storage: *const anyopaque, ascent: *c_int, descent: *c_int, line_gap: *c_int, upem: *c_int) callconv(.c) void;
    extern fn zt_stb_num_glyphs(storage: *const anyopaque) callconv(.c) c_int;
    extern fn zt_stb_find_glyph(storage: *const anyopaque, codepoint: c_int) callconv(.c) c_int;
    extern fn zt_stb_advance(storage: *const anyopaque, glyph: c_int) callconv(.c) c_int;
    extern fn zt_stb_glyph_box(storage: *const anyopaque, glyph: c_int, size_px: f32, x0: *c_int, y0: *c_int, x1: *c_int, y1: *c_int) callconv(.c) void;
    extern fn zt_stb_make_glyph(storage: *const anyopaque, glyph: c_int, size_px: f32, out: [*]u8, w: c_int, h: c_int) callconv(.c) void;
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
};

pub const Metrics = struct {
    ascender: f32,
    descender: f32,
    line_gap: f32,
    units_per_em: u16,
};

pub const Font = struct {
    bytes: []const u8,
    info: [info_cap]u8 align(8) = undefined,

    pub fn open(bytes: []const u8) Error!Font {
        if (bytes.len < 12) return error.InvalidFont;
        var font: Font = .{ .bytes = bytes };
        if (c.zt_stb_init(&font.info, bytes.ptr, @intCast(bytes.len)) == 0) {
            return error.InvalidFont;
        }
        return font;
    }

    fn storage(self: *const Font) *const anyopaque {
        return &self.info;
    }

    pub fn metrics(self: Font, size_px: f32) Error!Metrics {
        assert(size_px > 0);
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

    pub fn advanceWidth(self: Font, glyph_id: u16) Error!u16 {
        const n = c.zt_stb_num_glyphs(self.storage());
        if (glyph_id >= n) return error.GlyphNotFound;
        const adv = c.zt_stb_advance(self.storage(), glyph_id);
        if (adv < 0) return 0;
        return std.math.cast(u16, adv) orelse std.math.maxInt(u16);
    }

    pub fn glyphIndex(self: Font, codepoint: u21) Error!?u16 {
        const g = c.zt_stb_find_glyph(self.storage(), @intCast(codepoint));
        if (g <= 0) return null;
        return std.math.cast(u16, g) orelse return error.InvalidFont;
    }

    pub fn rasterize(self: Font, allocator: std.mem.Allocator, glyph_id: u16, size_px: f32) Error!Bitmap {
        assert(size_px > 0);
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

fn clampI16(v: i32) i16 {
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return @intCast(v);
}

test "open rejects junk" {
    try std.testing.expectError(error.InvalidFont, Font.open(&.{}));
    try std.testing.expectError(error.InvalidFont, Font.open("not a font"));
    var empty_dir: [12]u8 = undefined;
    std.mem.writeInt(u32, empty_dir[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, empty_dir[4..6], 0, .big);
    std.mem.writeInt(u16, empty_dir[6..8], 0, .big);
    std.mem.writeInt(u16, empty_dir[8..10], 0, .big);
    std.mem.writeInt(u16, empty_dir[10..12], 0, .big);
    try std.testing.expectError(error.InvalidFont, Font.open(&empty_dir));
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
