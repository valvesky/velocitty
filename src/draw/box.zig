//! Cell-aligned box drawing, block elements, and braille.
//!
//! Font outlines miss 1px TUI bars. Draw the U+2500 and U+2580 blocks
//! (and braille) into the cell instead. Shape table from Avi Halachmi's
//! st boxdraw (MIT).

const std = @import("std");

pub const Clip = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
};

const bdl: u16 = 1 << 8;
const bda: u16 = 1 << 9;
const bbd: u16 = 1 << 10;
const bbl: u16 = 2 << 10;
const bbu: u16 = 3 << 10;
const bbr: u16 = 4 << 10;
const bbq: u16 = 5 << 10;
const brl: u16 = 6 << 10;
const bbs: u16 = 1 << 14;
const bdb: u16 = 1 << 15;

const ll: u16 = 1 << 0;
const lu: u16 = 1 << 1;
const lr: u16 = 1 << 2;
const ld: u16 = 1 << 3;
const lh: u16 = ll + lr;
const lv: u16 = lu + ld;

const dl: u16 = 1 << 4;
const du: u16 = 1 << 5;
const dr: u16 = 1 << 6;
const dd: u16 = 1 << 7;
const dh: u16 = dl + dr;
const dv: u16 = du + dd;

const hl: u16 = ll + dl;
const hu: u16 = lu + du;
const hr: u16 = lr + dr;
const hd: u16 = ld + dd;
const hh: u16 = hl + hr;
const hv: u16 = hu + hd;

const qtl: u16 = 1 << 0;
const qtr: u16 = 1 << 1;
const qbl: u16 = 1 << 2;
const qbr: u16 = 1 << 3;

pub fn paint(
    pixels: []u32,
    stride: u32,
    height: u32,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    fg: u32,
    bg: u32,
    clip: Clip,
    cp: u21,
    bold: bool,
) bool {
    if (w == 0 or h == 0) return false;
    if (cp >= 0x23BA and cp <= 0x23BD) {
        paintScanline(pixels, stride, height, x, y, w, h, fg, clip, cp, bold);
        return true;
    }
    const bd = shape(cp, bold) orelse return false;
    const wi: i32 = @intCast(w);
    const hi: i32 = @intCast(h);
    const cat = bd & ~@as(u16, bdb | 0xff);
    if (bd & (bdl | bda) != 0) {
        paintLines(pixels, stride, height, x, y, wi, hi, fg, clip, bd);
    } else if (cat == bbd) {
        const d = div(@as(i32, bd & 0xff) * hi, 8);
        fill(pixels, stride, height, x, y + d, wi, hi - d, fg, clip);
    } else if (cat == bbu) {
        fill(pixels, stride, height, x, y, wi, div(@as(i32, bd & 0xff) * hi, 8), fg, clip);
    } else if (cat == bbl) {
        fill(pixels, stride, height, x, y, div(@as(i32, bd & 0xff) * wi, 8), hi, fg, clip);
    } else if (cat == bbr) {
        const d = div(@as(i32, bd & 0xff) * wi, 8);
        fill(pixels, stride, height, x + d, y, wi - d, hi, fg, clip);
    } else if (cat == bbq) {
        const w2 = div(wi, 2);
        const h2 = div(hi, 2);
        if (bd & qtl != 0) fill(pixels, stride, height, x, y, w2, h2, fg, clip);
        if (bd & qtr != 0) fill(pixels, stride, height, x + w2, y, wi - w2, h2, fg, clip);
        if (bd & qbl != 0) fill(pixels, stride, height, x, y + h2, w2, hi - h2, fg, clip);
        if (bd & qbr != 0) fill(pixels, stride, height, x + w2, y + h2, wi - w2, hi - h2, fg, clip);
    } else if (bd & bbs != 0) {
        const shade = mix(bg, fg, bd & 0xff, 4);
        fill(pixels, stride, height, x, y, wi, hi, shade, clip);
    } else if (cat == brl) {
        paintBraille(pixels, stride, height, x, y, wi, hi, fg, clip, @as(u8, @truncate(bd)));
    }
    return true;
}

fn shape(cp: u21, bold: bool) ?u16 {
    if (cp >= 0x2800 and cp <= 0x28FF) {
        return brl | @as(u16, @as(u8, @truncate(cp)));
    }
    if (cp < 0x2500 or cp > 0x259F) return null;
    const d = boxData(@as(u8, @truncate(cp)));
    if (d == 0) return null;
    return if (bold) d | bdb else d;
}

