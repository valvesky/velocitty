//! Apple sbix color glyphs. PNG strikes are decoded lazily, after a glyph miss.
const std = @import("std");
const Cbdt = @import("cbdt.zig");

const c = struct {
    extern fn zt_image_load_rgba(data: [*]const u8, len: c_int, w: *c_int, h: *c_int, out: *?[*]u8) callconv(.c) c_int;
    extern fn zt_image_free(p: [*]u8) callconv(.c) void;
};

pub const Error = Cbdt.Error;
pub const Bitmap = Cbdt.Bitmap;
const max_strikes = 256;
const max_duplicates = 32;
const max_image_bytes = 32 * 1024 * 1024;

pub const ColorFont = struct {
    sbix: []const u8,
    cmap: []const u8,
    hmtx: []const u8,
    units_per_em: u16,
    ascender: i16,
    descender: i16,
    line_gap: i16,
    num_h_metrics: u16,
    num_glyphs: u16,
    num_strikes: u16,

    pub fn parseAt(bytes: []const u8, offset: usize) ?ColorFont {
        const sbix = Cbdt.findTableAt(bytes, offset, "sbix") orelse return null;
        const cmap = Cbdt.findTableAt(bytes, offset, "cmap") orelse return null;
        const head = Cbdt.findTableAt(bytes, offset, "head") orelse return null;
        const hhea = Cbdt.findTableAt(bytes, offset, "hhea") orelse return null;
        const hmtx = Cbdt.findTableAt(bytes, offset, "hmtx") orelse return null;
        const maxp = Cbdt.findTableAt(bytes, offset, "maxp") orelse return null;
        if (sbix.len < 8 or head.len < 20 or hhea.len < 36 or maxp.len < 6) return null;
        if (read(u16, sbix, 0).? != 1) return null;
        const flags = read(u16, sbix, 2).?;
        if (flags & 1 == 0 or flags & ~@as(u16, 3) != 0) return null;
        const count = read(u32, sbix, 4).?;
        if (count == 0 or count > max_strikes or count > (sbix.len - 8) / 4) return null;
        const upem = read(u16, head, 18).?;
        const nglyphs = read(u16, maxp, 4).?;
        const nmetrics = read(u16, hhea, 34).?;
        if (upem == 0 or nglyphs == 0 or nmetrics == 0 or nmetrics > nglyphs or
            @as(usize, nmetrics) * 4 + @as(usize, nglyphs - nmetrics) * 2 > hmtx.len) return null;
        const font: ColorFont = .{
            .sbix = sbix,
            .cmap = cmap,
            .hmtx = hmtx,
            .units_per_em = upem,
            .ascender = read(i16, hhea, 4).?,
            .descender = read(i16, hhea, 6).?,
            .line_gap = read(i16, hhea, 8).?,
            .num_h_metrics = nmetrics,
            .num_glyphs = nglyphs,
            .num_strikes = @intCast(count),
        };
        for (0..count) |i| _ = font.strike(i) orelse return null;
        return font;
    }

    pub fn glyphIndex(self: ColorFont, cp: u21) ?u16 {
        const gid = Cbdt.cmapLookup(self.cmap, cp) orelse return null;
        return if (gid < self.num_glyphs) gid else null;
    }

    pub fn hasBitmap(self: ColorFont, gid: u16) bool {
        for (0..self.num_strikes) |i| {
            if (self.image(self.strike(i) orelse continue, gid) != null) return true;
        }
        return false;
    }

    pub fn advanceWidth(self: ColorFont, gid: u16) u16 {
        return read(u16, self.hmtx, @as(usize, @min(gid, self.num_h_metrics - 1)) * 4) orelse 0;
    }

    pub fn rasterize(self: ColorFont, allocator: std.mem.Allocator, gid: u16, size_px: f32) Error!?Bitmap {
        if (!std.math.isFinite(size_px) or size_px <= 0) return error.InvalidFont;
        // Prefer the smallest available strike at least as large as the target;
        // otherwise use the largest smaller strike. Coverage may vary by strike.
        var selected: ?Image = null;
        for (0..self.num_strikes) |i| {
            const candidate = self.image(self.strike(i) orelse continue, gid) orelse continue;
            if (selected == null or betterStrike(candidate.ppem, selected.?.ppem, size_px)) selected = candidate;
        }
        const image_data = selected orelse return null;
        var w: c_int = 0;
        var h: c_int = 0;
        var ptr: ?[*]u8 = null;
        if (c.zt_image_load_rgba(image_data.png.ptr, @intCast(image_data.png.len), &w, &h, &ptr) == 0) return null;
        const src = ptr orelse return null;
        defer c.zt_image_free(src);
        if (w <= 0 or h <= 0 or w > 4096 or h > 4096) return null;
        const sw: u32 = @intCast(w);
        const sh: u32 = @intCast(h);
        const scale = size_px / @as(f32, @floatFromInt(image_data.ppem));
        const dw: u32 = @intFromFloat(@min(512, @max(1, @round(@as(f32, @floatFromInt(sw)) * scale))));
        const dh: u32 = @intFromFloat(@min(512, @max(1, @round(@as(f32, @floatFromInt(sh)) * scale))));
        const pixels = try allocator.alloc(u8, @as(usize, dw) * dh * 4);
        Cbdt.downsampleRgba(src[0 .. @as(usize, sw) * sh * 4], sw, sh, pixels, dw, dh);
        return .{
            .width = @intCast(dw),
            .height = @intCast(dh),
            .bearing_x = signedPixel(@as(f32, @floatFromInt(image_data.x)) * scale),
            .bearing_y = signedPixel((@as(f32, @floatFromInt(image_data.y)) + @as(f32, @floatFromInt(sh))) * scale),
            .advance = @intFromFloat(@min(65535, @max(0, @round(@as(f32, @floatFromInt(self.advanceWidth(gid))) * size_px / @as(f32, @floatFromInt(self.units_per_em)))))),
            .pixels = pixels,
        };
    }

    fn strike(self: ColorFont, index: usize) ?[]const u8 {
        if (index >= self.num_strikes) return null;
        const start: usize = read(u32, self.sbix, 8 + index * 4) orelse return null;
        // Offset records need not be ordered by their physical table position.
        var end = self.sbix.len;
        for (0..self.num_strikes) |i| {
            if (i == index) continue;
            const other: usize = read(u32, self.sbix, 8 + i * 4) orelse return null;
            if (other == start) return null;
            if (other > start) end = @min(end, other);
        }
        const header_len = 4 + (@as(usize, self.num_glyphs) + 1) * 4;
        if (start < 8 + @as(usize, self.num_strikes) * 4 or start > end or end > self.sbix.len or end - start < header_len) return null;
        const result = self.sbix[start..end];
        if (read(u16, result, 0).? == 0) return null;
        return result;
    }

    const Image = struct { png: []const u8, x: i16, y: i16, ppem: u16 };

    fn image(self: ColorFont, data: []const u8, gid: u16) ?Image {
        var current = gid;
        var origin: ?[2]i16 = null;
        for (0..max_duplicates) |_| {
            if (current >= self.num_glyphs) return null;
            const start: usize = read(u32, data, 4 + @as(usize, current) * 4) orelse return null;
            const end: usize = read(u32, data, 8 + @as(usize, current) * 4) orelse return null;
            if (start < 4 + (@as(usize, self.num_glyphs) + 1) * 4 or start > end or end > data.len or end - start < 8) return null;
            const record = data[start..end];
            if (origin == null) origin = .{ read(i16, record, 0).?, read(i16, record, 2).? };
            if (std.mem.eql(u8, record[4..8], "dupe")) {
                if (record.len != 10) return null;
                current = read(u16, record, 8).?;
                continue;
            }
            if (!std.mem.eql(u8, record[4..8], "png ")) return null;
            const png = record[8..];
            if (png.len < 24 or png.len > max_image_bytes or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n") or
                !std.mem.eql(u8, png[12..16], "IHDR")) return null;
            const width = read(u32, png, 16).?;
            const height = read(u32, png, 20).?;
            if (width == 0 or height == 0 or width > 4096 or height > 4096) return null;
            return .{ .png = png, .x = origin.?[0], .y = origin.?[1], .ppem = read(u16, data, 0).? };
        }
        return null; // cyclic or excessive duplicate chains
    }
};

