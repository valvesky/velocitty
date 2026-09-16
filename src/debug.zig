const std = @import("std");
const builtin = @import("builtin");

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode == .Debug) {
        std.log.debug(fmt, args);
    }
}

/// Layers for the debug-only visual overlay (OSC 556 / CSI ? 556).
/// No-ops in Release*; the sequence is ignored so it cannot leak into builds.
pub const Overlay = packed struct(u8) {
    grid: bool = false,
    wrap: bool = false,
    lcf: bool = false,
    cursor: bool = false,
    dirty: bool = false,
    region: bool = false,
    wide: bool = false,
    hud: bool = false,

    pub const none: Overlay = .{};
    pub const all: Overlay = .{
        .grid = true,
        .wrap = true,
        .lcf = true,
        .cursor = true,
        .dirty = true,
        .region = true,
        .wide = true,
        .hud = true,
    };

    pub fn any(self: Overlay) bool {
        return @as(u8, @bitCast(self)) != 0;
    }
};

pub const live = builtin.mode == .Debug;

pub const col_grid: u32 = 0xFF3A3A3A;
pub const col_wrap: u32 = 0xFF00E5FF;
pub const col_lcf: u32 = 0xFFFF00FF;
pub const col_cursor: u32 = 0xFF00FF66;
pub const col_dirty: u32 = 0xFFFF8800;
pub const col_region: u32 = 0xFFFFFF00;
pub const col_wide: u32 = 0xFF3366FF;
pub const col_hud_bg: u32 = 0xE0101018;
pub const col_hud_fg: u32 = 0xFFFFFFFF;

pub fn parseOsc(payload: []const u8) Overlay {
    const s = std.mem.trim(u8, payload, " \t\r\n");
    if (s.len == 0) return Overlay.all;
    if (eqlIgnore(s, "on") or eqlIgnore(s, "all") or std.mem.eql(u8, s, "1")) return Overlay.all;
    if (eqlIgnore(s, "off") or std.mem.eql(u8, s, "0")) return Overlay.none;

    var out: Overlay = .{};
    var it = std.mem.tokenizeAny(u8, s, ",; \t");
    while (it.next()) |tok| {
        if (eqlIgnore(tok, "grid")) {
            out.grid = true;
        } else if (eqlIgnore(tok, "wrap")) {
            out.wrap = true;
        } else if (eqlIgnore(tok, "lcf")) {
            out.lcf = true;
        } else if (eqlIgnore(tok, "cursor")) {
            out.cursor = true;
        } else if (eqlIgnore(tok, "dirty")) {
            out.dirty = true;
        } else if (eqlIgnore(tok, "region")) {
            out.region = true;
        } else if (eqlIgnore(tok, "wide")) {
            out.wide = true;
        } else if (eqlIgnore(tok, "hud")) {
            out.hud = true;
        } else if (eqlIgnore(tok, "all") or eqlIgnore(tok, "on")) {
            return Overlay.all;
        } else if (eqlIgnore(tok, "off")) {
            return Overlay.none;
        }
    }
    return out;
}

pub fn applyOsc(overlay: *Overlay, payload: []const u8) void {
    if (!live) {
        overlay.* = Overlay.none;
        return;
    }
    overlay.* = parseOsc(payload);
}

pub fn applyDec(overlay: *Overlay, enable: bool) void {
    if (!live) {
        overlay.* = Overlay.none;
        return;
    }
    overlay.* = if (enable) Overlay.all else Overlay.none;
}

pub fn put(pixels: []u32, width: u32, height: u32, x: i32, y: i32, color: u32) void {
    if (x < 0 or y < 0) return;
    const xu: u32 = @intCast(x);
    const yu: u32 = @intCast(y);
    if (xu >= width or yu >= height) return;
    pixels[@as(usize, yu) * width + xu] = color;
}

pub fn hline(pixels: []u32, width: u32, height: u32, x0: i32, x1: i32, y: i32, color: u32) void {
    if (y < 0 or x1 <= x0) return;
    const yu: u32 = @intCast(y);
    if (yu >= height) return;
    var x = @max(x0, 0);
    const last = @min(x1, @as(i32, @intCast(width)));
    while (x < last) : (x += 1) {
        pixels[@as(usize, yu) * width + @as(u32, @intCast(x))] = color;
    }
}

pub fn vline(pixels: []u32, width: u32, height: u32, x: i32, y0: i32, y1: i32, color: u32) void {
    if (x < 0 or y1 <= y0) return;
    const xu: u32 = @intCast(x);
    if (xu >= width) return;
    var y = @max(y0, 0);
    const last = @min(y1, @as(i32, @intCast(height)));
    while (y < last) : (y += 1) {
        pixels[@as(usize, @as(u32, @intCast(y))) * width + xu] = color;
    }
}

