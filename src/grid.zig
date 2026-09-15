const std = @import("std");
const assert = std.debug.assert;

pub const Color = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const default_fg: Color = .{ .r = 170, .g = 170, .b = 170 };
    pub const default_bg: Color = .{ .r = 0, .g = 0, .b = 0 };
};

pub const vga_palette = [_]Color{
    .{ .r = 0, .g = 0, .b = 0 },       .{ .r = 170, .g = 0, .b = 0 },
    .{ .r = 0, .g = 170, .b = 0 },     .{ .r = 170, .g = 85, .b = 0 },
    .{ .r = 0, .g = 0, .b = 170 },     .{ .r = 170, .g = 0, .b = 170 },
    .{ .r = 0, .g = 170, .b = 170 },   .{ .r = 170, .g = 170, .b = 170 },
    .{ .r = 85, .g = 85, .b = 85 },    .{ .r = 255, .g = 85, .b = 85 },
    .{ .r = 85, .g = 255, .b = 85 },   .{ .r = 255, .g = 255, .b = 85 },
    .{ .r = 85, .g = 85, .b = 255 },   .{ .r = 255, .g = 85, .b = 255 },
    .{ .r = 85, .g = 255, .b = 255 },  .{ .r = 255, .g = 255, .b = 255 },
};

pub const Scheme = struct {
    fg: Color = Color.default_fg,
    bg: Color = Color.default_bg,
    cursor: Color = Color.default_fg,
    palette: [16]Color = vga_palette,
};

pub const Attrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
    blink: bool = false,
    link: bool = false,
    /// 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed (foot SGR 4:n).
    underline_style: u3 = 0,
    _padding: u4 = 0,
};

pub const Cell = packed struct {
    codepoint: u21 = ' ',
    attrs: Attrs = .{},
    _pad: u2 = 0,
    fg: Color = Color.default_fg,
    bg: Color = Color.default_bg,
};

pub const Cursor = struct { row: u16 = 0, col: u16 = 0 };

