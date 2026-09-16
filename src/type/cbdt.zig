//! CBDT/CBLC color bitmaps (Noto Color Emoji) + cmap / hhea for glyf-less fonts.

const std = @import("std");

const c = struct {
    extern fn zt_stbi_load_rgba(data: [*]const u8, len: c_int, w: *c_int, h: *c_int, out: *?[*]u8) callconv(.c) c_int;
    extern fn zt_stbi_free(p: [*]u8) callconv(.c) void;
};

pub const Error = error{
    InvalidFont,
    GlyphNotFound,
} || std.mem.Allocator.Error;

pub const Bitmap = struct {
    width: u16,
    height: u16,
    bearing_x: i16,
    bearing_y: i16,
    advance: u16,
    pixels: []u8,
    color: bool = true,
};

pub const ColorFont = struct {
    bytes: []const u8,
    cmap: []const u8,
    cblc: []const u8,
    cbdt: []const u8,
    hmtx: []const u8,
    units_per_em: u16,
    ascender: i16,
    descender: i16,
    line_gap: i16,
    num_h_metrics: u16,
    num_glyphs: u16,
    ppem: u8,
    strike_start: u16,
    strike_end: u16,
    index_array_off: u32,
    index_subtables: u32,

    pub fn parse(bytes: []const u8) ?ColorFont {
        const cblc = findTable(bytes, "CBLC") orelse return null;
        const cbdt = findTable(bytes, "CBDT") orelse return null;
        const cmap = findTable(bytes, "cmap") orelse return null;
        const head = findTable(bytes, "head") orelse return null;
        const hhea = findTable(bytes, "hhea") orelse return null;
        const hmtx = findTable(bytes, "hmtx") orelse return null;
        const maxp = findTable(bytes, "maxp") orelse return null;
        if (head.len < 20 or hhea.len < 36 or maxp.len < 6 or cblc.len < 56) return null;

        const units_per_em = readU16(head, 18) orelse return null;
        if (units_per_em == 0) return null;
        const ascender = readI16(hhea, 4) orelse return null;
        const descender = readI16(hhea, 6) orelse return null;
        const line_gap = readI16(hhea, 8) orelse return null;
        const num_h_metrics = readU16(hhea, 34) orelse return null;
        const num_glyphs = readU16(maxp, 4) orelse return null;

        const nsizes = readU32(cblc, 4) orelse return null;
        if (nsizes == 0) return null;
        // Largest ppem strike (last record is fine; Noto has one).
        var best_i: u32 = 0;
        var best_ppem: u8 = 0;
        var i: u32 = 0;
        while (i < nsizes) : (i += 1) {
            const rec = 8 + i * 48;
            if (rec + 48 > cblc.len) break;
            const ppem = cblc[rec + 44];
            if (ppem >= best_ppem) {
                best_ppem = ppem;
                best_i = i;
            }
        }
        const rec = 8 + best_i * 48;
        const index_array_off = readU32(cblc, rec) orelse return null;
        const nsub = readU32(cblc, rec + 8) orelse return null;
        const start_g = readU16(cblc, rec + 40) orelse return null;
        const end_g = readU16(cblc, rec + 42) orelse return null;
        if (best_ppem == 0 or nsub == 0) return null;

        return .{
            .bytes = bytes,
            .cmap = cmap,
            .cblc = cblc,
            .cbdt = cbdt,
            .hmtx = hmtx,
            .units_per_em = units_per_em,
            .ascender = ascender,
            .descender = descender,
            .line_gap = line_gap,
            .num_h_metrics = num_h_metrics,
            .num_glyphs = num_glyphs,
            .ppem = best_ppem,
            .strike_start = start_g,
            .strike_end = end_g,
            .index_array_off = index_array_off,
            .index_subtables = nsub,
        };
    }

    pub fn glyphIndex(self: ColorFont, codepoint: u21) ?u16 {
        return cmapLookup(self.cmap, codepoint);
    }

    pub fn hasBitmap(self: ColorFont, gid: u16) bool {
        return self.bitmapSpan(gid) != null;
    }

    pub fn advanceWidth(self: ColorFont, gid: u16) u16 {
        if (self.num_h_metrics == 0) return 0;
        const n = @min(gid, self.num_h_metrics - 1);
        const off: usize = @as(usize, n) * 4;
        return readU16(self.hmtx, off) orelse 0;
    }

    pub fn rasterize(self: ColorFont, allocator: std.mem.Allocator, gid: u16, size_px: f32) Error!?Bitmap {
        const span = self.bitmapSpan(gid) orelse return null;
        if (span.len < 9) return null;
        // Format 17: SmallGlyphMetrics (5) + ULONG dataLen + PNG.
        const height = span[0];
        const width = span[1];
        const bearing_x: i8 = @bitCast(span[2]);
        const bearing_y: i8 = @bitCast(span[3]);
        const advance = span[4];
        const data_len = readU32(span, 5) orelse return null;
        if (9 + data_len > span.len) return null;
        const png = span[9 .. 9 + data_len];
        if (png.len < 8 or !std.mem.eql(u8, png[0..4], "\x89PNG")) return null;

        var w: c_int = 0;
        var h: c_int = 0;
        var ptr: ?[*]u8 = null;
        if (c.zt_stbi_load_rgba(png.ptr, @intCast(png.len), &w, &h, &ptr) == 0) return null;
        const src = ptr orelse return null;
        defer c.zt_stbi_free(src);
        if (w <= 0 or h <= 0) return null;
        const sw: u32 = @intCast(w);
        const sh: u32 = @intCast(h);
        const src_n = @as(usize, sw) * @as(usize, sh) * 4;
        const src_rgba = src[0..src_n];

        const ppem: f32 = @floatFromInt(if (self.ppem == 0) 109 else self.ppem);
        const scale = size_px / ppem;
        var dw: u32 = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(sw)) * scale)));
        var dh: u32 = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(sh)) * scale)));
        dw = @min(dw, 512);
        dh = @min(dh, 512);

        const pixels = try allocator.alloc(u8, @as(usize, dw) * @as(usize, dh) * 4);
        errdefer allocator.free(pixels);
        downsampleRgba(src_rgba, sw, sh, pixels, dw, dh);

        const bx: i16 = @intFromFloat(@round(@as(f32, @floatFromInt(bearing_x)) * scale));
        const by: i16 = @intFromFloat(@round(@as(f32, @floatFromInt(bearing_y)) * scale));
        const adv_src: f32 = if (advance != 0)
            @floatFromInt(advance)
        else if (width != 0)
            @floatFromInt(width)
        else
            @floatFromInt(sw);
        const adv: u16 = @intFromFloat(@max(1, @min(65535, @round(adv_src * scale))));
        _ = height;
        return .{
            .width = @intCast(dw),
            .height = @intCast(dh),
            .bearing_x = bx,
            .bearing_y = by,
            .advance = adv,
            .pixels = pixels,
            .color = true,
        };
    }

    fn bitmapSpan(self: ColorFont, gid: u16) ?[]const u8 {
        if (gid < self.strike_start or gid > self.strike_end) return null;
        const cblc = self.cblc;
        const base = self.index_array_off;
        var j: u32 = 0;
        while (j < self.index_subtables) : (j += 1) {
            const arr = base + j * 8;
            if (arr + 8 > cblc.len) return null;
            const first = readU16(cblc, arr) orelse return null;
            const last = readU16(cblc, arr + 2) orelse return null;
            const add = readU32(cblc, arr + 4) orelse return null;
            if (gid < first or gid > last) continue;
            const st = base + add;
            if (st + 8 > cblc.len) return null;
            const index_format = readU16(cblc, st) orelse return null;
            const image_format = readU16(cblc, st + 2) orelse return null;
            const image_off = readU32(cblc, st + 4) orelse return null;
            if (index_format != 1 or image_format != 17) return null;
            const k: u32 = gid - first;
            const o1_at = st + 8 + k * 4;
            const o2_at = o1_at + 4;
            if (o2_at + 4 > cblc.len) return null;
            const o1 = readU32(cblc, o1_at) orelse return null;
            const o2 = readU32(cblc, o2_at) orelse return null;
            if (o2 <= o1) return null;
            const start = image_off + o1;
            const end = image_off + o2;
            if (end > self.cbdt.len or start >= end) return null;
            return self.cbdt[start..end];
        }
        return null;
    }
};

