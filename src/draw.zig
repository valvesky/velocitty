//! CPU framebuffer.

const std = @import("std");
const assert = std.debug.assert;
const Term = @import("term.zig");
const Type = @import("type.zig");
const Box = @import("draw/box.zig");

const vec_len = std.simd.suggestVectorLength(u32) orelse 4;

const Clip = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
};

pub const Frame = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u32,
    prev: []Term.Cell = &.{},
    prev_cols: u16 = 0,
    prev_rows: u16 = 0,
    prev_cursor: Term.Cursor = .{},
    prev_cursor_on: bool = false,
    prev_cursor_style: Term.CursorStyle = .block,
    dirty_y: u32 = 0,
    dirty_h: u32 = 0,
    dirty_full: bool = true,
    last_fill_ns: u64 = 0,
    last_glyph_ns: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) std.mem.Allocator.Error!Frame {
        assert(width > 0);
        assert(height > 0);
        const pixels = try allocator.alloc(u32, width * height);
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *Frame) void {
        if (self.prev.len != 0) self.allocator.free(self.prev);
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn resize(self: *Frame, width: u32, height: u32) std.mem.Allocator.Error!void {
        assert(width > 0);
        assert(height > 0);
        if (width == self.width and height == self.height) return;
        const pixels = try self.allocator.realloc(self.pixels, width * height);
        @memset(pixels, 0);
        self.pixels = pixels;
        self.width = width;
        self.height = height;
        self.forgetPrev();
        self.dirty_full = true;
        self.dirty_y = 0;
        self.dirty_h = height;
    }

    pub fn damaged(self: *const Frame) bool {
        return self.dirty_full or self.dirty_h != 0;
    }

    /// Drop the retained cell snapshot so the next `render` paints every line.
    pub fn invalidate(self: *Frame) void {
        self.prev_rows = 0;
        self.dirty_full = true;
        self.dirty_y = 0;
        self.dirty_h = self.height;
    }

    pub fn pack(color: Term.Color) u32 {
        return (@as(u32, color.a) << 24) |
            (@as(u32, color.r) << 16) |
            (@as(u32, color.g) << 8) |
            color.b;
    }

    pub fn render(self: *Frame, screen: *const Term.Screen, cell_w: u32, cell_h: u32, type_ctx: ?*Type.Context, size_px: f32) void {
        assert(cell_w > 0);
        assert(cell_h > 0);
        assert(self.width == @as(u32, screen.cols) * cell_w);
        assert(self.height == @as(u32, screen.rows) * cell_h);
        assert(size_px > 0);
        const size: f32 = size_px;
        var baseline: f32 = @round(size * 0.8);
        if (type_ctx) |ctx| {
            if (ctx.metrics(size)) |m| {
                baseline = @round(m.ascender);
            } else |_| {}
        }

        const cols = screen.cols;
        const rows = screen.rows;
        const have_prev = self.ensurePrev(cols, rows);
        const cur_on = screen.cursorVisible() and screen.scrollOffset() == 0;
        var cur = screen.cursor();
        if (cur.row >= rows) cur.row = rows - 1;
        if (cur.col >= cols) cur.col = cols - 1;
        const style = screen.cursorStyle();
        const style_changed = style != self.prev_cursor_style;

        self.dirty_full = false;
        self.dirty_y = 0;
        self.dirty_h = 0;

        var scroll: i2 = 0;
        if (have_prev) {
            if (scrolledBy(screen, self.prev, cols, rows, 1)) {
                scroll = 1;
            } else if (scrolledBy(screen, self.prev, cols, rows, -1)) {
                scroll = -1;
            }
        }
        if (scroll != 0 and self.prev_cursor_on) {
            var pc = self.prev_cursor;
            if (pc.row >= rows) pc.row = rows - 1;
            if (pc.col >= cols) pc.col = cols - 1;
            paintCursor(self, pc.col, pc.row, cell_w, cell_h, self.prev_cursor_style);
        }
        if (scroll == 1) {
            shiftPixels(self, cell_h, .up);
            shiftPrev(self, cols, rows, .up);
            self.dirty_full = true;
        } else if (scroll == -1) {
            shiftPixels(self, cell_h, .down);
            shiftPrev(self, cols, rows, .down);
            self.dirty_full = true;
        }

        const use_bits = have_prev and screen.scrollOffset() == 0 and scroll == 0;
        var paint_buf: [512]bool = @splat(false);
        const paint_all = rows > paint_buf.len;
        var r: u16 = 0;
        while (r < rows) : (r += 1) {
            const cursor_row = mustPaintCursorRow(r, self.prev_cursor, self.prev_cursor_on, cur, cur_on) or
                (style_changed and (r == cur.row or r == self.prev_cursor.row)) or
                (scroll != 0 and cur_on and r == cur.row);
            var need = true;
            if (!paint_all and !cursor_row) {
                if (use_bits and !screen.lineDirty(r)) {
                    need = false;
                } else if (have_prev and rowEql(screen.rowCells(r), self.prevRow(r, cols))) {
                    need = false;
                }
            }
            if (!paint_all) paint_buf[r] = need;
        }

        const Run = struct { start: u16, end: u16 };
        var run_buf: [256]Run = undefined;
        var nruns: u16 = 0;
        r = 0;
        while (r < rows) {
            const need = paint_all or paint_buf[r];
            if (!need) {
                r += 1;
                continue;
            }
            const start = r;
            r += 1;
            while (r < rows and (paint_all or paint_buf[r])) : (r += 1) {}
            if (nruns == run_buf.len) {
                nruns = 1;
                run_buf[0] = .{ .start = 0, .end = rows };
                break;
            }
            run_buf[nruns] = .{ .start = start, .end = r };
            nruns += 1;
        }

        var fill_ns: u64 = 0;
        var glyph_ns: u64 = 0;
        var ri: u16 = 0;
        while (ri < nruns) : (ri += 1) {
            const run = run_buf[ri];
            const y0 = @as(u32, run.start) * cell_h;
            const tf0 = nowNs();
            fillRun(self, screen, run.start, run.end, cell_w, cell_h);
            fill_ns += @intCast(nowNs() - tf0);
            const clip = Clip{
                .x0 = 0,
                .y0 = @intCast(y0),
                .x1 = @intCast(self.width),
                .y1 = @intCast(@as(u32, run.end) * cell_h),
            };
            const tg0 = nowNs();
            var gr: i32 = @as(i32, run.start) - 1;
            const gr_last: i32 = run.end;
            while (gr <= gr_last) : (gr += 1) {
                if (gr < 0 or gr >= rows) continue;
                const rr: u16 = @intCast(gr);
                const line = screen.rowCells(rr);
                blitLine(self, line, rr, 0, @intCast(line.len), cell_w, cell_h, type_ctx, size, baseline, clip);
            }
            var rr: u16 = run.start;
            while (rr < run.end) : (rr += 1) {
                if (self.prev.len == @as(usize, cols) * rows) {
                    @memcpy(self.prevRowMut(rr, cols), screen.rowCells(rr));
                }
            }
            if (cur_on and cur.row >= run.start and cur.row < run.end) {
                paintCursor(self, cur.col, cur.row, cell_w, cell_h, style);
            }
            glyph_ns += @intCast(nowNs() - tg0);
        }
        if (screen.scrollOffset() == 0) {
            blitKitty(self, screen, cell_w, cell_h);
        }
        self.last_fill_ns = fill_ns;
        self.last_glyph_ns = glyph_ns;
        self.prev_cursor = cur;
        self.prev_cursor_on = cur_on;
        self.prev_cursor_style = style;
        if (self.dirty_h == self.height) self.dirty_full = true;
    }

    fn forgetPrev(self: *Frame) void {
        if (self.prev.len != 0) {
            self.allocator.free(self.prev);
            self.prev = &.{};
        }
        self.prev_cols = 0;
        self.prev_rows = 0;
        self.prev_cursor_on = false;
        self.prev_cursor_style = .block;
    }

    fn ensurePrev(self: *Frame, cols: u16, rows: u16) bool {
        const n = @as(usize, cols) * rows;
        if (self.prev.len == n and self.prev_cols == cols and self.prev_rows == rows) return true;
        if (self.prev.len == n) {
            self.prev_cols = cols;
            self.prev_rows = rows;
            return false;
        }
        self.forgetPrev();
        self.prev = self.allocator.alloc(Term.Cell, n) catch return false;
        self.prev_cols = cols;
        self.prev_rows = rows;
        return false;
    }

    fn prevRow(self: *const Frame, row: u16, cols: u16) []const Term.Cell {
        const off = @as(usize, row) * cols;
        return self.prev[off .. off + cols];
    }

    fn prevRowMut(self: *Frame, row: u16, cols: u16) []Term.Cell {
        const off = @as(usize, row) * cols;
        return self.prev[off .. off + cols];
    }
};

