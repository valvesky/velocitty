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

    var pix = allocator.alloc(u32, @as(usize, w) * h) catch return error.InvalidSixel;
    errdefer allocator.free(pix);
    @memset(pix, 0);

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
                    pix = grow(allocator, pix, w, h, nw, nh) catch return error.InvalidSixel;
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
                    if (color_i < pal.len) {
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
                    pix = grow(allocator, pix, w, h, w, nh) catch return error.InvalidSixel;
                    h = nh;
                }
            },
            0x3F...0x7E => {
                const bits: u8 = c - 0x3F;
                const n = if (have_repeat) repeat else 1;
                have_repeat = false;
                repeat = 1;
                if (bits != 0 or !params.transparent) {
                    var k: u32 = 0;
                    while (k < n) : (k += 1) {
                        if (x >= params.max_w) break;
                        if (x >= w) {
                            const nw = @min(@max(w * 2, x + 1), params.max_w);
                            pix = grow(allocator, pix, w, h, nw, h) catch return error.InvalidSixel;
                            w = nw;
                        }
                        if (y + 6 > h) {
                            const nh = @min(@max(h * 2, y + 6), params.max_h);
                            pix = grow(allocator, pix, w, h, w, nh) catch return error.InvalidSixel;
                            h = nh;
                        }
                        const col = pal[@min(color_i, pal.len - 1)];
                        const packed_c = pack(col);
                        var b: u3 = 0;
                        while (b < 6) : (b += 1) {
                            if ((bits >> b) & 1 == 0) {
                                if (params.transparent) continue;
                            }
                            const py = y + b;
                            if (py >= h) break;
                            pix[@as(usize, py) * w + x] = if ((bits >> b) & 1 != 0) packed_c else if (params.transparent) 0 else pack(pal[0]);
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

    params.palette.* = pal;
    const out_w = @max(1, @min(w, if (max_x == 0) w else max_x));
    const out_h = @max(1, @min(h, if (max_y == 0) h else max_y));
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

fn grow(allocator: std.mem.Allocator, pix: []u32, ow: u32, oh: u32, nw: u32, nh: u32) error{InvalidSixel}![]u32 {
    if (nw == ow and nh == oh) return pix;
    if (nw == 0 or nh == 0) return error.InvalidSixel;
    const next = allocator.alloc(u32, @as(usize, nw) * nh) catch return error.InvalidSixel;
    @memset(next, 0);
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
