const std = @import("std");
const assert = std.debug.assert;

pub fn encodeRgb(allocator: std.mem.Allocator, width: u32, height: u32, pixels: []const u32) error{OutOfMemory}![]u8 {
    assert(width > 0);
    assert(height > 0);
    assert(pixels.len == @as(usize, width) * @as(usize, height));

    const row_bytes = 1 + @as(usize, width) * 3;
    const raw = try allocator.alloc(u8, row_bytes * height);
    defer allocator.free(raw);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const dst_row = raw[y * row_bytes ..][0..row_bytes];
        dst_row[0] = 0;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const px = pixels[y * width + x];
            const o = 1 + @as(usize, x) * 3;
            dst_row[o] = @intCast((px >> 16) & 0xff);
            dst_row[o + 1] = @intCast((px >> 8) & 0xff);
            dst_row[o + 2] = @intCast(px & 0xff);
        }
    }

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    try zlibStore(&idat, allocator, raw);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &[_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8;
    ihdr[9] = 2;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(&out, allocator, "IHDR", &ihdr);
    try writeChunk(&out, allocator, "IDAT", idat.items);
    try writeChunk(&out, allocator, "IEND", &.{});
    return out.toOwnedSlice(allocator);
}

pub fn writeFile(allocator: std.mem.Allocator, io: std.Io, sub_path: []const u8, width: u32, height: u32, pixels: []const u32) !void {
    const bytes = try encodeRgb(allocator, width, height, pixels);
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sub_path, .data = bytes });
}

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u32,
};

/// Decode an RGB8 PNG produced by `encodeRgb` (uncompressed store IDAT).
pub fn decodeRgb(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    const sig = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &sig)) return error.InvalidPng;
    var i: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var have_ihdr = false;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    while (i + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[i..][0..4], .big);
        const typ = bytes[i + 4 ..][0..4];
        i += 8;
        if (i + len + 4 > bytes.len) return error.InvalidPng;
        const data = bytes[i .. i + len];
        i += len + 4;
        if (std.mem.eql(u8, typ, "IHDR")) {
            if (len != 13) return error.InvalidPng;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (data[8] != 8 or data[9] != 2) return error.UnsupportedPng;
            have_ihdr = true;
        } else if (std.mem.eql(u8, typ, "IDAT")) {
            try idat.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, typ, "IEND")) {
            break;
        }
    }
    if (!have_ihdr or width == 0 or height == 0) return error.InvalidPng;
    const raw = try zlibInflateStore(allocator, idat.items);
    defer allocator.free(raw);
    const row_bytes = 1 + @as(usize, width) * 3;
    if (raw.len != row_bytes * height) return error.InvalidPng;
    const pixels = try allocator.alloc(u32, @as(usize, width) * height);
    errdefer allocator.free(pixels);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src = raw[y * row_bytes ..][0..row_bytes];
        if (src[0] != 0) return error.UnsupportedPng;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const o = 1 + @as(usize, x) * 3;
            pixels[y * width + x] = (@as(u32, 255) << 24) |
                (@as(u32, src[o]) << 16) |
                (@as(u32, src[o + 1]) << 8) |
                src[o + 2];
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

/// Black where pixels match; red=reference luma, green=got luma where they differ.
pub fn diffPixels(allocator: std.mem.Allocator, ref: []const u32, got: []const u32) error{OutOfMemory}![]u32 {
    assert(ref.len == got.len);
    const out = try allocator.alloc(u32, ref.len);
    for (ref, got, out) |r, g, *d| {
        if (r == g) {
            d.* = 0xff000000;
        } else {
            d.* = 0xff000000 | (@as(u32, luma(r)) << 16) | (@as(u32, luma(g)) << 8);
        }
    }
    return out;
}

fn luma(px: u32) u8 {
    const r = (px >> 16) & 0xff;
    const g = (px >> 8) & 0xff;
    const b = px & 0xff;
    return @intCast((r * 3 + g * 6 + b) / 10);
}

fn zlibInflateStore(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len < 6) return error.InvalidPng;
    if (data[0] != 0x78) return error.UnsupportedPng;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var off: usize = 2;
    while (off + 4 < data.len) {
        const header = data[off];
        off += 1;
        if (header != 0 and header != 1) return error.UnsupportedPng;
        if (off + 4 > data.len) return error.InvalidPng;
        const n = std.mem.readInt(u16, data[off..][0..2], .little);
        const nlen = std.mem.readInt(u16, data[off + 2 ..][0..2], .little);
        off += 4;
        if (n ^ 0xffff != nlen) return error.InvalidPng;
        if (off + n > data.len) return error.InvalidPng;
        try out.appendSlice(allocator, data[off..][0..n]);
        off += n;
        if (header == 1) break;
    }
    return out.toOwnedSlice(allocator);
}

fn writeChunk(out: *std.ArrayList(u8), allocator: std.mem.Allocator, typ: *const [4]u8, data: []const u8) error{OutOfMemory}!void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(allocator, &len);
    try out.appendSlice(allocator, typ);
    try out.appendSlice(allocator, data);
    var crc = std.hash.Crc32.init();
    crc.update(typ);
    crc.update(data);
    var crc_b: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_b, crc.final(), .big);
    try out.appendSlice(allocator, &crc_b);
}

fn zlibStore(out: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) error{OutOfMemory}!void {
    try out.append(allocator, 0x78);
    try out.append(allocator, 0x01);
    var off: usize = 0;
    while (off < data.len) {
        const n: u16 = @intCast(@min(data.len - off, 65535));
        const last = off + n == data.len;
        try out.append(allocator, if (last) 0x01 else 0x00);
        var lenb: [2]u8 = undefined;
        std.mem.writeInt(u16, &lenb, n, .little);
        try out.appendSlice(allocator, &lenb);
        var nlenb: [2]u8 = undefined;
        std.mem.writeInt(u16, &nlenb, n ^ 0xffff, .little);
        try out.appendSlice(allocator, &nlenb);
        try out.appendSlice(allocator, data[off..][0..n]);
        off += n;
    }
    const adler = std.hash.Adler32.hash(data);
    var ab: [4]u8 = undefined;
    std.mem.writeInt(u32, &ab, adler, .big);
    try out.appendSlice(allocator, &ab);
}