fn fillRun(
    self: *Frame,
    screen: *const Term.Screen,
    start: u16,
    end: u16,
    cell_w: u32,
    cell_h: u32,
) void {
    const y0 = @as(u32, start) * cell_h;
    if (runUniformBg(screen, start, end)) |bg| {
        fillRect(self, 0, y0, self.width, @as(u32, end - start) * cell_h, bg);
    } else {
        var rr: u16 = start;
        while (rr < end) : (rr += 1) {
            paintBg(self, screen.rowCells(rr), rr, cell_w, cell_h);
        }
    }
    var rr: u16 = start;
    while (rr < end) : (rr += 1) markDirtyStrip(self, rr, cell_h);
}

fn runUniformBg(screen: *const Term.Screen, start: u16, end: u16) ?u32 {
    if (start >= end) return null;
    const first = screen.rowCells(start);
    if (first.len == 0) return null;
    const bg = packColor(effectiveBg(first[0]));
    var r = start;
    while (r < end) : (r += 1) {
        for (screen.rowCells(r)) |cell| {
            if (packColor(effectiveBg(cell)) != bg) return null;
        }
    }
    return bg;
}

fn mustPaintCursorRow(
    row: u16,
    prev: Term.Cursor,
    prev_on: bool,
    cur: Term.Cursor,
    cur_on: bool,
) bool {
    const was = prev_on and prev.row == row;
    const now = cur_on and cur.row == row;
    if (!was and !now) return false;
    if (was and now and prev.col == cur.col) return false;
    return true;
}

