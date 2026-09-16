//! CPU framebuffer.

const std = @import("std");
const assert = std.debug.assert;
const Term = @import("vt.zig");
const Type = @import("type.zig");
const Box = @import("draw/box.zig");
const Select = @import("select.zig");
const Debug = @import("debug.zig");

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
    prev_sel: Select.State = .{},

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
        self.renderSel(screen, cell_w, cell_h, type_ctx, size_px, .{});
    }

    pub fn renderSel(self: *Frame, screen: *const Term.Screen, cell_w: u32, cell_h: u32, type_ctx: ?*Type.Context, size_px: f32, sel: Select.State) void {
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
        const overlay_on = Debug.live and screen.debug_overlay.any();
        const paint_all = rows > paint_buf.len or overlay_on;
        var r: u16 = 0;
        while (r < rows) : (r += 1) {
            const cursor_row = mustPaintCursorRow(r, self.prev_cursor, self.prev_cursor_on, cur, cur_on) or
                (style_changed and (r == cur.row or r == self.prev_cursor.row)) or
                (scroll != 0 and cur_on and r == cur.row);
            const sel_row = sel.coversRow(r, cols) or self.prev_sel.coversRow(r, cols);
            var need = true;
            if (!paint_all and !cursor_row and !sel_row) {
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
            fillRun(self, screen, run.start, run.end, cell_w, cell_h, sel);
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
                blitLine(self, screen, line, rr, 0, @intCast(line.len), cell_w, cell_h, type_ctx, size, baseline, clip, sel);
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
        if (overlay_on) {
            paintDebugOverlay(self, screen, cell_w, cell_h, cur);
            self.dirty_full = true;
            self.dirty_y = 0;
            self.dirty_h = self.height;
        }
        self.last_fill_ns = fill_ns;
        self.last_glyph_ns = glyph_ns;
        self.prev_cursor = cur;
        self.prev_cursor_on = cur_on;
        self.prev_cursor_style = style;
        self.prev_sel = sel;
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
        self.prev_sel = .{};
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
    sel: Select.State,
) void {
    const y0 = @as(u32, start) * cell_h;
    const uniform = if (sel.overlapsRows(start, end, screen.cols)) null else runUniformBg(screen, start, end);
    if (uniform) |bg| {
        fillRect(self, 0, y0, self.width, @as(u32, end - start) * cell_h, bg);
    } else {
        var rr: u16 = start;
        while (rr < end) : (rr += 1) {
            paintBg(self, screen, screen.rowCells(rr), rr, cell_w, cell_h, sel, screen.cols);
        }
    }
    var rr: u16 = start;
    while (rr < end) : (rr += 1) markDirtyStrip(self, rr, cell_h);
}

fn runUniformBg(screen: *const Term.Screen, start: u16, end: u16) ?u32 {
    if (start >= end) return null;
    const first = screen.rowCells(start);
    if (first.len == 0) return null;
    const rev = screen.flags.reverse;
    const bg = packColor(effectiveBg(first[0], rev));
    var r = start;
    while (r < end) : (r += 1) {
        for (screen.rowCells(r)) |cell| {
            if (packColor(effectiveBg(cell, rev)) != bg) return null;
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

fn effectiveBg(cell: Term.Cell, reverse: bool) Term.Color {
    const inv = cell.attrs.inverse != reverse;
    return if (inv) cell.fg else cell.bg;
}

fn effectiveFg(cell: Term.Cell, reverse: bool) Term.Color {
    var fg = cell.fg;
    var bg = cell.bg;
    if (cell.attrs.inverse != reverse) {
        const tmp = fg;
        fg = bg;
        bg = tmp;
    }
    if (cell.attrs.dim) {
        fg = .{ .r = fg.r / 2, .g = fg.g / 2, .b = fg.b / 2, .a = fg.a };
    }
    return fg;
}

fn paintBg(self: *Frame, screen: *const Term.Screen, line: []const Term.Cell, row: u16, cell_w: u32, cell_h: u32, sel: Select.State, cols: u16) void {
    paintBgSpan(self, screen, line, row, 0, @intCast(line.len), cell_w, cell_h, sel, cols);
}

fn paintBgSpan(self: *Frame, screen: *const Term.Screen, line: []const Term.Cell, row: u16, col0: u16, col1: u16, cell_w: u32, cell_h: u32, sel: Select.State, cols: u16) void {
    const y0 = @as(u32, row) * cell_h;
    const last: u16 = @intCast(@min(@as(usize, col1), line.len));
    var c = col0;
    while (c < last) {
        const bg = packColor(paintColors(screen, line[c], sel.contains(c, row, cols)).bg);
        var n: u16 = 1;
        while (c + n < last and packColor(paintColors(screen, line[c + n], sel.contains(c + n, row, cols)).bg) == bg) : (n += 1) {}
        fillRect(self, @as(u32, c) * cell_w, y0, @as(u32, n) * cell_w, cell_h, bg);
        c += n;
    }
}

fn paintColors(screen: *const Term.Screen, cell: Term.Cell, selected: bool) struct { fg: Term.Color, bg: Term.Color } {
    const rev = screen.flags.reverse;
    var fg = effectiveFg(cell, rev);
    var bg = effectiveBg(cell, rev);
    if (selected) {
        if (screen.have_sel_fg or screen.have_sel_bg) {
            if (screen.have_sel_fg) fg = screen.sel_fg;
            if (screen.have_sel_bg) bg = screen.sel_bg;
        } else {
            const tmp = fg;
            fg = bg;
            bg = tmp;
        }
    }
    return .{ .fg = fg, .bg = bg };
}

fn packColor(color: Term.Color) u32 {
    return Frame.pack(color);
}

fn blitLine(
    self: *Frame,
    screen: *const Term.Screen,
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
    sel: Select.State,
) void {
    const y0 = @as(u32, row) * cell_h;
    const last: u16 = @intCast(@min(@as(usize, col1), line.len));
    var c = col0;
    while (c < last) : (c += 1) {
        const cell = line[c];
        if (cell.attrs.hidden or cell.codepoint < 0x20 or cell.codepoint == 0x7F) continue;
        const painted = paintColors(screen, cell, sel.contains(c, row, @intCast(line.len)));
        const fg = packColor(painted.fg);
        const bg = packColor(painted.bg);
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
                    const st = Type.Style{ .bold = cell.attrs.bold, .italic = cell.attrs.italic };
                    var g = ctx.peekGlyphStyled(cell.codepoint, size, st);
                    if (g == null) {
                        g = ctx.ensureGlyphStyled(cell.codepoint, size, st) catch null;
                    }
                    if (g) |glyph| {
                        const ox: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(x0)) + glyph.bearing_x));
                        const oy: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(y0)) + baseline - glyph.bearing_y));
                        if (glyph.color) {
                            blitColorGlyph(self, glyph, ctx.color_atlas.pixels, ctx.color_atlas.width, ox, oy, clip);
                        } else {
                            blitGlyph(self, glyph, ctx.atlas.pixels, ctx.atlas.width, ox, oy, fg, bg, clip);
                        }
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
            const ul = if (cell.attrs.ul_color)
                packColor(.{ .r = cell.ul.r, .g = cell.ul.g, .b = cell.ul.b, .a = 255 })
            else
                fg;
            const style: u3 = if (cell.attrs.underline_style != 0) cell.attrs.underline_style else 1;
            drawUnderline(self, x0, y0, cell_w, cell_h, ul, style);
        }
    }
}