fn paintScanline(
    pixels: []u32,
    stride: u32,
    height: u32,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    fg: u32,
    clip: Clip,
    cp: u21,
    bold: bool,
) void {
    const wi: i32 = @intCast(w);
    const hi: i32 = @intCast(h);
    const s = stem(wi, hi, bold);
    const t: i32 = switch (cp) {
        0x23BA => 0,
        0x23BB => @max(0, div(hi, 3) - @divTrunc(s, 2)),
        0x23BC => @max(0, div(2 * hi, 3) - @divTrunc(s, 2)),
        else => @max(0, hi - s),
    };
    fill(pixels, stride, height, x, y + t, wi, s, fg, clip);
}

fn paintBraille(
    pixels: []u32,
    stride: u32,
    height: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    fg: u32,
    clip: Clip,
    bits: u8,
) void {
    const w1 = div(w, 2);
    const h1 = div(h, 4);
    const h2 = div(h, 2);
    const h3 = div(3 * h, 4);
    if (bits & 1 != 0) fill(pixels, stride, height, x, y, w1, h1, fg, clip);
    if (bits & 2 != 0) fill(pixels, stride, height, x, y + h1, w1, h2 - h1, fg, clip);
    if (bits & 4 != 0) fill(pixels, stride, height, x, y + h2, w1, h3 - h2, fg, clip);
    if (bits & 8 != 0) fill(pixels, stride, height, x + w1, y, w - w1, h1, fg, clip);
    if (bits & 16 != 0) fill(pixels, stride, height, x + w1, y + h1, w - w1, h2 - h1, fg, clip);
    if (bits & 32 != 0) fill(pixels, stride, height, x + w1, y + h2, w - w1, h3 - h2, fg, clip);
    if (bits & 64 != 0) fill(pixels, stride, height, x, y + h3, w1, h - h3, fg, clip);
    if (bits & 128 != 0) fill(pixels, stride, height, x + w1, y + h3, w - w1, h - h3, fg, clip);
}

fn paintLines(
    pixels: []u32,
    stride: u32,
    height: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    fg: u32,
    clip: Clip,
    bd: u16,
) void {
    const s = stem(w, h, bd & bdb != 0);
    const w2 = div(w - s, 2);
    const h2 = div(h - s, 2);
    const light = bd & (ll | lu | lr | ld);
    const double_ = bd & (dl | du | dr | dd);

    if (light != 0) {
        const arc = bd & bda != 0;
        const multi_light = light & (light -% 1) != 0;
        const multi_double = double_ & (double_ -% 1) != 0;
        const d: i32 = if (arc or (multi_double and !multi_light)) -s else 0;
        if (bd & ll != 0) fill(pixels, stride, height, x, y + h2, w2 + s + d, s, fg, clip);
        if (bd & lu != 0) fill(pixels, stride, height, x + w2, y, s, h2 + s + d, fg, clip);
        if (bd & lr != 0) fill(pixels, stride, height, x + w2 - d, y + h2, w - w2 + d, s, fg, clip);
        if (bd & ld != 0) fill(pixels, stride, height, x + w2, y + h2 - d, s, h - h2 + d, fg, clip);
    }

    if (double_ != 0) {
        const has_dl = bd & dl != 0;
        const has_du = bd & du != 0;
        const has_dr = bd & dr != 0;
        const has_dd = bd & dd != 0;
        if (has_dl) {
            const p: i32 = if (has_dd) -s else 0;
            const n: i32 = if (has_du) -s else if (has_dd) s else 0;
            fill(pixels, stride, height, x, y + h2 + s, w2 + s + p, s, fg, clip);
            fill(pixels, stride, height, x, y + h2 - s, w2 + s + n, s, fg, clip);
        }
        if (has_du) {
            const p: i32 = if (has_dl) -s else 0;
            const n: i32 = if (has_dr) -s else if (has_dl) s else 0;
            fill(pixels, stride, height, x + w2 - s, y, s, h2 + s + p, fg, clip);
            fill(pixels, stride, height, x + w2 + s, y, s, h2 + s + n, fg, clip);
        }
        if (has_dr) {
            const p: i32 = if (has_du) -s else 0;
            const n: i32 = if (has_dd) -s else if (has_du) s else 0;
            fill(pixels, stride, height, x + w2 - p, y + h2 - s, w - w2 + p, s, fg, clip);
            fill(pixels, stride, height, x + w2 - n, y + h2 + s, w - w2 + n, s, fg, clip);
        }
        if (has_dd) {
            const p: i32 = if (has_dr) -s else 0;
            const n: i32 = if (has_dl) -s else if (has_dr) s else 0;
            fill(pixels, stride, height, x + w2 + s, y + h2 - p, s, h - h2 + p, fg, clip);
            fill(pixels, stride, height, x + w2 - s, y + h2 - n, s, h - h2 + n, fg, clip);
        }
    }
}