fn rowEql(a: []const Term.Cell, b: []const Term.Cell) bool {
    if (a.len != b.len) return false;
    return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
}

fn scrolledBy(screen: *const Term.Screen, prev: []const Term.Cell, cols: u16, rows: u16, delta: i2) bool {
    if (rows < 2 or prev.len != @as(usize, cols) * rows) return false;
    if (delta == 1) {
        if (rowEql(screen.rowCells(0), prev[0..cols])) return false;
        var r: u16 = 0;
        while (r + 1 < rows) : (r += 1) {
            const off = @as(usize, r + 1) * cols;
            if (!rowEql(screen.rowCells(r), prev[off .. off + cols])) return false;
        }
        return true;
    }
    if (delta == -1) {
        const last = @as(usize, rows - 1) * cols;
        if (rowEql(screen.rowCells(rows - 1), prev[last .. last + cols])) return false;
        var r: u16 = 1;
        while (r < rows) : (r += 1) {
            const off = @as(usize, r - 1) * cols;
            if (!rowEql(screen.rowCells(r), prev[off .. off + cols])) return false;
        }
        return true;
    }
    return false;
}

const Shift = enum { up, down };

fn shiftPixels(self: *Frame, cell_h: u32, dir: Shift) void {
    const strip = cell_h * self.width;
    if (strip == 0 or self.pixels.len <= strip) return;
    const n = self.pixels.len - strip;
    switch (dir) {
        .up => std.mem.copyForwards(u32, self.pixels[0..n], self.pixels[strip .. strip + n]),
        .down => std.mem.copyBackwards(u32, self.pixels[strip .. strip + n], self.pixels[0..n]),
    }
}

fn shiftPrev(self: *Frame, cols: u16, rows: u16, dir: Shift) void {
    if (rows < 2) return;
    const n = @as(usize, cols) * (rows - 1);
    switch (dir) {
        .up => std.mem.copyForwards(Term.Cell, self.prev[0..n], self.prev[cols .. cols + n]),
        .down => std.mem.copyBackwards(Term.Cell, self.prev[cols .. cols + n], self.prev[0..n]),
    }
}