fn drawUnderline(self: *Frame, x0: u32, y0: u32, cell_w: u32, cell_h: u32, color: u32, style: u3) void {
    const y_base = y0 + cell_h -| 2;
    var x: u32 = 0;
    switch (style) {
        2 => { // double
            const y2 = y0 + cell_h -| 4;
            while (x < cell_w) : (x += 1) {
                self.pixels[y_base * self.width + (x0 + x)] = color;
                if (y2 >= y0) self.pixels[y2 * self.width + (x0 + x)] = color;
            }
        },
        3 => { // curly
            while (x < cell_w) : (x += 1) {
                const wave: u32 = if ((x / 2) % 2 == 0) 0 else 1;
                const uy = y_base -| wave;
                self.pixels[uy * self.width + (x0 + x)] = color;
            }
        },
        4 => { // dotted
            while (x < cell_w) : (x += 1) {
                if (x % 2 == 0) self.pixels[y_base * self.width + (x0 + x)] = color;
            }
        },
        5 => { // dashed
            while (x < cell_w) : (x += 1) {
                if (x % 6 < 4) self.pixels[y_base * self.width + (x0 + x)] = color;
            }
        },
        else => {
            while (x < cell_w) : (x += 1) {
                self.pixels[y_base * self.width + (x0 + x)] = color;
            }
        },
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

fn paintDebugOverlay(self: *Frame, screen: *const Term.Screen, cell_w: u32, cell_h: u32, cur: Term.Cursor) void {
    if (!Debug.live) return;
    const ov = screen.debug_overlay;
    if (!ov.any()) return;
    const g = screen.gridConst();
    const w = self.width;
    const h = self.height;
    const pix = self.pixels;
    const cols = screen.cols;
    const rows = screen.rows;
    const cw: i32 = @intCast(cell_w);
    const ch: i32 = @intCast(cell_h);

    var dirty_n: u16 = 0;
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        const y0: i32 = @as(i32, r) * ch;
        const y1 = y0 + ch;
        if (screen.lineDirty(r)) dirty_n += 1;
        if (ov.dirty and screen.lineDirty(r)) {
            const bar = @max(1, @min(2, cw));
            Debug.fill(pix, w, h, 0, y0, bar, ch, Debug.col_dirty);
        }
        if (ov.wrap and g.viewRowWrapped(r)) {
            const bar = @max(1, @min(2, cw));
            Debug.fill(pix, w, h, @as(i32, cols) * cw - bar, y0, bar, ch, Debug.col_wrap);
        }
        if (ov.grid) {
            Debug.hline(pix, w, h, 0, @intCast(w), y1 - 1, Debug.col_grid);
        }
        if (ov.wide) {
            const line = screen.rowCells(r);
            var c: u16 = 0;
            while (c < cols) : (c += 1) {
                const trail = line[c].codepoint == 0;
                const lead = c + 1 < cols and line[c].codepoint != 0 and line[c].codepoint != ' ' and line[c + 1].codepoint == 0;
                if (!trail and !lead) continue;
                const x0: i32 = @as(i32, c) * cw;
                Debug.hline(pix, w, h, x0, x0 + cw, y0, Debug.col_wide);
                if (ch > 1) Debug.hline(pix, w, h, x0, x0 + cw, y0 + 1, Debug.col_wide);
            }
        }
    }
    if (ov.grid) {
        var c: u16 = 1;
        while (c < cols) : (c += 1) {
            Debug.vline(pix, w, h, @as(i32, c) * cw, 0, @intCast(h), Debug.col_grid);
        }
    }
    if (ov.region) {
        const top: i32 = @as(i32, g.scroll_top) * ch;
        const bot: i32 = (@as(i32, g.scroll_bottom) + 1) * ch;
        Debug.hline(pix, w, h, 0, @intCast(w), top, Debug.col_region);
        Debug.hline(pix, w, h, 0, @intCast(w), bot - 1, Debug.col_region);
    }
    if (ov.cursor) {
        Debug.rect(pix, w, h, @as(i32, cur.col) * cw, @as(i32, cur.row) * ch, cw, ch, Debug.col_cursor);
    }
    if (ov.lcf and g.wrap_pending) {
        Debug.rect(pix, w, h, @as(i32, cur.col) * cw, @as(i32, cur.row) * ch, cw, ch, Debug.col_lcf);
    }
    if (ov.hud and h >= 8 and w >= 24) {
        var buf: [120]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d},{d}{s}{s}{s}{s}{s} {s} s{d} {d}-{d} D{d} o{d}{s}{s}", .{
            cur.row,
            cur.col,
            if (g.wrap_pending) " LCF" else "",
            if (screen.flags.auto_wrap) " W" else "",
            if (screen.flags.insert_mode) " I" else "",
            if (screen.which == 1) " ALT" else "",
            if (screen.flags.reverse) " REV" else "",
            @tagName(screen.mouse),
            screen.scrollOffset(),
            g.scroll_top,
            g.scroll_bottom,
            dirty_n,
            screen.debug_osc_id,
            if (screen.flags.sync_output) " SYNC" else "",
            if (screen.notify_pending) " NTF" else "",
        }) catch buf[0..0];
        const tw = Debug.textWidth(text);
        const pad: i32 = 2;
        Debug.fill(pix, w, h, 1, 1, tw + pad * 2, 5 + pad * 2, Debug.col_hud_bg);
        Debug.text(pix, w, h, 1 + pad, 1 + pad, text, Debug.col_hud_fg);
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