fn betterStrike(candidate: u16, current: u16, size: f32) bool {
    const candidate_large = @as(f32, @floatFromInt(candidate)) >= size;
    const current_large = @as(f32, @floatFromInt(current)) >= size;
    if (candidate_large != current_large) return candidate_large;
    return if (candidate_large) candidate < current else candidate > current;
}

fn signedPixel(value: f32) i16 {
    return @intFromFloat(@max(-32768, @min(32767, @round(value))));
}

fn read(comptime T: type, bytes: []const u8, at: usize) ?T {
    if (at > bytes.len or bytes.len - at < @sizeOf(T)) return null;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .big);
}

/// A complete bitmap-only sfnt with two colored PNG strikes, a duplicate with
/// its own origin/advance, and a glyph covered only by the larger strike.
pub const testing = if (@import("builtin").is_test) struct {
    const red = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00, 0x11, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x38, 0x21, 0xc2, 0xd5, 0x00, 0xc2, 0x0c, 0x30, 0x06, 0x00, 0x34, 0x2e, 0x05, 0x99, 0x8f, 0xc1, 0x19, 0xf5, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    const green = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00, 0x10, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0x38, 0x61, 0xf3, 0x1f, 0x8c, 0x61, 0x0c, 0x00, 0x43, 0x9c, 0x08, 0x0d, 0x89, 0x31, 0x54, 0xfd, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    pub const sbix_at = 108;
    const small_len = 24 + 8 + red.len + 10;
    const large_len = 24 + 8 + green.len + 10 + 8 + green.len;
    const sbix_len = 16 + small_len + large_len;
    const cmap_at = std.mem.alignForward(usize, sbix_at + sbix_len, 4);
    const head_at = cmap_at + 40;
    const hhea_at = head_at + 20;
    const hmtx_at = hhea_at + 36;
    const maxp_at = hmtx_at + 16;
    pub const used = maxp_at + 6;

    pub fn font() [used]u8 {
        var data: [used]u8 = @splat(0);
        write(u32, &data, 0, 0x00010000);
        write(u16, &data, 4, 6);
        const tags = [_]*const [4]u8{ "sbix", "cmap", "head", "hhea", "hmtx", "maxp" };
        const starts = [_]usize{ sbix_at, cmap_at, head_at, hhea_at, hmtx_at, maxp_at };
        const lengths = [_]usize{ sbix_len, 40, 20, 36, 16, 6 };
        for (tags, starts, lengths, 0..) |tag, start, len, i| {
            @memcpy(data[12 + i * 16 ..][0..4], tag);
            write(u32, &data, 20 + i * 16, @intCast(start));
            write(u32, &data, 24 + i * 16, @intCast(len));
        }
        write(u16, &data, sbix_at, 1);
        write(u16, &data, sbix_at + 2, 1);
        write(u32, &data, sbix_at + 4, 2);
        write(u32, &data, sbix_at + 8, 16);
        write(u32, &data, sbix_at + 12, 16 + small_len);
        makeStrike(data[sbix_at + 16 ..][0..small_len], 16, &red, false);
        makeStrike(data[sbix_at + 16 + small_len ..][0..large_len], 32, &green, true);
        // Windows full-Unicode cmap, with one contiguous format-12 group.
        write(u16, &data, cmap_at + 2, 1);
        write(u16, &data, cmap_at + 4, 3);
        write(u16, &data, cmap_at + 6, 10);
        write(u32, &data, cmap_at + 8, 12);
        write(u16, &data, cmap_at + 12, 12);
        write(u32, &data, cmap_at + 16, 28);
        write(u32, &data, cmap_at + 24, 1);
        write(u32, &data, cmap_at + 28, 0x1f600);
        write(u32, &data, cmap_at + 32, 0x1f602);
        write(u32, &data, cmap_at + 36, 1);
        write(u16, &data, head_at + 18, 1000);
        write(i16, &data, hhea_at + 4, 800);
        write(i16, &data, hhea_at + 6, -200);
        write(u16, &data, hhea_at + 34, 4);
        for (0..4) |gid| write(u16, &data, hmtx_at + gid * 4, @intCast(500 + gid * 100));
        write(u16, &data, maxp_at + 4, 4);
        return data;
    }

    fn makeStrike(dst: []u8, ppem: u16, png: []const u8, last_glyph: bool) void {
        write(u16, dst, 0, ppem);
        write(u16, dst, 2, 72);
        const duplicate_at = 24 + 8 + png.len;
        const last_at = duplicate_at + 10;
        const offsets = [_]usize{ 24, 24, duplicate_at, last_at, dst.len };
        for (offsets, 0..) |off, i| write(u32, dst, 4 + i * 4, @intCast(off));
        write(i16, dst, 24, -2);
        write(i16, dst, 26, -1);
        @memcpy(dst[28..32], "png ");
        @memcpy(dst[32..][0..png.len], png);
        write(i16, dst, duplicate_at, 3);
        write(i16, dst, duplicate_at + 2, 4);
        @memcpy(dst[duplicate_at + 4 ..][0..4], "dupe");
        write(u16, dst, duplicate_at + 8, 1);
        if (last_glyph) {
            @memcpy(dst[last_at + 4 ..][0..4], "png ");
            @memcpy(dst[last_at + 8 ..][0..png.len], png);
        }
    }

    pub fn write(comptime T: type, data: []u8, at: usize, value: T) void {
        std.mem.writeInt(T, data[at..][0..@sizeOf(T)], value, .big);
    }
} else struct {};