fn markDirtyStrip(self: *Frame, row: u16, cell_h: u32) void {
    const y = @as(u32, row) * cell_h;
    const h = cell_h;
    if (self.dirty_h == 0) {
        self.dirty_y = y;
        self.dirty_h = h;
        return;
    }
    const y1 = @max(self.dirty_y + self.dirty_h, y + h);
    const y0 = @min(self.dirty_y, y);
    self.dirty_y = y0;
    self.dirty_h = y1 - y0;
}

fn effectiveBg(cell: Term.Cell) Term.Color {
    return if (cell.attrs.inverse) cell.fg else cell.bg;
}

fn effectiveFg(cell: Term.Cell) Term.Color {
    var fg = cell.fg;
    var bg = cell.bg;
    if (cell.attrs.inverse) {
        const tmp = fg;
        fg = bg;
        bg = tmp;
    }
    if (cell.attrs.dim) {
        fg = .{ .r = fg.r / 2, .g = fg.g / 2, .b = fg.b / 2, .a = fg.a };
    }
    return fg;
}

fn paintBg(self: *Frame, line: []const Term.Cell, row: u16, cell_w: u32, cell_h: u32) void {
    paintBgSpan(self, line, row, 0, @intCast(line.len), cell_w, cell_h);
}

fn paintBgSpan(self: *Frame, line: []const Term.Cell, row: u16, col0: u16, col1: u16, cell_w: u32, cell_h: u32) void {
    const y0 = @as(u32, row) * cell_h;
    const last: u16 = @intCast(@min(@as(usize, col1), line.len));
    var c = col0;
    while (c < last) {
        const bg = packColor(effectiveBg(line[c]));
        var n: u16 = 1;
        while (c + n < last and packColor(effectiveBg(line[c + n])) == bg) : (n += 1) {}
        fillRect(self, @as(u32, c) * cell_w, y0, @as(u32, n) * cell_w, cell_h, bg);
        c += n;
    }
}

fn packColor(color: Term.Color) u32 {
    return Frame.pack(color);
}

fn blitLine(
    self: *Frame,
    line: []const Term.Cell,
    row: u16,
    col0: u16,
    col1: u16,
    cell_w: u32,
    cell_h: u32,
    type_ctx: ?*Type.Context,
    size: f32,
    baseline: f32,
    clip: Clip,
) void {
    const y0 = @as(u32, row) * cell_h;
    const last: u16 = @intCast(@min(@as(usize, col1), line.len));
    var c = col0;
    while (c < last) : (c += 1) {
        const cell = line[c];
        if (cell.attrs.hidden or cell.codepoint == 0) continue;
        const fg = packColor(effectiveFg(cell));
        const bg = packColor(effectiveBg(cell));
        const x0 = @as(u32, c) * cell_w;
        if (!(cell.codepoint >= 0x80 and Box.paint(
            self.pixels,
            self.width,
            self.height,
            @intCast(x0),
            @intCast(y0),
            cell_w,
            cell_h,
            fg,
            bg,
            .{ .x0 = clip.x0, .y0 = clip.y0, .x1 = clip.x1, .y1 = clip.y1 },
            cell.codepoint,
            cell.attrs.bold,
        ))) {
            if (type_ctx) |ctx| {
                if (cell.codepoint != ' ') {
                    var g = ctx.peekGlyph(cell.codepoint, size);
                    if (g == null) {
                        g = ctx.ensureGlyph(cell.codepoint, size) catch null;
                    }
                    if (g) |glyph| {
                        const ox: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(x0)) + glyph.bearing_x));
                        const oy: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(y0)) + baseline - glyph.bearing_y));
                        blitGlyph(self, glyph, ctx.atlas.pixels, ctx.atlas.width, ox, oy, fg, bg, clip);
                    }
                }
            } else if (clip.y0 <= @as(i32, @intCast(y0)) and clip.y1 >= @as(i32, @intCast(y0 + cell_h))) {
                var y: u32 = 0;
                while (y < cell_h) : (y += 1) {
                    var x: u32 = 0;
                    while (x < cell_w) : (x += 1) {
                        const filled = cell.codepoint != ' ' and
                            x > 0 and y > 0 and
                            x + 1 < cell_w and y + 1 < cell_h;
                        if (filled) self.pixels[(y0 + y) * self.width + (x0 + x)] = fg;
                    }
                }
            }
        }
        if ((cell.attrs.underline or cell.attrs.link) and clip.y0 <= @as(i32, @intCast(y0)) and clip.y1 >= @as(i32, @intCast(y0 + cell_h))) {
            const uy = y0 + cell_h -| 2;
            var x: u32 = 0;
            while (x < cell_w) : (x += 1) {
                self.pixels[uy * self.width + (x0 + x)] = fg;
            }
        }
    }
}