fn blitColorGlyph(
    self: *Frame,
    g: Type.Glyph,
    atlas: []const u32,
    atlas_w: u32,
    origin_x: i32,
    origin_y: i32,
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
    while (row < dst_h) : (row += 1) {
        const atlas_row = atlas[@as(usize, ay + row) * atlas_w + ax ..][0..dst_w];
        const pix_row = self.pixels[@as(usize, dst_y + row) * self.width + dst_x ..][0..dst_w];
        var col: u32 = 0;
        while (col < dst_w) : (col += 1) {
            const px = atlas_row[col];
            const a: u8 = @intCast(px >> 24);
            if (a == 0) continue;
            if (a == 255) {
                pix_row[col] = px | 0xff000000;
            } else {
                pix_row[col] = mix(pix_row[col], px | 0xff000000, a);
            }
        }
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

test "debug overlay paints grid" {
    if (!Debug.live) return;
    const gpa = std.testing.allocator;
    var dummy: [1]u8 = .{0};
    var vt = try Term.VtState.init(gpa, 4, 2, 2, &dummy);
    defer vt.deinit();
    vt.debug_overlay = .{ .grid = true };
    var frame = try Frame.init(gpa, 4 * 8, 2 * 8);
    defer frame.deinit();
    frame.render(&vt, 8, 8, null, 8);
    var found = false;
    for (frame.pixels) |px| {
        if (px == Debug.col_grid) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