fn stem(w: i32, h: i32, bold: bool) i32 {
    const mwh = @min(w, h);
    const base = @max(1, div(mwh, 8));
    if (bold and mwh >= 6) return @max(base + 1, div(3 * base, 2));
    return base;
}

fn div(n: i32, d: i32) i32 {
    if (d == 0) return 0;
    return @divTrunc(n + @divTrunc(d, 2), d);
}

fn mix(bg: u32, fg: u32, num: u32, den: u32) u32 {
    const t = num;
    const u = den - num;
    const br = (bg >> 16) & 0xff;
    const bg_ = (bg >> 8) & 0xff;
    const bb = bg & 0xff;
    const ba = (bg >> 24) & 0xff;
    const fr = (fg >> 16) & 0xff;
    const fg_ = (fg >> 8) & 0xff;
    const fb = fg & 0xff;
    const r = (br * u + fr * t) / den;
    const g = (bg_ * u + fg_ * t) / den;
    const b = (bb * u + fb * t) / den;
    return (ba << 24) | (r << 16) | (g << 8) | b;
}

fn fill(
    pixels: []u32,
    stride: u32,
    height: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: u32,
    clip: Clip,
) void {
    if (w <= 0 or h <= 0) return;
    var x0 = x;
    var y0 = y;
    var x1 = x + w;
    var y1 = y + h;
    x0 = @max(x0, clip.x0);
    y0 = @max(y0, clip.y0);
    x1 = @min(x1, clip.x1);
    y1 = @min(y1, clip.y1);
    x0 = @max(x0, 0);
    y0 = @max(y0, 0);
    x1 = @min(x1, @as(i32, @intCast(stride)));
    y1 = @min(y1, @as(i32, @intCast(height)));
    if (x0 >= x1 or y0 >= y1) return;
    const row_w: usize = @intCast(x1 - x0);
    var row = y0;
    while (row < y1) : (row += 1) {
        const start: usize = @as(usize, @intCast(row)) * stride + @as(usize, @intCast(x0));
        @memset(pixels[start .. start + row_w], color);
    }
}