fn blitKitty(self: *Frame, screen: *const Term.Screen, cell_w: u32, cell_h: u32) void {
    const store = &screen.kitty;
    if (store.placements.items.len == 0) return;
    for (store.placements.items) |p| {
        if (p.screen != @as(u1, if (screen.altScreen()) 1 else 0)) continue;
        const img = store.find(p.image_id) orelse continue;
        const dest_w: u32 = if (p.columns != 0) p.columns * cell_w else img.width;
        const dest_h: u32 = if (p.rows != 0) p.rows * cell_h else img.height;
        const dx: i32 = p.col * @as(i32, @intCast(cell_w));
        const dy: i32 = p.row * @as(i32, @intCast(cell_h));
        const src_x = @min(p.src_x, img.width);
        const src_y = @min(p.src_y, img.height);
        const crop_w: u32 = if (p.src_w == 0) img.width - src_x else @min(p.src_w, img.width - src_x);
        const crop_h: u32 = if (p.src_h == 0) img.height - src_y else @min(p.src_h, img.height - src_y);
        blitRgba(self, img.rgba, img.width, img.height, src_x, src_y, crop_w, crop_h, dx, dy, dest_w, dest_h);
    }
}

fn blitRgba(
    self: *Frame,
    rgba: []const u8,
    stride_w: u32,
    stride_h: u32,
    src_x: u32,
    src_y: u32,
    src_w: u32,
    src_h: u32,
    dest_x: i32,
    dest_y: i32,
    dest_w: u32,
    dest_h: u32,
) void {
    _ = stride_h;
    if (src_w == 0 or src_h == 0 or dest_w == 0 or dest_h == 0) return;
    var y: u32 = 0;
    while (y < dest_h) : (y += 1) {
        const py = dest_y + @as(i32, @intCast(y));
        if (py < 0 or py >= self.height) continue;
        const sy = src_y + y * src_h / dest_h;
        var x: u32 = 0;
        while (x < dest_w) : (x += 1) {
            const px = dest_x + @as(i32, @intCast(x));
            if (px < 0 or px >= self.width) continue;
            const sx = src_x + x * src_w / dest_w;
            const si = (@as(usize, sy) * stride_w + sx) * 4;
            const a = rgba[si + 3];
            if (a == 0) continue;
            const di = @as(usize, @intCast(py)) * self.width + @as(usize, @intCast(px));
            if (a == 255) {
                self.pixels[di] = (@as(u32, 255) << 24) |
                    (@as(u32, rgba[si]) << 16) |
                    (@as(u32, rgba[si + 1]) << 8) |
                    rgba[si + 2];
            } else {
                self.pixels[di] = mix(
                    self.pixels[di],
                    (@as(u32, 255) << 24) |
                        (@as(u32, rgba[si]) << 16) |
                        (@as(u32, rgba[si + 1]) << 8) |
                        rgba[si + 2],
                    a,
                );
            }
        }
    }
}

fn nowNs() i128 {
    return @intCast(std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds);
}

fn paintCursor(self: *Frame, col: u16, row: u16, cell_w: u32, cell_h: u32, style: Term.CursorStyle) void {
    const x0 = @as(u32, col) * cell_w;
    const y0 = @as(u32, row) * cell_h;
    switch (style) {
        .block => invertRect(self, x0, y0, cell_w, cell_h),
        .underline => {
            const h = @max(1, @min(2, cell_h));
            invertRect(self, x0, y0 + cell_h - h, cell_w, h);
        },
        .bar => {
            const w = @max(1, @min(2, cell_w));
            invertRect(self, x0, y0, w, cell_h);
        },
    }
}

fn invertRect(self: *Frame, x0: u32, y0: u32, w: u32, h: u32) void {
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i = (y0 + y) * self.width + (x0 + x);
            const p = self.pixels[i];
            const a = p >> 24;
            const r = 255 - ((p >> 16) & 0xff);
            const g = 255 - ((p >> 8) & 0xff);
            const b = 255 - (p & 0xff);
            self.pixels[i] = (a << 24) | (r << 16) | (g << 8) | b;
        }
    }
}