pub fn rect(pixels: []u32, width: u32, height: u32, x0: i32, y0: i32, w: i32, h: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    hline(pixels, width, height, x0, x0 + w, y0, color);
    hline(pixels, width, height, x0, x0 + w, y0 + h - 1, color);
    vline(pixels, width, height, x0, y0, y0 + h, color);
    vline(pixels, width, height, x0 + w - 1, y0, y0 + h, color);
}

pub fn fill(pixels: []u32, width: u32, height: u32, x0: i32, y0: i32, w: i32, h: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    var y = @max(y0, 0);
    const y1 = @min(y0 + h, @as(i32, @intCast(height)));
    const x_lo = @max(x0, 0);
    const x_hi = @min(x0 + w, @as(i32, @intCast(width)));
    if (x_hi <= x_lo) return;
    while (y < y1) : (y += 1) {
        hline(pixels, width, height, x_lo, x_hi, y, color);
    }
}

/// 3×5 glyphs, 1px gap. Unknown chars are skipped (advance still consumed).
pub fn text(pixels: []u32, width: u32, height: u32, x0: i32, y0: i32, s: []const u8, color: u32) void {
    var x = x0;
    for (s) |c| {
        blitGlyph(pixels, width, height, x, y0, c, color);
        x += 4;
    }
}

pub fn textWidth(s: []const u8) i32 {
    return @intCast(s.len * 4);
}

fn blitGlyph(pixels: []u32, width: u32, height: u32, x0: i32, y0: i32, c: u8, color: u32) void {
    const bits = glyph(asciiUpper(c));
    if (bits == 0) return;
    var row: u4 = 0;
    while (row < 5) : (row += 1) {
        var col: u4 = 0;
        while (col < 3) : (col += 1) {
            const bit: u4 = row * 3 + col;
            if ((bits >> bit) & 1 != 0) {
                put(pixels, width, height, x0 + col, y0 + row, color);
            }
        }
    }
}

fn asciiUpper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - ('a' - 'A') else c;
}

fn eqlIgnore(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (asciiUpper(x) != asciiUpper(y)) return false;
    }
    return true;
}

/// 3×5, row-major, LSB = top-left. Rightmost 3 bits are the top row.
fn glyph(c: u8) u16 {
    return switch (c) {
        '0' => 0b111_101_101_101_111,
        '1' => 0b111_010_010_110_010,
        '2' => 0b111_100_111_001_111,
        '3' => 0b111_001_111_001_111,
        '4' => 0b001_001_111_101_101,
        '5' => 0b111_001_111_100_111,
        '6' => 0b111_101_111_100_111,
        '7' => 0b001_001_001_001_111,
        '8' => 0b111_101_111_101_111,
        '9' => 0b111_001_111_101_111,
        'A' => 0b101_101_111_101_010,
        'B' => 0b111_101_110_101_110,
        'C' => 0b111_100_100_100_111,
        'D' => 0b110_101_101_101_110,
        'E' => 0b111_100_111_100_111,
        'F' => 0b100_100_111_100_111,
        'G' => 0b111_101_101_100_111,
        'H' => 0b101_101_111_101_101,
        'I' => 0b111_010_010_010_111,
        'J' => 0b110_101_001_001_001,
        'K' => 0b101_101_110_101_101,
        'L' => 0b111_100_100_100_100,
        'M' => 0b101_101_101_111_101,
        'N' => 0b101_101_101_111_101,
        'O' => 0b111_101_101_101_111,
        'P' => 0b100_100_111_101_111,
        'Q' => 0b001_111_101_101_111,
        'R' => 0b101_110_111_101_110,
        'S' => 0b111_001_111_100_111,
        'T' => 0b010_010_010_010_111,
        'U' => 0b111_101_101_101_101,
        'V' => 0b010_101_101_101_101,
        'W' => 0b101_111_101_101_101,
        'X' => 0b101_101_010_101_101,
        'Y' => 0b010_010_010_101_101,
        'Z' => 0b111_100_010_001_111,
        '-' => 0b000_000_111_000_000,
        '=' => 0b000_111_000_111_000,
        ':' => 0b000_010_000_010_000,
        ',' => 0b010_001_000_000_000,
        '.' => 0b010_000_000_000_000,
        '+' => 0b000_010_111_010_000,
        '/' => 0b100_010_010_010_001,
        else => 0,
    };
}

test "parse osc 556" {
    try std.testing.expectEqual(Overlay.all, parseOsc(""));
    try std.testing.expectEqual(Overlay.all, parseOsc("all"));
    try std.testing.expectEqual(Overlay.all, parseOsc("ON"));
    try std.testing.expectEqual(Overlay.none, parseOsc("off"));
    try std.testing.expectEqual(Overlay.none, parseOsc("0"));
    const w = parseOsc("wrap,lcf");
    try std.testing.expect(w.wrap and w.lcf and !w.grid and !w.hud);
    const g = parseOsc("grid hud");
    try std.testing.expect(g.grid and g.hud and !g.dirty);
}