pub const Grid = struct {
    cells: []Cell,
    starts: []u32,
    /// 1 if this ring row continues onto the next (DECAWM soft wrap).
    wraps: []u8,
    cap: u32,
    head: u32 = 0,
    used: u32,
    scroll: u32 = 0,
    cursor: Cursor = .{},
    /// Last-column flag (DECAWM delayed wrap). Cursor stays on the last cell.
    wrap_pending: bool = false,
    fg: Color = Color.default_fg,
    bg: Color = Color.default_bg,
    attrs: Attrs = .{},
    saved_cursor: Cursor = .{},
    saved_wrap_pending: bool = false,
    saved_fg: Color = Color.default_fg,
    saved_bg: Color = Color.default_bg,
    saved_attrs: Attrs = .{},
    scroll_top: u16 = 0,
    scroll_bottom: u16,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, cap: u32) !Grid {
        const total = @as(usize, cols) * cap;
        const cells = try allocator.alloc(Cell, total);
        errdefer allocator.free(cells);
        @memset(cells, Cell{});

        const starts = try allocator.alloc(u32, cap);
        errdefer allocator.free(starts);
        for (starts, 0..) |*s, i| {
            s.* = @intCast(i * cols);
        }

        const wraps = try allocator.alloc(u8, cap);
        errdefer allocator.free(wraps);
        @memset(wraps, 0);

        return Grid{
            .cells = cells,
            .starts = starts,
            .wraps = wraps,
            .cap = cap,
            .used = rows,
            .scroll_bottom = rows -| 1,
        };
    }

    pub fn deinit(self: *Grid, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.starts);
        allocator.free(self.wraps);
    }

    pub fn setRowWrap(self: *Grid, row: u16, wrapped: bool) void {
        self.wraps[(self.head + row) % self.cap] = if (wrapped) 1 else 0;
    }

    /// Compact the ring onto a new cell buffer. Scrollback is kept.
    /// When `reflow` is set and the column count changes, soft-wrapped rows
    /// are joined and re-broken at `new_cols` (primary screen). Alt screen
    /// should pass `reflow=false` so TUIs can redraw.
    pub fn resize(
        self: *Grid,
        allocator: std.mem.Allocator,
        old_cols: u16,
        old_rows: u16,
        new_cols: u16,
        new_rows: u16,
        min_cap: u32,
        reflow: bool,
    ) std.mem.Allocator.Error!void {
        assert(new_cols > 0 and new_rows > 0);
        if (reflow and new_cols != old_cols) {
            try self.resizeReflow(allocator, old_cols, old_rows, new_cols, new_rows, min_cap);
            return;
        }
        try self.resizeClip(allocator, old_cols, old_rows, new_cols, new_rows, min_cap);
    }

    fn resizeClip(
        self: *Grid,
        allocator: std.mem.Allocator,
        old_cols: u16,
        old_rows: u16,
        new_cols: u16,
        new_rows: u16,
        min_cap: u32,
    ) std.mem.Allocator.Error!void {
        const hist = self.used -| @as(u32, old_rows);
        const keep_screen = @min(@as(u32, old_rows), @as(u32, new_rows));
        const new_cap = @max(min_cap, hist + new_rows);

        const new_cells = try allocator.alloc(Cell, @as(usize, new_cols) * new_cap);
        errdefer allocator.free(new_cells);
        const blank = Cell{ .fg = self.fg, .bg = self.bg, .codepoint = ' ' };
        @memset(new_cells, blank);

        const new_starts = try allocator.alloc(u32, new_cap);
        errdefer allocator.free(new_starts);
        for (new_starts, 0..) |*s, i| s.* = @intCast(i * @as(u32, new_cols));

        const new_wraps = try allocator.alloc(u8, new_cap);
        errdefer allocator.free(new_wraps);
        @memset(new_wraps, 0);

        const copy_cols = @min(old_cols, new_cols);
        const oldest = (self.head + self.cap - hist) % self.cap;
        var n: u32 = 0;
        while (n < hist + keep_screen) : (n += 1) {
            const src_idx = (oldest + n) % self.cap;
            const src_off = self.starts[src_idx];
            const dst_off = new_starts[n];
            @memcpy(
                new_cells[dst_off .. dst_off + copy_cols],
                self.cells[src_off .. src_off + copy_cols],
            );
            new_wraps[n] = self.wraps[src_idx];
        }

        allocator.free(self.cells);
        allocator.free(self.starts);
        allocator.free(self.wraps);
        self.cells = new_cells;
        self.starts = new_starts;
        self.wraps = new_wraps;
        self.cap = new_cap;
        self.head = hist;
        self.used = hist + new_rows;
        self.scroll = @min(self.scroll, hist);
        self.clampCursors(new_cols, new_rows, old_rows);
    }

    fn resizeReflow(
        self: *Grid,
        allocator: std.mem.Allocator,
        old_cols: u16,
        old_rows: u16,
        new_cols: u16,
        new_rows: u16,
        min_cap: u32,
    ) std.mem.Allocator.Error!void {
        const hist = self.used -| @as(u32, old_rows);
        const old_total = hist + @as(u32, old_rows);
        const oldest = (self.head + self.cap - hist) % self.cap;
        const blank = Cell{ .fg = self.fg, .bg = self.bg, .codepoint = ' ' };
        const cur_abs = hist + @as(u32, self.cursor.row);
        const cur_col = self.cursor.col;

        var out_cells: std.ArrayList(Cell) = .empty;
        defer out_cells.deinit(allocator);
        var out_wraps: std.ArrayList(u8) = .empty;
        defer out_wraps.deinit(allocator);
        var logical: std.ArrayList(Cell) = .empty;
        defer logical.deinit(allocator);

        var new_cur_row: u32 = 0;
        var new_cur_col: u16 = @min(cur_col, new_cols - 1);
        var mapped_cursor = false;

        var i: u32 = 0;
        while (i < old_total) {
            logical.clearRetainingCapacity();
            const log_start = i;
            while (true) {
                const src_idx = (oldest + i) % self.cap;
                const src = self.cells[self.starts[src_idx] .. self.starts[src_idx] + old_cols];
                const wrapped = self.wraps[src_idx] != 0 and i + 1 < old_total;
                const take = if (wrapped) old_cols else rowContentLen(src);
                try logical.appendSlice(allocator, src[0..take]);
                if (!wrapped) break;
                i += 1;
            }
            const log_end = i;
            const before_rows: u32 = @intCast(out_wraps.items.len);
            try wrapLogical(
                allocator,
                &out_cells,
                &out_wraps,
                logical.items,
                new_cols,
                blank,
            );
            if (!mapped_cursor and cur_abs >= log_start and cur_abs <= log_end) {
                const offset = cursorOffsetInLogical(
                    self,
                    oldest,
                    old_cols,
                    log_start,
                    cur_abs,
                    cur_col,
                );
                mapCursor(offset, new_cols, before_rows, &new_cur_row, &new_cur_col);
                mapped_cursor = true;
            }
            i += 1;
        }

        var out_rows: u32 = @intCast(out_wraps.items.len);
        const cur_line: u32 = if (mapped_cursor) new_cur_row else out_rows -| 1;
        while (out_rows > new_rows and out_rows > cur_line + 1) {
            const last = out_rows - 1;
            const off = last * @as(u32, new_cols);
            if (rowContentLen(out_cells.items[off .. off + new_cols]) != 0) break;
            out_rows = last;
        }
        if (out_rows < new_rows) {
            var pad = out_rows;
            while (pad < new_rows) : (pad += 1) {
                var c: u16 = 0;
                while (c < new_cols) : (c += 1) try out_cells.append(allocator, blank);
                try out_wraps.append(allocator, 0);
            }
            out_rows = new_rows;
        }

        var view_top = out_rows -| @as(u32, new_rows);
        if (mapped_cursor and new_cur_row < view_top) view_top = new_cur_row;
        if (mapped_cursor and new_cur_row >= view_top + new_rows) {
            view_top = new_cur_row + 1 - new_rows;
        }

        const new_cap = @max(min_cap, out_rows);
        const new_cells = try allocator.alloc(Cell, @as(usize, new_cols) * new_cap);
        errdefer allocator.free(new_cells);
        @memset(new_cells, blank);
        const new_starts = try allocator.alloc(u32, new_cap);
        errdefer allocator.free(new_starts);
        for (new_starts, 0..) |*s, k| s.* = @intCast(k * @as(u32, new_cols));
        const new_wraps = try allocator.alloc(u8, new_cap);
        errdefer allocator.free(new_wraps);
        @memset(new_wraps, 0);

        const drop = out_rows -| new_cap;
        const keep = out_rows - drop;
        var n: u32 = 0;
        while (n < keep) : (n += 1) {
            const src_row = drop + n;
            const src_off = src_row * @as(u32, new_cols);
            const dst_off = new_starts[n];
            @memcpy(
                new_cells[dst_off .. dst_off + new_cols],
                out_cells.items[src_off .. src_off + new_cols],
            );
            new_wraps[n] = out_wraps.items[src_row];
        }

        allocator.free(self.cells);
        allocator.free(self.starts);
        allocator.free(self.wraps);
        self.cells = new_cells;
        self.starts = new_starts;
        self.wraps = new_wraps;
        self.cap = new_cap;
        const view = @min(view_top -| drop, keep -| @as(u32, new_rows));
        self.head = view;
        self.used = view + new_rows;
        self.scroll = 0;
        if (mapped_cursor) {
            const abs = new_cur_row -| drop;
            if (abs >= view) {
                self.cursor.row = @intCast(@min(abs - view, @as(u32, new_rows - 1)));
            } else {
                self.cursor.row = 0;
            }
            self.cursor.col = @min(new_cur_col, new_cols - 1);
        } else {
            self.cursor.row = @min(self.cursor.row, new_rows - 1);
            self.cursor.col = @min(self.cursor.col, new_cols - 1);
        }
        self.wrap_pending = false;
        self.saved_cursor.row = @min(self.saved_cursor.row, new_rows - 1);
        self.saved_cursor.col = @min(self.saved_cursor.col, new_cols - 1);
        self.saved_wrap_pending = false;
        self.clampScrollRegion(old_rows, new_rows);
    }

    fn clampCursors(self: *Grid, new_cols: u16, new_rows: u16, old_rows: u16) void {
        self.cursor.row = @min(self.cursor.row, new_rows - 1);
        self.cursor.col = @min(self.cursor.col, new_cols - 1);
        self.wrap_pending = false;
        self.saved_cursor.row = @min(self.saved_cursor.row, new_rows - 1);
        self.saved_cursor.col = @min(self.saved_cursor.col, new_cols - 1);
        self.saved_wrap_pending = false;
        self.clampScrollRegion(old_rows, new_rows);
    }

    fn clampScrollRegion(self: *Grid, old_rows: u16, new_rows: u16) void {
        if (self.scroll_top == 0 and self.scroll_bottom + 1 == old_rows) {
            self.scroll_bottom = new_rows - 1;
        } else {
            if (self.scroll_top >= new_rows) self.scroll_top = 0;
            if (self.scroll_bottom >= new_rows) self.scroll_bottom = new_rows - 1;
            if (self.scroll_top > self.scroll_bottom) {
                self.scroll_top = 0;
                self.scroll_bottom = new_rows - 1;
            }
        }
    }

    pub fn reset(self: *Grid, cols: u16, rows: u16, scheme: Scheme) void {
        @memset(self.cells, Cell{ .fg = scheme.fg, .bg = scheme.bg });
        for (self.starts, 0..) |*s, i| {
            s.* = @intCast(i * cols);
        }
        @memset(self.wraps, 0);
        self.head = 0;
        self.used = rows;
        self.scroll = 0;
        self.cursor = .{};
        self.wrap_pending = false;
        self.fg = scheme.fg;
        self.bg = scheme.bg;
        self.attrs = .{};
        self.saved_cursor = .{};
        self.saved_wrap_pending = false;
        self.saved_fg = scheme.fg;
        self.saved_bg = scheme.bg;
        self.saved_attrs = .{};
        self.scroll_top = 0;
        self.scroll_bottom = rows -| 1;
    }

    pub inline fn getCell(self: *Grid, row: u16, col: u16) *Cell {
        const line_idx = (self.head + row) % self.cap;
        return &self.cells[self.starts[line_idx] + col];
    }

    pub inline fn cellAt(self: *const Grid, row: u16, col: u16) Cell {
        const line_idx = (self.head + row) % self.cap;
        return self.cells[self.starts[line_idx] + col];
    }

    pub inline fn rowSlice(self: *Grid, row: u16, cols: u16) []Cell {
        const line_idx = (self.head + row) % self.cap;
        const off = self.starts[line_idx];
        return self.cells[off .. off + cols];
    }

    pub inline fn rowSliceConst(self: *const Grid, row: u16, cols: u16) []const Cell {
        const line_idx = (self.head + row) % self.cap;
        const off = self.starts[line_idx];
        return self.cells[off .. off + cols];
    }

    pub inline fn viewRowSliceConst(self: *const Grid, row: u16, cols: u16) []const Cell {
        const line_idx = (self.head + self.cap - self.scroll + row) % self.cap;
        const off = self.starts[line_idx];
        return self.cells[off .. off + cols];
    }

    pub inline fn viewCellAt(self: *const Grid, row: u16, col: u16) Cell {
        const line_idx = (self.head + self.cap - self.scroll + row) % self.cap;
        return self.cells[self.starts[line_idx] + col];
    }

    /// Full-grid scroll that keeps the outgoing top line in the ring (primary history).
    pub fn historyScrollUp(self: *Grid, n: u16, cols: u16, rows: u16) void {
        var k: u16 = 0;
        while (k < n) : (k += 1) {
            self.head = (self.head + 1) % self.cap;
            if (self.used < self.cap) self.used += 1;
            if (rows != 0) {
                self.clearRange(rows - 1, 0, cols);
                self.setRowWrap(rows - 1, false);
            }
            if (self.scroll != 0) {
                const max_scroll = self.used -| @as(u32, rows);
                self.scroll = @min(self.scroll + 1, max_scroll);
            }
        }
    }

    pub inline fn blankCell(self: *Grid) Cell {
        return Cell{
            .codepoint = ' ',
            .attrs = .{},
            .fg = self.fg,
            .bg = self.bg,
        };
    }

    /// Primary cell mutation primitive
    pub fn writeCell(self: *Grid, row: u16, col: u16, cp: u21) void {
        const cell = self.getCell(row, col);
        cell.* = .{
            .codepoint = cp,
            .attrs = self.attrs,
            .fg = self.fg,
            .bg = self.bg,
        };
    }

    /// Clear cell range [start_col, end_col) on a given row
    pub fn clearRange(self: *Grid, row: u16, start_col: u16, end_col: u16) void {
        const line_idx = (self.head + row) % self.cap;
        const row_offset = self.starts[line_idx];
        const blank = self.blankCell();
        @memset(self.cells[row_offset + start_col .. row_offset + end_col], blank);
    }

    /// Insert blank characters at row/col, shifting existing cells right
    pub fn insertCells(self: *Grid, row: u16, col: u16, count: u16, cols: u16) void {
        if (col >= cols) return;
        const line_idx = (self.head + row) % self.cap;
        const offset = self.starts[line_idx];
        const shift_count = @min(count, cols - col);
        const copy_len = cols - col - shift_count;

        if (copy_len > 0) {
            std.mem.copyBackwards(
                Cell,
                self.cells[offset + col + shift_count .. offset + cols],
                self.cells[offset + col .. offset + col + copy_len],
            );
        }
        @memset(self.cells[offset + col .. offset + col + shift_count], self.blankCell());
    }

    /// Delete characters at row/col, shifting remaining cells left
    pub fn deleteCells(self: *Grid, row: u16, col: u16, count: u16, cols: u16) void {
        if (col >= cols) return;
        const line_idx = (self.head + row) % self.cap;
        const offset = self.starts[line_idx];
        const del_count = @min(count, cols - col);
        const copy_len = cols - col - del_count;

        if (copy_len > 0) {
            std.mem.copyForwards(
                Cell,
                self.cells[offset + col .. offset + col + copy_len],
                self.cells[offset + col + del_count .. offset + cols],
            );
        }
        @memset(self.cells[offset + cols - del_count .. offset + cols], self.blankCell());
    }

    /// Scroll defined region up by n lines
    pub fn scrollUp(self: *Grid, top: u16, bottom: u16, n: u16, cols: u16) void {
        const count = @min(n, bottom - top + 1);
        var i: u16 = top;
        while (i <= bottom - count) : (i += 1) {
            const src_idx = (self.head + i + count) % self.cap;
            const dst_idx = (self.head + i) % self.cap;
            std.mem.copyForwards(
                Cell,
                self.cells[self.starts[dst_idx] .. self.starts[dst_idx] + cols],
                self.cells[self.starts[src_idx] .. self.starts[src_idx] + cols],
            );
            self.wraps[dst_idx] = self.wraps[src_idx];
        }
        var clear_row: u16 = bottom - count + 1;
        while (clear_row <= bottom) : (clear_row += 1) {
            self.clearRange(clear_row, 0, cols);
            self.setRowWrap(clear_row, false);
        }
    }

    pub fn scrollDown(self: *Grid, top: u16, bottom: u16, n: u16, cols: u16) void {
        const count = @min(n, bottom - top + 1);
        var i: u16 = bottom;
        while (i >= top + count) : (i -= 1) {
            const src_idx = (self.head + i - count) % self.cap;
            const dst_idx = (self.head + i) % self.cap;
            std.mem.copyForwards(
                Cell,
                self.cells[self.starts[dst_idx] .. self.starts[dst_idx] + cols],
                self.cells[self.starts[src_idx] .. self.starts[src_idx] + cols],
            );
            self.wraps[dst_idx] = self.wraps[src_idx];
            if (i == top + count) break;
        }
        var clear_row: u16 = top;
        while (clear_row < top + count) : (clear_row += 1) {
            self.clearRange(clear_row, 0, cols);
            self.setRowWrap(clear_row, false);
        }
    }

    pub fn saveCursor(self: *Grid) void {
        self.saved_cursor = self.cursor;
        self.saved_wrap_pending = self.wrap_pending;
        self.saved_fg = self.fg;
        self.saved_bg = self.bg;
        self.saved_attrs = self.attrs;
    }

    pub fn restoreCursor(self: *Grid) void {
        self.cursor = self.saved_cursor;
        self.wrap_pending = self.saved_wrap_pending;
        self.fg = self.saved_fg;
        self.bg = self.saved_bg;
        self.attrs = self.saved_attrs;
    }
};