fn fillRect(self: *Frame, x0: u32, y0: u32, w: u32, h: u32, color: u32) void {
    if (w == self.width and x0 == 0) {
        const start = y0 * self.width;
        @memset(self.pixels[start .. start + h * self.width], color);
        return;
    }
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const row = self.pixels[(y0 + y) * self.width + x0 ..][0..w];
        @memset(row, color);
    }
}

fn blitGlyph(
    self: *Frame,
    g: Type.Glyph,
    atlas: []const u8,
    atlas_w: u32,
    origin_x: i32,
    origin_y: i32,
    fg: u32,
    bg: u32,
    clip: Clip,
) void {
    if (g.width == 0 or g.height == 0) return;
    var x0 = origin_x;
    var y0 = origin_y;
    var x1 = origin_x + @as(i32, g.width);
    var y1 = origin_y + @as(i32, g.height);
    var src_x: i32 = 0;
    var src_y: i32 = 0;
    if (x0 < clip.x0) {
        src_x += clip.x0 - x0;
        x0 = clip.x0;
    }
    if (y0 < clip.y0) {
        src_y += clip.y0 - y0;
        y0 = clip.y0;
    }
    if (x1 > clip.x1) x1 = clip.x1;
    if (y1 > clip.y1) y1 = clip.y1;
    if (x0 >= x1 or y0 >= y1) return;
    const dst_w: u32 = @intCast(x1 - x0);
    const dst_h: u32 = @intCast(y1 - y0);
    const ax = @as(u32, g.atlas_x) + @as(u32, @intCast(src_x));
    const ay = @as(u32, g.atlas_y) + @as(u32, @intCast(src_y));
    const dst_y: u32 = @intCast(y0);
    const dst_x: u32 = @intCast(x0);
    var row: u32 = 0;
    if (dst_w == vec_len) {
        const Cover = @Vector(vec_len, u8);
        const Pix = @Vector(vec_len, u32);
        const fg_v: Pix = @splat(fg);
        const bg_v: Pix = @splat(bg);
        const zero_c: Cover = @splat(0);
        const full_c: Cover = @splat(255);
        while (row < dst_h) : (row += 1) {
            const atlas_row = atlas[@as(usize, ay + row) * atlas_w + ax ..][0..vec_len];
            const pix_row = self.pixels[@as(usize, dst_y + row) * self.width + dst_x ..][0..vec_len];
            const cover: Cover = atlas_row.*;
            const is_zero = cover == zero_c;
            if (@reduce(.And, is_zero)) continue;
            const is_full = cover == full_c;
            if (@reduce(.And, is_full)) {
                pix_row.* = @as([vec_len]u32, fg_v);
                continue;
            }
            const dest: Pix = pix_row.*;
            var out = mixVec(bg_v, fg_v, cover);
            out = @select(u32, is_full, fg_v, out);
            out = @select(u32, is_zero, dest, out);
            pix_row.* = @as([vec_len]u32, out);
        }
        return;
    }
    while (row < dst_h) : (row += 1) {
        const atlas_row = atlas[@as(usize, ay + row) * atlas_w + ax ..][0..dst_w];
        const pix_row = self.pixels[@as(usize, dst_y + row) * self.width + dst_x ..][0..dst_w];
        var col: u32 = 0;
        if (dst_w >= vec_len) {
            const Cover = @Vector(vec_len, u8);
            const Pix = @Vector(vec_len, u32);
            const fg_v: Pix = @splat(fg);
            const bg_v: Pix = @splat(bg);
            const zero_c: Cover = @splat(0);
            const full_c: Cover = @splat(255);
            while (col + vec_len <= dst_w) : (col += vec_len) {
                const cover: Cover = atlas_row[col..][0..vec_len].*;
                const is_zero = cover == zero_c;
                if (@reduce(.And, is_zero)) continue;
                const is_full = cover == full_c;
                if (@reduce(.And, is_full)) {
                    pix_row[col..][0..vec_len].* = @as([vec_len]u32, fg_v);
                    continue;
                }
                const dest: Pix = pix_row[col..][0..vec_len].*;
                var out = mixVec(bg_v, fg_v, cover);
                out = @select(u32, is_full, fg_v, out);
                out = @select(u32, is_zero, dest, out);
                pix_row[col..][0..vec_len].* = @as([vec_len]u32, out);
            }
        }
        while (col < dst_w) : (col += 1) {
            const cover = atlas_row[col];
            if (cover == 0) continue;
            if (cover == 255) {
                pix_row[col] = fg;
            } else {
                pix_row[col] = mix(bg, fg, cover);
            }
        }
    }
}

