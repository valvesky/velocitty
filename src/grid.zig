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
    cap: u32,
    head: u32 = 0,
    used: u32,
    scroll: u32 = 0,
    cursor: Cursor = .{},
    fg: Color = Color.default_fg,
    bg: Color = Color.default_bg,
    attrs: Attrs = .{},
    saved_cursor: Cursor = .{},
    saved_fg: Color = Color.default_fg,
    saved_bg: Color = Color.default_bg,
    saved_attrs: Attrs = .{},
    scroll_top: u16 = 0,
    scroll_bottom: u16,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, cap: u32) !Grid {
        const total = @as(usize, cols) * cap;
        const cells = try allocator.alloc(Cell, total);
        @memset(cells, Cell{});

        const starts = try allocator.alloc(u32, cap);
        for (starts, 0..) |*s, i| {
            s.* = @intCast(i * cols);
        }

        return Grid{
            .cells = cells,
            .starts = starts,
            .cap = cap,
            .used = rows,
            .scroll_bottom = rows -| 1,
        };
    }

    pub fn deinit(self: *Grid, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.starts);
    }

    /// Compact the ring onto a new cell buffer. Scrollback is kept; extra columns
    /// and rows are blank. `min_cap` is the smallest ring to allocate (primary
    /// scrollback, or `new_rows` for the alt screen).
    pub fn resize(
        self: *Grid,
        allocator: std.mem.Allocator,
        old_cols: u16,
        old_rows: u16,
        new_cols: u16,
        new_rows: u16,
        min_cap: u32,
    ) std.mem.Allocator.Error!void {
        assert(new_cols > 0 and new_rows > 0);
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
        }

        allocator.free(self.cells);
        allocator.free(self.starts);
        self.cells = new_cells;
        self.starts = new_starts;
        self.cap = new_cap;
        self.head = hist;
        self.used = hist + new_rows;
        self.scroll = @min(self.scroll, hist);
        self.cursor.row = @min(self.cursor.row, new_rows - 1);
        self.cursor.col = @min(self.cursor.col, new_cols - 1);
        self.saved_cursor.row = @min(self.saved_cursor.row, new_rows - 1);
        self.saved_cursor.col = @min(self.saved_cursor.col, new_cols - 1);

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
        self.head = 0;
        self.used = rows;
        self.scroll = 0;
        self.cursor = .{};
        self.fg = scheme.fg;
        self.bg = scheme.bg;
        self.attrs = .{};
        self.saved_cursor = .{};
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
            if (rows != 0) self.clearRange(rows - 1, 0, cols);
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
        }
        var clear_row: u16 = bottom - count + 1;
        while (clear_row <= bottom) : (clear_row += 1) {
            self.clearRange(clear_row, 0, cols);
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
            if (i == top + count) break;
        }
        var clear_row: u16 = top;
        while (clear_row < top + count) : (clear_row += 1) {
            self.clearRange(clear_row, 0, cols);
        }
    }

    pub fn saveCursor(self: *Grid) void {
        self.saved_cursor = self.cursor;
        self.saved_fg = self.fg;
        self.saved_bg = self.bg;
        self.saved_attrs = self.attrs;
    }

    pub fn restoreCursor(self: *Grid) void {
        self.cursor = self.saved_cursor;
        self.fg = self.saved_fg;
        self.bg = self.saved_bg;
        self.attrs = self.saved_attrs;
    }
};