fn downsampleRgba(src: []const u8, sw: u32, sh: u32, dst: []u8, dw: u32, dh: u32) void {
    if (dw == sw and dh == sh) {
        @memcpy(dst, src);
        return;
    }
    var y: u32 = 0;
    while (y < dh) : (y += 1) {
        const y0 = y * sh / dh;
        const y1 = @max(y0 + 1, (y + 1) * sh / dh);
        var x: u32 = 0;
        while (x < dw) : (x += 1) {
            const x0 = x * sw / dw;
            const x1 = @max(x0 + 1, (x + 1) * sw / dw);
            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            var a: u32 = 0;
            var n: u32 = 0;
            var sy = y0;
            while (sy < y1) : (sy += 1) {
                var sx = x0;
                while (sx < x1) : (sx += 1) {
                    const i = (@as(usize, sy) * sw + sx) * 4;
                    r += src[i];
                    g += src[i + 1];
                    b += src[i + 2];
                    a += src[i + 3];
                    n += 1;
                }
            }
            const o = (@as(usize, y) * dw + x) * 4;
            if (n == 0) {
                dst[o] = 0;
                dst[o + 1] = 0;
                dst[o + 2] = 0;
                dst[o + 3] = 0;
            } else {
                dst[o] = @intCast(r / n);
                dst[o + 1] = @intCast(g / n);
                dst[o + 2] = @intCast(b / n);
                dst[o + 3] = @intCast(a / n);
            }
        }
    }
}