inline fn lerpChan(t: u32, fg: u32, bg: u32) u32 {
    return (t * fg + (255 - t) * bg) * 257 >> 16;
}

fn mix(bg: u32, fg: u32, cover: u8) u32 {
    const t: u32 = cover;
    const br = (bg >> 16) & 0xff;
    const bg_ = (bg >> 8) & 0xff;
    const bb = bg & 0xff;
    const ba = (bg >> 24) & 0xff;
    const fr = (fg >> 16) & 0xff;
    const fg_ = (fg >> 8) & 0xff;
    const fb = fg & 0xff;
    return (ba << 24) | (lerpChan(t, fr, br) << 16) | (lerpChan(t, fg_, bg_) << 8) | lerpChan(t, fb, bb);
}

fn mixVec(bg: @Vector(vec_len, u32), fg: @Vector(vec_len, u32), cover: @Vector(vec_len, u8)) @Vector(vec_len, u32) {
    const t: @Vector(vec_len, u32) = @intCast(cover);
    const u = @as(@Vector(vec_len, u32), @splat(255)) - t;
    const ff: @Vector(vec_len, u32) = @splat(0xff);
    const s8: @Vector(vec_len, u5) = @splat(8);
    const s16: @Vector(vec_len, u5) = @splat(16);
    const s24: @Vector(vec_len, u5) = @splat(24);
    const k: @Vector(vec_len, u32) = @splat(257);
    const sh: @Vector(vec_len, u5) = @splat(16);
    const br = (bg >> s16) & ff;
    const bg_ = (bg >> s8) & ff;
    const bb = bg & ff;
    const ba = (bg >> s24) & ff;
    const fr = (fg >> s16) & ff;
    const fg_ = (fg >> s8) & ff;
    const fb = fg & ff;
    const r = (t * fr + u * br) * k >> sh;
    const g = (t * fg_ + u * bg_) * k >> sh;
    const b = (t * fb + u * bb) * k >> sh;
    return (ba << s24) | (r << s16) | (g << s8) | b;
}