test "sbix PNG glyphs preserve color alpha metrics and duplicate origins" {
    const bytes = testing.font();
    const font = ColorFont.parseAt(&bytes, 0) orelse return error.InvalidFont;
    try std.testing.expectEqual(@as(u16, 1), font.glyphIndex(0x1f600).?);
    try std.testing.expectEqual(@as(u16, 2), font.glyphIndex(0x1f601).?);
    try std.testing.expect(font.glyphIndex('A') == null);
    try std.testing.expect(font.hasBitmap(1) and font.hasBitmap(2) and font.hasBitmap(3));
    try std.testing.expect(!font.hasBitmap(0) and !font.hasBitmap(4));
    const bmp = (try font.rasterize(std.testing.allocator, 1, 16)).?;
    defer std.testing.allocator.free(bmp.pixels);
    try std.testing.expect(bmp.color);
    try std.testing.expectEqual(@as(u16, 2), bmp.width);
    try std.testing.expectEqual(@as(u16, 2), bmp.height);
    try std.testing.expectEqual(@as(i16, -2), bmp.bearing_x);
    try std.testing.expectEqual(@as(i16, 1), bmp.bearing_y);
    try std.testing.expectEqual(@as(u16, 10), bmp.advance);
    for (0..4) |i| try std.testing.expectEqualSlices(u8, &.{ 200, 20, 10, 128 }, bmp.pixels[i * 4 ..][0..4]);
    const duplicate = (try font.rasterize(std.testing.allocator, 2, 16)).?;
    defer std.testing.allocator.free(duplicate.pixels);
    try std.testing.expectEqualSlices(u8, bmp.pixels, duplicate.pixels);
    try std.testing.expectEqual(@as(i16, 3), duplicate.bearing_x);
    try std.testing.expectEqual(@as(i16, 6), duplicate.bearing_y);
    try std.testing.expectEqual(@as(u16, 11), duplicate.advance);
}