pub fn findTable(bytes: []const u8, tag: *const [4]u8) ?[]const u8 {
    if (bytes.len < 12) return null;
    const n = readU16(bytes, 4) orelse return null;
    var i: u16 = 0;
    var off: usize = 12;
    while (i < n) : (i += 1) {
        if (off + 16 > bytes.len) return null;
        if (std.mem.eql(u8, bytes[off..][0..4], tag)) {
            const to = readU32(bytes, off + 8) orelse return null;
            const tl = readU32(bytes, off + 12) orelse return null;
            if (to > bytes.len or tl > bytes.len - to) return null;
            return bytes[to .. to + tl];
        }
        off += 16;
    }
    return null;
}

fn cmapLookup(cmap: []const u8, cp: u21) ?u16 {
    if (cmap.len < 4) return null;
    const nsub = readU16(cmap, 2) orelse return null;
    var i: u16 = 0;
    var best: ?u16 = null;
    while (i < nsub) : (i += 1) {
        const rec = 4 + @as(usize, i) * 8;
        if (rec + 8 > cmap.len) break;
        const plat = readU16(cmap, rec) orelse break;
        const enc = readU16(cmap, rec + 2) orelse break;
        const off = readU32(cmap, rec + 4) orelse break;
        if (off >= cmap.len) continue;
        const fmt = readU16(cmap, off) orelse continue;
        const gid = switch (fmt) {
            4 => cmapFmt4(cmap[off..], cp),
            12 => cmapFmt12(cmap[off..], cp),
            else => null,
        };
        if (gid) |g| {
            if (g == 0) continue;
            // Prefer Unicode full repertoire (platform 0 or Win UCS-4).
            if ((plat == 0 and enc >= 4) or (plat == 3 and enc == 10)) return g;
            best = g;
        }
    }
    return best;
}