fn rowContentLen(row: []const Cell) u16 {
    var n: u16 = @intCast(row.len);
    while (n > 0) {
        const cp = row[n - 1].codepoint;
        if (cp != 0 and cp != ' ') break;
        n -= 1;
    }
    return n;
}

fn wrapLogical(
    allocator: std.mem.Allocator,
    out_cells: *std.ArrayList(Cell),
    out_wraps: *std.ArrayList(u8),
    logical: []const Cell,
    new_cols: u16,
    blank: Cell,
) std.mem.Allocator.Error!void {
    var col: u16 = 0;
    var i: usize = 0;
    if (logical.len == 0) {
        var c: u16 = 0;
        while (c < new_cols) : (c += 1) try out_cells.append(allocator, blank);
        try out_wraps.append(allocator, 0);
        return;
    }
    while (i < logical.len) {
        const cell = logical[i];
        if (cell.codepoint == 0) {
            i += 1;
            continue;
        }
        const wide = i + 1 < logical.len and logical[i + 1].codepoint == 0;
        var width: u16 = if (wide) 2 else 1;
        if (width == 2 and new_cols < 2) width = 1;
        if (col + width > new_cols) {
            while (col < new_cols) : (col += 1) try out_cells.append(allocator, blank);
            try out_wraps.append(allocator, 1);
            col = 0;
        }
        try out_cells.append(allocator, cell);
        col += 1;
        if (width == 2) {
            try out_cells.append(allocator, logical[i + 1]);
            col += 1;
            i += 1;
        }
        i += 1;
    }
    while (col < new_cols) : (col += 1) try out_cells.append(allocator, blank);
    try out_wraps.append(allocator, 0);
}