test "sbix selects available strikes by target size regardless of offset order" {
    var bytes = testing.font();
    for ([_]bool{ false, true }) |reorder| {
        if (reorder) {
            testing.write(u32, &bytes, testing.sbix_at + 8, 16 + testing.small_len);
            testing.write(u32, &bytes, testing.sbix_at + 12, 16);
        }
        const font = ColorFont.parseAt(&bytes, 0) orelse return error.InvalidFont;
        for ([_]f32{ 20, 32, 40 }) |size| {
            const bmp = (try font.rasterize(std.testing.allocator, 1, size)).?;
            defer std.testing.allocator.free(bmp.pixels);
            try std.testing.expectEqualSlices(u8, &.{ 0, 200, 60, 255 }, bmp.pixels[0..4]);
        }
        const small = (try font.rasterize(std.testing.allocator, 1, 8)).?;
        defer std.testing.allocator.free(small.pixels);
        try std.testing.expectEqual(@as(u16, 1), small.width);
        try std.testing.expectEqualSlices(u8, &.{ 200, 20, 10, 128 }, small.pixels);
        // Glyph 3 has no 16px bitmap: still use its larger strike at 8px.
        const missing_small = (try font.rasterize(std.testing.allocator, 3, 8)).?;
        defer std.testing.allocator.free(missing_small.pixels);
        try std.testing.expectEqualSlices(u8, &.{ 0, 200, 60, 255 }, missing_small.pixels);
    }
}

