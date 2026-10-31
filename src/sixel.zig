//! Sixel (DCS q) decoder → RGBA bitmap.

const std = @import("std");
const Color = @import("grid.zig").Color;

pub const max_dim: u32 = 2048;

pub const Bitmap = struct {
    width: u32,
    height: u32,
    rgba: []u8,
};

pub const Params = struct {
    /// P2=1: unset sixel bits stay transparent.
    transparent: bool = false,
    max_w: u32 = max_dim,
    max_h: u32 = max_dim,
    palette: *[256]Color,
    registers: u16 = 256,
};

pub fn decode(allocator: std.mem.Allocator, body: []const u8, params: Params) error{InvalidSixel}!Bitmap {
    return walk(true, allocator, body, params);
}

/// The size `decode` would return, without painting (the palette is left
/// untouched). `rgba` is empty.
pub fn measure(body: []const u8, params: Params) Bitmap {
    return walk(false, undefined, body, params) catch .{ .width = 1, .height = 1, .rgba = &.{} };
}

fn walk(comptime paint: bool, allocator: std.mem.Allocator, body: []const u8, params: Params) error{InvalidSixel}!Bitmap {
    var pal = params.palette.*;
    var x: u32 = 0;
    var y: u32 = 0;
    var max_x: u32 = 0;
    var max_y: u32 = 0;
    var color_i: u16 = 0;
    var repeat: u32 = 1;
    var have_repeat = false;
    var w: u32 = 1;
    var h: u32 = 6;
    var i: usize = 0;

    var pix: []u32 = &.{};
    if (paint) pix = allocator.alloc(u32, @as(usize, w) * h) catch return error.InvalidSixel;
    errdefer if (paint) allocator.free(pix);
    if (paint) @memset(pix, fillFor(params, &pal));

    while (i < body.len) {
        const c = body[i];
        i += 1;
        switch (c) {
            0x1b, 0x07 => break,
            '!' => {
                repeat = readNum(body, &i);
                if (repeat == 0) repeat = 1;
                have_repeat = true;
            },
            '"' => {
                _ = readNum(body, &i);
                skipSemi(body, &i);
                _ = readNum(body, &i);
                skipSemi(body, &i);
                const ph = readNum(body, &i);
                skipSemi(body, &i);
                const pv = readNum(body, &i);
                if (ph > 0 or pv > 0) {
                    const nw = if (ph > 0) @min(ph, params.max_w) else w;
                    const nh = if (pv > 0) @min(pv, params.max_h) else h;
                    if (paint) pix = try grow(allocator, pix, w, h, nw, nh, fillFor(params, &pal));
                    w = nw;
                    h = nh;
                }
            },
            '#' => {
                const pc = readNum(body, &i);
                color_i = @intCast(@min(pc, @as(u32, params.registers) -| 1));
                skipSemi(body, &i);
                if (i < body.len and body[i] >= '0' and body[i] <= '9') {
                    const pu = readNum(body, &i);
                    skipSemi(body, &i);
                    const px = readNum(body, &i);
                    skipSemi(body, &i);
                    const py = readNum(body, &i);
                    skipSemi(body, &i);
                    const pz = readNum(body, &i);
                    if (paint and color_i < pal.len) {
                        pal[color_i] = if (pu == 1) hls(px, py, pz) else rgb100(px, py, pz);
                    }
                }
            },
            '$' => x = 0,
            '-' => {
                x = 0;
                y += 6;
                if (y + 6 > h) {
                    const nh = @min(y + 6, params.max_h);
                    if (paint) pix = try grow(allocator, pix, w, h, w, nh, fillFor(params, &pal));
                    h = nh;
                }
            },
            0x3F...0x7E => {
                const bits: u8 = c - 0x3F;
                const n = if (have_repeat) repeat else 1;
                have_repeat = false;
                repeat = 1;
                if (bits != 0 or !params.transparent) {
                    if (y + 6 > h and h < params.max_h) {
                        const nh = @min(@max(h * 2, y + 6), params.max_h);
                        if (paint) pix = try grow(allocator, pix, w, h, w, nh, fillFor(params, &pal));
                        h = nh;
                    }
                    if (!paint) {
                        // Same growth as below (w doubles when x reaches it), without pixels.
                        const target = @min(x +| n, params.max_w);
                        while (w < target) w = @min(w * 2, params.max_w);
                        x = @max(x, target);
                        max_x = @max(max_x, x);
                        max_y = @max(max_y, y + 6);
                        continue;
                    }
                    const packed_c = pack(pal[@min(color_i, pal.len - 1)]);
                    const rows: u32 = @min(6, h -| y);
                    var k: u32 = 0;
                    while (k < n) : (k += 1) {
                        if (x >= params.max_w) break;
                        if (x >= w) {
                            const nw = @min(@max(w * 2, x + 1), params.max_w);
                            if (paint) pix = try grow(allocator, pix, w, h, nw, h, fillFor(params, &pal));
                            w = nw;
                        }
                        if (paint and bits != 0) {
                            var idx = @as(usize, y) * w + x;
                            var b: u32 = 0;
                            while (b < rows) : (b += 1) {
                                if ((bits >> @intCast(b)) & 1 != 0) pix[idx] = packed_c;
                                idx += w;
                            }
                        }
                        x += 1;
                    }
                } else {
                    x +|= n;
                }
                max_x = @max(max_x, x);
                max_y = @max(max_y, y + 6);
            },
            else => {},
        }
    }

    const out_w = @max(1, @min(w, if (max_x == 0) w else max_x));
    const out_h = @max(1, @min(h, if (max_y == 0) h else max_y));
    if (!paint) return .{ .width = out_w, .height = out_h, .rgba = &.{} };
    params.palette.* = pal;
    const rgba = allocator.alloc(u8, @as(usize, out_w) * out_h * 4) catch {
        allocator.free(pix);
        return error.InvalidSixel;
    };
    var row: u32 = 0;
    while (row < out_h) : (row += 1) {
        var col: u32 = 0;
        while (col < out_w) : (col += 1) {
            const src = if (row < h and col < w) pix[@as(usize, row) * w + col] else 0;
            const di = (@as(usize, row) * out_w + col) * 4;
            rgba[di + 0] = @truncate(src >> 16);
            rgba[di + 1] = @truncate(src >> 8);
            rgba[di + 2] = @truncate(src);
            rgba[di + 3] = @truncate(src >> 24);
        }
    }
    allocator.free(pix);
    return .{ .width = out_w, .height = out_h, .rgba = rgba };
}