test "render fills glyph placeholder" {
    const gpa = std.testing.allocator;
    var screen = try Term.Screen.init(gpa, 1, 1);
    defer screen.deinit();
    const Runs = @import("runs.zig");
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[?25l\x1b[38;2;255;0;0mX";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    var frame = try Frame.init(gpa, 4, 4);
    defer frame.deinit();
    frame.render(&screen, 4, 4, null, 4);
    try std.testing.expectEqual(Frame.pack(.{ .r = 0, .g = 0, .b = 0 }), frame.pixels[0]);
    try std.testing.expectEqual(Frame.pack(.{ .r = 255, .g = 0, .b = 0 }), frame.pixels[1 * 4 + 1]);
}

test "one cell change does not repaint other rows" {
    const gpa = std.testing.allocator;
    var screen = try Term.Screen.init(gpa, 2, 2);
    defer screen.deinit();
    const Runs = @import("runs.zig");
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[?25lAB\nCD";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    var frame = try Frame.init(gpa, 8, 8);
    defer frame.deinit();
    frame.render(&screen, 4, 4, null, 4);
    const bottom = try gpa.dupe(u32, frame.pixels[4 * 8 .. 8 * 8]);
    defer gpa.free(bottom);
    screen.clearDirty();
    runs.clearRetainingCapacity();
    const src2 = "\x1b[1;1HX";
    try Runs.split(gpa, src2, &runs);
    screen.feed(runs.items, src2);
    frame.render(&screen, 4, 4, null, 4);
    try std.testing.expectEqual(@as(u21, 'X'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cell(0, 1).codepoint);
    try std.testing.expectEqualSlices(u32, bottom, frame.pixels[4 * 8 .. 8 * 8]);
}

test "second render skips clean lines" {
    const gpa = std.testing.allocator;
    var screen = try Term.Screen.init(gpa, 2, 2);
    defer screen.deinit();
    const Runs = @import("runs.zig");
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[?25lAB\nCD";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    var frame = try Frame.init(gpa, 8, 8);
    defer frame.deinit();
    frame.render(&screen, 4, 4, null, 4);
    try std.testing.expect(frame.damaged());
    const first = try gpa.dupe(u32, frame.pixels);
    defer gpa.free(first);
    screen.clearDirty();
    frame.render(&screen, 4, 4, null, 4);
    try std.testing.expect(!frame.damaged());
    try std.testing.expectEqualSlices(u32, first, frame.pixels);
}

test "scroll up memmoves pixel strips" {
    const gpa = std.testing.allocator;
    const Runs = @import("runs.zig");
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);

    var screen = try Term.Screen.init(gpa, 2, 2);
    defer screen.deinit();
    const src1 = "\x1b[?25lAA\nBB";
    try Runs.split(gpa, src1, &runs);
    screen.feed(runs.items, src1);
    var frame = try Frame.init(gpa, 8, 8);
    defer frame.deinit();
    frame.render(&screen, 4, 4, null, 4);
    const old_bottom = try gpa.dupe(u32, frame.pixels[4 * 8 .. 8 * 8]);
    defer gpa.free(old_bottom);

    screen.clear();
    runs.clearRetainingCapacity();
    const src2 = "\x1b[?25lBB\nCC";
    try Runs.split(gpa, src2, &runs);
    screen.feed(runs.items, src2);
    frame.render(&screen, 4, 4, null, 4);
    try std.testing.expectEqualSlices(u32, old_bottom, frame.pixels[0..32]);
    try std.testing.expect(frame.dirty_full);
}

test "scroll up does not leave a ghost cursor" {
    const gpa = std.testing.allocator;
    const Runs = @import("runs.zig");
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);

    var screen = try Term.Screen.init(gpa, 2, 2);
    defer screen.deinit();
    const src1 = "A\n";
    try Runs.split(gpa, src1, &runs);
    screen.feed(runs.items, src1);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor().row);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor().col);

    var frame = try Frame.init(gpa, 8, 8);
    defer frame.deinit();
    frame.render(&screen, 4, 4, null, 4);
    const inv: u32 = 0xffffffff;
    const bg: u32 = 0xff000000;
    try std.testing.expectEqual(inv, frame.pixels[32]);

    runs.clearRetainingCapacity();
    const src2 = "\n";
    try Runs.split(gpa, src2, &runs);
    screen.feed(runs.items, src2);
    frame.render(&screen, 4, 4, null, 4);
    try std.testing.expectEqual(bg, frame.pixels[0]);
    try std.testing.expectEqual(inv, frame.pixels[32]);
}

test {
    _ = @import("draw/box.zig");
}

test "lerpChan close to div 255" {
    var t: u32 = 0;
    while (t < 256) : (t += 1) {
        var c: u32 = 0;
        while (c < 256) : (c += 1) {
            const fast = lerpChan(t, c, 0);
            const slow = (t * c) / 255;
            const d = if (fast > slow) fast - slow else slow - fast;
            try std.testing.expect(d <= 1);
        }
    }
}

test "ncmpcpp acs header bars fill the cell" {
    const gpa = std.testing.allocator;
    var screen = try Term.Screen.init(gpa, 3, 1);
    defer screen.deinit();
    const Runs = @import("runs.zig");
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[?25l\x1b[38;2;255;0;0m\x1b(0qtu\x1b(B";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u21, 0x2500), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 0x251C), screen.cell(0, 1).codepoint);
    try std.testing.expectEqual(@as(u21, 0x2524), screen.cell(0, 2).codepoint);
    var frame = try Frame.init(gpa, 24, 8);
    defer frame.deinit();
    frame.render(&screen, 8, 8, null, 8);
    const red = Frame.pack(.{ .r = 255, .g = 0, .b = 0 });
    try std.testing.expectEqual(red, frame.pixels[4 * 24 + 0]);
    try std.testing.expectEqual(red, frame.pixels[4 * 24 + 7]);
    try std.testing.expectEqual(@as(u32, 0xff000000), frame.pixels[0]);
}