test "sbix rejects truncated tables offsets duplicate cycles and oversized images" {
    const valid = testing.font();
    for (0..valid.len) |len| try std.testing.expect(ColorFont.parseAt(valid[0..len], 0) == null);
    var bytes = valid;
    testing.write(u32, &bytes, testing.sbix_at + 4, 0xffffffff);
    try std.testing.expect(ColorFont.parseAt(&bytes, 0) == null);
    bytes = valid;
    testing.write(u32, &bytes, testing.sbix_at + 8, 0xffffffff);
    try std.testing.expect(ColorFont.parseAt(&bytes, 0) == null);
    bytes = valid;
    for ([_]usize{ testing.sbix_at + 16, testing.sbix_at + 16 + testing.small_len }) |strike_at| {
        const record_at: usize = read(u32, &bytes, strike_at + 12).?;
        testing.write(u16, &bytes, strike_at + record_at + 8, 2); // self-reference
    }
    var font = ColorFont.parseAt(&bytes, 0).?;
    try std.testing.expect(!font.hasBitmap(2));
    try std.testing.expect(try font.rasterize(std.testing.allocator, 2, 16) == null);
    bytes = valid;
    for ([_]usize{ testing.sbix_at + 16, testing.sbix_at + 16 + testing.small_len }) |strike_at| {
        testing.write(u32, &bytes, strike_at + 24 + 8 + 16, 0xffffffff); // PNG IHDR width
    }
    font = ColorFont.parseAt(&bytes, 0).?;
    try std.testing.expect(!font.hasBitmap(1));
    try std.testing.expect(try font.rasterize(std.testing.allocator, 1, 16) == null);
    bytes = valid;
    testing.write(u32, &bytes, testing.cmap_at + 24, 0xffffffff);
    font = ColorFont.parseAt(&bytes, 0).?;
    try std.testing.expect(font.glyphIndex(0x1f600) == null);
}

test "sbix rasterization releases decoded pixels on allocator failure" {
    const Checks = struct {
        fn render(allocator: std.mem.Allocator) !void {
            const bytes = testing.font();
            const font = ColorFont.parseAt(&bytes, 0).?;
            const bmp = (try font.rasterize(allocator, 1, 16)).?;
            defer allocator.free(bmp.pixels);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Checks.render, .{});
}