pub fn defaultPalette() [256]Color {
    var pal: [256]Color = @splat(.{ .r = 0, .g = 0, .b = 0 });
    const seed = [_]Color{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 170, .g = 0, .b = 0 },
        .{ .r = 0, .g = 170, .b = 0 },
        .{ .r = 170, .g = 170, .b = 0 },
        .{ .r = 0, .g = 0, .b = 170 },
        .{ .r = 170, .g = 0, .b = 170 },
        .{ .r = 0, .g = 170, .b = 170 },
        .{ .r = 170, .g = 170, .b = 170 },
        .{ .r = 85, .g = 85, .b = 85 },
        .{ .r = 255, .g = 85, .b = 85 },
        .{ .r = 85, .g = 255, .b = 85 },
        .{ .r = 255, .g = 255, .b = 85 },
        .{ .r = 85, .g = 85, .b = 255 },
        .{ .r = 255, .g = 85, .b = 255 },
        .{ .r = 85, .g = 255, .b = 255 },
        .{ .r = 255, .g = 255, .b = 255 },
    };
    for (seed, 0..) |c, n| pal[n] = c;
    return pal;
}

fn pack(c: Color) u32 {
    return (@as(u32, 255) << 24) | (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

fn rgb100(r: u32, g: u32, b: u32) Color {
    return .{
        .r = scale100(r),
        .g = scale100(g),
        .b = scale100(b),
    };
}

fn scale100(v: u32) u8 {
    return @intCast(@min(255, v * 255 / 100));
}

fn hls(h: u32, l: u32, s: u32) Color {
    const hf = @as(f32, @floatFromInt(@min(h, 360))) / 360.0;
    const lf = @as(f32, @floatFromInt(@min(l, 100))) / 100.0;
    const sf = @as(f32, @floatFromInt(@min(s, 100))) / 100.0;
    var r: f32 = lf;
    var g: f32 = lf;
    var b: f32 = lf;
    if (sf > 0) {
        const q = if (lf < 0.5) lf * (1 + sf) else lf + sf - lf * sf;
        const p = 2 * lf - q;
        r = hue(p, q, hf + 1.0 / 3.0);
        g = hue(p, q, hf);
        b = hue(p, q, hf - 1.0 / 3.0);
    }
    return .{
        .r = @intFromFloat(std.math.clamp(r, 0, 1) * 255),
        .g = @intFromFloat(std.math.clamp(g, 0, 1) * 255),
        .b = @intFromFloat(std.math.clamp(b, 0, 1) * 255),
    };
}

fn hue(p: f32, q: f32, t0: f32) f32 {
    var t = t0;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

fn readNum(body: []const u8, i: *usize) u32 {
    var v: u32 = 0;
    while (i.* < body.len) {
        const c = body[i.*];
        if (c < '0' or c > '9') break;
        v = v *% 10 +% (c - '0');
        i.* += 1;
    }
    return v;
}

fn skipSemi(body: []const u8, i: *usize) void {
    if (i.* < body.len and body[i.*] == ';') i.* += 1;
}

/// Background for newly created canvas: palette 0 unless transparent (P2=1).
fn fillFor(params: Params, pal: *const [256]Color) u32 {
    return if (params.transparent) 0 else pack(pal[0]);
}

fn grow(allocator: std.mem.Allocator, pix: []u32, ow: u32, oh: u32, nw: u32, nh: u32, fill: u32) error{InvalidSixel}![]u32 {
    if (nw == ow and nh == oh) return pix;
    if (nw == 0 or nh == 0) return error.InvalidSixel;
    const next = allocator.alloc(u32, @as(usize, nw) * nh) catch return error.InvalidSixel;
    @memset(next, fill);
    const cw = @min(ow, nw);
    const ch = @min(oh, nh);
    var r: u32 = 0;
    while (r < ch) : (r += 1) {
        @memcpy(next[@as(usize, r) * nw ..][0..cw], pix[@as(usize, r) * ow ..][0..cw]);
    }
    allocator.free(pix);
    return next;
}

test "sixel hash color and dash" {
    var pal = defaultPalette();
    const bmp = try decode(std.testing.allocator, "#1;2;100;0;0~-", .{
        .palette = &pal,
        .transparent = true,
    });
    defer std.testing.allocator.free(bmp.rgba);
    try std.testing.expect(bmp.width >= 1);
    try std.testing.expect(bmp.height >= 6);
    try std.testing.expectEqual(@as(u8, 255), bmp.rgba[0]);
    try std.testing.expectEqual(@as(u8, 0), bmp.rgba[1]);
}

test "sixel non-transparent keeps earlier color passes in a band" {
    var pal = defaultPalette();
    const bmp = try decode(std.testing.allocator, "#1;2;100;0;0@$#2;2;0;100;0A", .{ .palette = &pal });
    defer std.testing.allocator.free(bmp.rgba);
    // row 0 = red (bit0 of '@'), row 1 = green (bit1 of 'A')
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, bmp.rgba[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, bmp.rgba[bmp.width * 4 ..][0..4]);
    // untouched pixel is opaque background (palette 0)
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, bmp.rgba[bmp.width * 2 * 4 ..][0..4]);
}

test "measure matches decode size" {
    const gpa = std.testing.allocator;
    var pal = defaultPalette();
    const bodies = [_][]const u8{
        "#1~~~~-#2!10~",
        "\"1;1;30;20#3!40?",
        "#0;2;100;0;0~~$~~-~-~",
        "!700~-!3~$!2000?~",
        "\"1;1;3;3!9~",
    };
    for (bodies) |body| {
        const m = measure(body, .{ .palette = &pal });
        const bmp = try decode(gpa, body, .{ .palette = &pal });
        defer gpa.free(bmp.rgba);
        try std.testing.expectEqual(bmp.width, m.width);
        try std.testing.expectEqual(bmp.height, m.height);
    }
}