fn cursorOffsetInLogical(
    grid: *const Grid,
    oldest: u32,
    old_cols: u16,
    log_start: u32,
    cur_abs: u32,
    cur_col: u16,
) u32 {
    var off: u32 = 0;
    var r = log_start;
    while (r < cur_abs) : (r += 1) {
        const src_idx = (oldest + r) % grid.cap;
        const src = grid.cells[grid.starts[src_idx] .. grid.starts[src_idx] + old_cols];
        const wrapped = grid.wraps[src_idx] != 0;
        off += if (wrapped) old_cols else rowContentLen(src);
    }
    const src_idx = (oldest + cur_abs) % grid.cap;
    const src = grid.cells[grid.starts[src_idx] .. grid.starts[src_idx] + old_cols];
    const take = if (grid.wraps[src_idx] != 0) old_cols else rowContentLen(src);
    return off + @min(@as(u32, cur_col), @as(u32, take));
}

fn mapCursor(offset: u32, new_cols: u16, before_rows: u32, row: *u32, col: *u16) void {
    row.* = before_rows + offset / new_cols;
    col.* = @intCast(@min(offset % new_cols, @as(u32, new_cols - 1)));
}

test "reflow keeps glyphs" {
    var g = try Grid.init(std.testing.allocator, 4, 2, 8);
    defer g.deinit(std.testing.allocator);
    g.writeCell(0, 0, 'A');
    g.writeCell(0, 1, 'B');
    try std.testing.expectEqual(@as(u21, 'A'), g.cellAt(0, 0).codepoint);
    try g.resize(std.testing.allocator, 4, 2, 6, 3, 8, true);
    try std.testing.expectEqual(@as(u21, 'A'), g.cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), g.cellAt(0, 1).codepoint);
}