fn cmapFmt4(t: []const u8, cp: u21) ?u16 {
    if (cp > 0xFFFF or t.len < 16) return null;
    const seg_count_x2 = readU16(t, 6) orelse return null;
    if (seg_count_x2 < 2 or seg_count_x2 % 2 != 0) return null;
    const seg_count: usize = seg_count_x2 / 2;
    const end_at: usize = 14;
    const start_at = end_at + seg_count_x2 + 2;
    const delta_at = start_at + seg_count_x2;
    const range_at = delta_at + seg_count_x2;
    if (range_at + seg_count_x2 > t.len) return null;
    const c16: u16 = @intCast(cp);
    var s: usize = 0;
    while (s < seg_count) : (s += 1) {
        const end = readU16(t, end_at + s * 2) orelse return null;
        if (c16 > end) continue;
        const start = readU16(t, start_at + s * 2) orelse return null;
        if (c16 < start) return null;
        const delta = readI16(t, delta_at + s * 2) orelse return null;
        const range = readU16(t, range_at + s * 2) orelse return null;
        if (range == 0) {
            return c16 +% @as(u16, @bitCast(delta));
        }
        const ro = range_at + s * 2 + range + (c16 - start) * 2;
        const g = readU16(t, ro) orelse return null;
        if (g == 0) return null;
        return g +% @as(u16, @bitCast(delta));
    }
    return null;
}

fn cmapFmt12(t: []const u8, cp: u21) ?u16 {
    if (t.len < 16) return null;
    const ngroups = readU32(t, 12) orelse return null;
    if (16 + ngroups * 12 > t.len) return null;
    var lo: u32 = 0;
    var hi = ngroups;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const rec = 16 + mid * 12;
        const start = readU32(t, rec) orelse return null;
        const end = readU32(t, rec + 4) orelse return null;
        if (cp < start) {
            hi = mid;
        } else if (cp > end) {
            lo = mid + 1;
        } else {
            const start_gid = readU32(t, rec + 8) orelse return null;
            const gid = start_gid + (cp - start);
            if (gid > 0xFFFF) return null;
            return @intCast(gid);
        }
    }
    return null;
}

fn readU16(s: []const u8, off: usize) ?u16 {
    if (off + 2 > s.len) return null;
    return std.mem.readInt(u16, s[off..][0..2], .big);
}

fn readI16(s: []const u8, off: usize) ?i16 {
    return @bitCast(readU16(s, off) orelse return null);
}

fn readU32(s: []const u8, off: usize) ?u32 {
    if (off + 4 > s.len) return null;
    return std.mem.readInt(u32, s[off..][0..4], .big);
}

test "noto color emoji grin" {
    const gpa = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io, "/usr/share/fonts/noto/NotoColorEmoji.ttf", .{}) catch return;
    defer file.close(io);
    const n = file.length(io) catch return;
    const bytes = try gpa.alloc(u8, n);
    defer gpa.free(bytes);
    _ = file.readPositionalAll(io, bytes, 0) catch return;

    const font = ColorFont.parse(bytes) orelse return error.InvalidFont;
    const gid = font.glyphIndex(0x1F600) orelse return error.GlyphNotFound;
    try std.testing.expect(font.hasBitmap(gid));
    const bmp = (try font.rasterize(gpa, gid, 16)) orelse return error.GlyphNotFound;
    defer gpa.free(bmp.pixels);
    try std.testing.expect(bmp.color);
    try std.testing.expect(bmp.width > 4);
    try std.testing.expect(bmp.height > 4);
    var color: usize = 0;
    var i: usize = 0;
    while (i + 3 < bmp.pixels.len) : (i += 4) {
        if (bmp.pixels[i + 3] < 32) continue;
        if (bmp.pixels[i] != bmp.pixels[i + 1] or bmp.pixels[i] != bmp.pixels[i + 2]) color += 1;
    }
    try std.testing.expect(color > 8);
}