fn boxData(idx: u8) u16 {
    return switch (idx) {
        0x00 => bdl + lh,
        0x02 => bdl + lv,
        0x0c => bdl + ld + lr,
        0x10 => bdl + ld + ll,
        0x14 => bdl + lu + lr,
        0x18 => bdl + lu + ll,
        0x1c => bdl + lv + lr,
        0x24 => bdl + lv + ll,
        0x2c => bdl + lh + ld,
        0x34 => bdl + lh + lu,
        0x3c => bdl + lv + lh,
        0x74 => bdl + ll,
        0x75 => bdl + lu,
        0x76 => bdl + lr,
        0x77 => bdl + ld,
        0x01 => bdl + hh,
        0x03 => bdl + hv,
        0x0d => bdl + hr + ld,
        0x0e => bdl + hd + lr,
        0x0f => bdl + hd + hr,
        0x11 => bdl + hl + ld,
        0x12 => bdl + hd + ll,
        0x13 => bdl + hd + hl,
        0x15 => bdl + hr + lu,
        0x16 => bdl + hu + lr,
        0x17 => bdl + hu + hr,
        0x19 => bdl + hl + lu,
        0x1a => bdl + hu + ll,
        0x1b => bdl + hu + hl,
        0x1d => bdl + hr + lv,
        0x1e => bdl + hu + ld + lr,
        0x1f => bdl + hd + lr + lu,
        0x20 => bdl + hv + lr,
        0x21 => bdl + hu + hr + ld,
        0x22 => bdl + hd + hr + lu,
        0x23 => bdl + hv + hr,
        0x25 => bdl + hl + lv,
        0x26 => bdl + hu + ld + ll,
        0x27 => bdl + hd + lu + ll,
        0x28 => bdl + hv + ll,
        0x29 => bdl + hu + hl + ld,
        0x2a => bdl + hd + hl + lu,
        0x2b => bdl + hv + hl,
        0x2d => bdl + hl + ld + lr,
        0x2e => bdl + hr + ll + ld,
        0x2f => bdl + hh + ld,
        0x30 => bdl + hd + lh,
        0x31 => bdl + hd + hl + lr,
        0x32 => bdl + hr + hd + ll,
        0x33 => bdl + hh + hd,
        0x35 => bdl + hl + lu + lr,
        0x36 => bdl + hr + lu + ll,
        0x37 => bdl + hh + lu,
        0x38 => bdl + hu + lh,
        0x39 => bdl + hu + hl + lr,
        0x3a => bdl + hu + hr + ll,
        0x3b => bdl + hh + hu,
        0x3d => bdl + hl + lv + lr,
        0x3e => bdl + hr + lv + ll,
        0x3f => bdl + hh + lv,
        0x40 => bdl + hu + lh + ld,
        0x41 => bdl + hd + lh + lu,
        0x42 => bdl + hv + lh,
        0x43 => bdl + hu + hl + ld + lr,
        0x44 => bdl + hu + hr + ld + ll,
        0x45 => bdl + hd + hl + lu + lr,
        0x46 => bdl + hd + hr + lu + ll,
        0x47 => bdl + hh + hu + ld,
        0x48 => bdl + hh + hd + lu,
        0x49 => bdl + hv + hl + lr,
        0x4a => bdl + hv + hr + ll,
        0x4b => bdl + hv + hh,
        0x78 => bdl + hl,
        0x79 => bdl + hu,
        0x7a => bdl + hr,
        0x7b => bdl + hd,
        0x7c => bdl + hr + ll,
        0x7d => bdl + hd + lu,
        0x7e => bdl + hl + lr,
        0x7f => bdl + hu + ld,
        0x50 => bdl + dh,
        0x51 => bdl + dv,
        0x52 => bdl + dr + ld,
        0x53 => bdl + dd + lr,
        0x54 => bdl + dr + dd,
        0x55 => bdl + dl + ld,
        0x56 => bdl + dd + ll,
        0x57 => bdl + dl + dd,
        0x58 => bdl + dr + lu,
        0x59 => bdl + du + lr,
        0x5a => bdl + du + dr,
        0x5b => bdl + dl + lu,
        0x5c => bdl + du + ll,
        0x5d => bdl + dl + du,
        0x5e => bdl + dr + lv,
        0x5f => bdl + dv + lr,
        0x60 => bdl + dv + dr,
        0x61 => bdl + dl + lv,
        0x62 => bdl + dv + ll,
        0x63 => bdl + dv + dl,
        0x64 => bdl + dh + ld,
        0x65 => bdl + dd + lh,
        0x66 => bdl + dd + dh,
        0x67 => bdl + dh + lu,
        0x68 => bdl + du + lh,
        0x69 => bdl + dh + du,
        0x6a => bdl + dh + lv,
        0x6b => bdl + dv + lh,
        0x6c => bdl + dh + dv,
        0x6d => bda + ld + lr,
        0x6e => bda + ld + ll,
        0x6f => bda + lu + ll,
        0x70 => bda + lu + lr,
        0x81 => bbd + 7,
        0x82 => bbd + 6,
        0x83 => bbd + 5,
        0x84 => bbd + 4,
        0x85 => bbd + 3,
        0x86 => bbd + 2,
        0x87 => bbd + 1,
        0x88 => bbd + 0,
        0x89 => bbl + 7,
        0x8a => bbl + 6,
        0x8b => bbl + 5,
        0x8c => bbl + 4,
        0x8d => bbl + 3,
        0x8e => bbl + 2,
        0x8f => bbl + 1,
        0x80 => bbu + 4,
        0x94 => bbu + 1,
        0x90 => bbr + 4,
        0x95 => bbr + 7,
        0x96 => bbq + qbl,
        0x97 => bbq + qbr,
        0x98 => bbq + qtl,
        0x99 => bbq + qtl + qbl + qbr,
        0x9a => bbq + qtl + qbr,
        0x9b => bbq + qtl + qtr + qbl,
        0x9c => bbq + qtl + qtr + qbr,
        0x9d => bbq + qtr,
        0x9e => bbq + qbl + qtr,
        0x9f => bbq + qbl + qtr + qbr,
        0x91 => bbs + 1,
        0x92 => bbs + 2,
        0x93 => bbs + 3,
        else => 0,
    };
}

test "light horizontal spans the cell" {
    var pixels: [8 * 8]u32 = @splat(0);
    const clip = Clip{ .x0 = 0, .y0 = 0, .x1 = 8, .y1 = 8 };
    try std.testing.expect(paint(&pixels, 8, 8, 0, 0, 8, 8, 0xffffffff, 0xff000000, clip, 0x2500, false));
    var fg: usize = 0;
    for (pixels) |p| {
        if (p == 0xffffffff) fg += 1;
    }
    try std.testing.expect(fg >= 8);
    try std.testing.expectEqual(@as(u32, 0), pixels[0]);
}

test "acs tee and full block" {
    var pixels: [8 * 8]u32 = @splat(0);
    const clip = Clip{ .x0 = 0, .y0 = 0, .x1 = 8, .y1 = 8 };
    try std.testing.expect(paint(&pixels, 8, 8, 0, 0, 8, 8, 0xffffffff, 0, clip, 0x251C, false));
    try std.testing.expect(paint(&pixels, 8, 8, 0, 0, 8, 8, 0xffffffff, 0, clip, 0x2588, false));
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[8 * 8 - 1]);
}
