//! State machine, VT operations, sequence routing, and flags.

const std = @import("std");
const GridMod = @import("grid.zig");
const Kitty = @import("kitty.zig");
const CsiSeq = @import("csi.zig");
const Esc = @import("esc.zig");
const Osc = @import("osc.zig");
const Dcs = @import("dcs.zig");
const C0 = @import("c0.zig");
const C1 = @import("c1.zig");
const EastAsian = @import("type/eastasian.zig");
const Run = @import("circbuffer.zig").Run;

pub const Color = GridMod.Color;
pub const Scheme = GridMod.Scheme;
pub const Attrs = GridMod.Attrs;
pub const Cell = GridMod.Cell;
pub const Cursor = GridMod.Cursor;
pub const Grid = GridMod.Grid;

pub const Mouse = enum {
    off,
    x10,
    btn,
    drag,
    any,
};

pub const CursorStyle = enum(u8) { block, underline, bar };
pub const Charset = enum { ascii, dec_special };
const KITTY_KBD_SUPPORTED: u16 = 0x1F;

pub const ColorSnap = struct {
    fg: Color,
    bg: Color,
    cursor: Color,
    table: [256]Color,
};
/// Alias used by draw/select.
pub const Screen = VtState;

pub const Flags = packed struct {
    origin_mode: bool = false,
    auto_wrap: bool = true,
    insert_mode: bool = false,
    cursor_visible: bool = true,
    cursor_blink: bool = false,
    app_cursor: bool = false,
    app_keypad: bool = false,
    mouse_sgr: bool = false,
    mouse_urxvt: bool = false,
    mouse_pixels: bool = false,
    mouse_hilite: bool = false,
    focus_event: bool = false,
    bracket_paste: bool = false,
    alt_scroll: bool = false,
    sync_output: bool = false,
    osc8: bool = false,
    reverse: bool = false,
    reverse_wrap: bool = true,
    meta_eight_bit: bool = true,
    num_lock_modifier: bool = true,
    meta_esc_prefix: bool = true,
    bell_action: bool = true,
    sixel_display: bool = false,
    sixel_private_palette: bool = true,
    sixel_cursor_right: bool = false,
    grapheme_shaping: bool = false,
    report_theme: bool = false,
    visibility_reports: bool = false,
    size_notifications: bool = false,
    ime: bool = false,
    _pad: u2 = 0,
};

pub const VtState = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    grids: [2]Grid,
    which: u1 = 0,
    flags: Flags = .{},
    cursor_style: CursorStyle = .block,
    mouse: Mouse = .off,
    modify_other_keys: u8 = 1,
    g0: Charset = .ascii,
    g1: Charset = .ascii,
    g2: Charset = .ascii,
    g3: Charset = .ascii,
    gl: u2 = 0,
    ss: u2 = 0,
    ss_active: bool = false,
    last_cp: u21 = ' ',
    saved_mode: [32]u32 = @splat(0),
    saved_mode_val: [32]u8 = @splat(0),
    line_dirty: []u64,
    tabs: []u64,
    scheme: Scheme = .{},
    orig: Scheme = .{},
    table: [256]Color = undefined,
    ul_color: Color = .{ .r = 0, .g = 0, .b = 0 },
    ul_set: bool = false,
    color_stack: [16]ColorSnap = undefined,
    color_stack_size: u8 = 0,
    color_stack_idx: u8 = 0,
    kitty_kbd: [8]u16 = @splat(0),
    kitty_kbd_idx: u8 = 0,
    title: std.ArrayListUnmanaged(u8) = .empty,
    title_stack: std.ArrayListUnmanaged([]u8) = .empty,
    cell_px_w: u16 = 8,
    cell_px_h: u16 = 16,
    dark_theme: bool = true,
    visible: bool = true,
    kitty: Kitty.Store,
    storage: []u8,
    reply: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, scrollback: u32, storage: []u8) !VtState {
        var primary = try Grid.init(allocator, cols, rows, scrollback);
        errdefer primary.deinit(allocator);
        var alt = try Grid.init(allocator, cols, rows, rows);
        errdefer alt.deinit(allocator);
        const dirty_len = (rows + 63) / 64;
        const line_dirty = try allocator.alloc(u64, dirty_len);
        errdefer allocator.free(line_dirty);
        @memset(line_dirty, ~@as(u64, 0));
        const tab_len = (@as(usize, cols) + 63) / 64;
        const tabs = try allocator.alloc(u64, tab_len);
        defaultTabs(tabs, cols);

        var self = VtState{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .grids = .{ primary, alt },
            .line_dirty = line_dirty,
            .tabs = tabs,
            .kitty = Kitty.Store.init(allocator),
            .storage = storage,
        };
        self.initTable();
        return self;
    }

    pub fn deinit(self: *VtState) void {
        self.reply.deinit(self.allocator);
        self.title.deinit(self.allocator);
        for (self.title_stack.items) |t| self.allocator.free(t);
        self.title_stack.deinit(self.allocator);
        self.grids[0].deinit(self.allocator);
        self.grids[1].deinit(self.allocator);
        self.allocator.free(self.line_dirty);
        self.allocator.free(self.tabs);
        self.kitty.deinit();
    }

    pub fn reset(self: *VtState) void {
        self.which = 0;
        self.flags = .{};
        self.cursor_style = .block;
        self.mouse = .off;
        self.modify_other_keys = 1;
        self.g0 = .ascii;
        self.g1 = .ascii;
        self.g2 = .ascii;
        self.g3 = .ascii;
        self.gl = 0;
        self.ss_active = false;
        self.last_cp = ' ';
        self.saved_mode = @splat(0);
        self.saved_mode_val = @splat(0);
        self.ul_set = false;
        self.color_stack_size = 0;
        self.color_stack_idx = 0;
        self.kitty_kbd = @splat(0);
        self.kitty_kbd_idx = 0;
        self.scheme = self.orig;
        self.initTable();
        self.reply.clearRetainingCapacity();
        self.kitty.clear();
        defaultTabs(self.tabs, self.cols);
        self.grids[0].reset(self.cols, self.rows, self.scheme);
        self.grids[1].reset(self.cols, self.rows, self.scheme);
        self.markDirtyAll();
    }

    /// Replace the palette and remap cells that still hold previous theme colors.
    pub fn applyScheme(self: *VtState, next: Scheme) void {
        const prev = self.scheme;
        self.scheme = next;
        self.orig = next;
        self.initTable();
        remapGrid(&self.grids[0], prev, next);
        remapGrid(&self.grids[1], prev, next);
        self.markDirtyAll();
    }

    pub fn feedRuns(self: *VtState, runs: []const Run) void {
        for (runs) |run| {
            const slice = self.storage[run.off .. run.off + run.len];
            switch (run.kind) {
                .plain => {
                    for (slice) |b| self.printCodepoint(b);
                },
                .utf8 => {
                    var view = std.unicode.Utf8View.init(slice) catch continue;
                    var iter = view.iterator();
                    while (iter.nextCodepoint()) |cp| {
                        self.printCodepoint(cp);
                    }
                },
                .c0 => {
                    if (slice.len > 0) C0.dispatch(self, slice[0]);
                },
                .c1 => {
                    if (slice.len > 0) C1.dispatch(self, slice[0]);
                },
                .esc => Esc.dispatch(self, slice),
                .csi => {
                    var params: [16]CsiSeq.Param = undefined;
                    CsiSeq.parse(slice, &params).apply(self);
                },
                .osc => Osc.dispatch(self, slice),
                .str => {
                    if (Kitty.isPrefix(slice)) self.feedKitty(slice) else Dcs.dispatch(self, slice);
                },
                .esc_kitty => self.feedKitty(slice),
                .esc_sixel => {},
            }
        }
    }

    pub inline fn grid(self: *VtState) *Grid {
        return &self.grids[self.which];
    }

    pub inline fn gridConst(self: *const VtState) *const Grid {
        return &self.grids[self.which];
    }

    pub fn rowCells(self: *const VtState, row: u16) []const Cell {
        return self.gridConst().viewRowSliceConst(row, self.cols);
    }

    pub fn cell(self: *const VtState, row: u16, col: u16) Cell {
        return self.gridConst().viewCellAt(row, col);
    }

    pub fn viewScroll(self: *VtState, delta: i32) void {
        if (self.which != 0) return;
        const g = self.grid();
        const max_scroll = g.used -| @as(u32, self.rows);
        if (delta > 0) {
            g.scroll = @min(max_scroll, g.scroll + @as(u32, @intCast(delta)));
        } else if (delta < 0) {
            g.scroll -|= @as(u32, @intCast(-delta));
        }
        self.markDirtyAll();
    }

    pub fn cursor(self: *const VtState) Cursor {
        return self.gridConst().cursor;
    }

    pub fn cursorVisible(self: *const VtState) bool {
        return self.flags.cursor_visible;
    }

    pub fn cursorStyle(self: *const VtState) CursorStyle {
        return self.cursor_style;
    }

    pub fn altScreen(self: *const VtState) bool {
        return self.which == 1;
    }

    pub fn scrollOffset(self: *const VtState) u32 {
        return self.gridConst().scroll;
    }

    pub fn resize(self: *VtState, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0) return;
        if (cols == self.cols and rows == self.rows) return;
        const old_cols = self.cols;
        const old_rows = self.rows;
        try (&self.grids[0]).resize(self.allocator, old_cols, old_rows, cols, rows, self.grids[0].cap, true);
        try (&self.grids[1]).resize(self.allocator, old_cols, old_rows, cols, rows, rows, false);

        const dirty_len = (rows + 63) / 64;
        if (dirty_len != self.line_dirty.len) {
            self.line_dirty = try self.allocator.realloc(self.line_dirty, dirty_len);
        }
        const tab_len = (@as(usize, cols) + 63) / 64;
        if (tab_len != self.tabs.len) {
            self.tabs = try self.allocator.realloc(self.tabs, tab_len);
            defaultTabs(self.tabs, cols);
        } else if (cols != old_cols) {
            defaultTabs(self.tabs, cols);
        }

        self.cols = cols;
        self.rows = rows;
        self.markDirtyAll();
    }

    pub inline fn markDirty(self: *VtState, row: u16) void {
        if (row < self.rows) {
            self.line_dirty[row / 64] |= (@as(u64, 1) << @intCast(row % 64));
        }
    }

    pub fn markDirtyAll(self: *VtState) void {
        @memset(self.line_dirty, ~@as(u64, 0));
    }

    pub fn clearDirty(self: *VtState) void {
        @memset(self.line_dirty, 0);
    }

    pub fn lineDirty(self: *const VtState, row: u16) bool {
        if (row >= self.rows) return false;
        return self.line_dirty[row / 64] & (@as(u64, 1) << @intCast(row % 64)) != 0;
    }

    pub fn respond(self: *VtState, bytes: []const u8) void {
        self.reply.appendSlice(self.allocator, bytes) catch {};
    }

    pub fn respondFmt(self: *VtState, comptime fmt: []const u8, args: anytype) void {
        var buf: [96]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.respond(resp);
    }

    fn doWrap(self: *VtState) void {
        var g = self.grid();
        g.wrap_pending = false;
        g.setRowWrap(g.cursor.row, true);
        g.cursor.col = 0;
        self.index();
    }

    pub fn printCodepoint(self: *VtState, cp: u21) void {
        const mapped = self.mapCp(cp);
        var width: u16 = @max(1, EastAsian.cellWidth(mapped));
        var g = self.grid();

        if (g.wrap_pending) {
            g.wrap_pending = false;
            if (self.flags.auto_wrap) {
                self.doWrap();
                g = self.grid();
            }
        }

        if (g.cursor.col >= self.cols) {
            if (self.flags.auto_wrap) {
                self.doWrap();
                g = self.grid();
            } else {
                g.cursor.col = self.cols - 1;
                width = 1;
            }
        }

        if (width == 2 and g.cursor.col + 1 >= self.cols) {
            if (self.flags.auto_wrap and g.cursor.col != 0) {
                self.doWrap();
                g = self.grid();
            }
            if (g.cursor.col + 1 >= self.cols) width = 1;
        }

        if (self.flags.insert_mode) self.ich(width);
        g = self.grid();
        if (g.cursor.col >= self.cols) g.cursor.col = self.cols - 1;

        const attrs = self.paintAttrs();
        const slot = g.getCell(g.cursor.row, g.cursor.col);
        slot.* = .{
            .codepoint = mapped,
            .attrs = attrs,
            .fg = g.fg,
            .bg = g.bg,
        };
        if (width == 2 and g.cursor.col + 1 < self.cols) {
            g.getCell(g.cursor.row, g.cursor.col + 1).* = .{
                .codepoint = 0,
                .attrs = attrs,
                .fg = g.fg,
                .bg = g.bg,
            };
        }
        self.markDirty(g.cursor.row);
        g.cursor.col += width;
        if (g.cursor.col >= self.cols) {
            g.cursor.col = self.cols - 1;
            g.wrap_pending = self.flags.auto_wrap;
        } else {
            g.wrap_pending = false;
        }
        self.last_cp = mapped;
    }

    fn mapCp(self: *VtState, cp: u21) u21 {
        if (cp < 0x20 or cp > 0x7e) return cp;
        const idx: u2 = if (self.ss_active) blk: {
            self.ss_active = false;
            break :blk self.ss;
        } else self.gl;
        const set = switch (idx) {
            0 => self.g0,
            1 => self.g1,
            2 => self.g2,
            3 => self.g3,
        };
        if (set != .dec_special) return cp;
        return Esc.mapDecSpecial(cp);
    }

    fn paintAttrs(self: *const VtState) Attrs {
        var a = self.gridConst().attrs;
        a.link = self.flags.osc8;
        return a;
    }

    pub fn eraseCell(self: *const VtState) Cell {
        const g = self.gridConst();
        return .{ .fg = g.fg, .bg = g.bg };
    }

    pub fn cup(self: *VtState, row1: u16, col1: u16) void {
        const g = self.grid();
        var row: u16 = row1 -| 1;
        const col: u16 = col1 -| 1;

        if (self.flags.origin_mode) {
            row = @min(g.scroll_bottom, g.scroll_top +| row);
        } else {
            row = @min(self.rows - 1, row);
        }

        g.wrap_pending = false;
        g.cursor.row = row;
        g.cursor.col = @min(self.cols - 1, col);
    }

    pub fn cuu(self: *VtState, count: u16) void {
        const g = self.grid();
        g.wrap_pending = false;
        const top = if (self.flags.origin_mode) g.scroll_top else 0;
        const n = @min(count, g.cursor.row -| top);
        g.cursor.row -= n;
    }

    pub fn cud(self: *VtState, count: u16) void {
        const g = self.grid();
        g.wrap_pending = false;
        const bot = if (self.flags.origin_mode) g.scroll_bottom else self.rows - 1;
        const n = @min(count, bot -| g.cursor.row);
        g.cursor.row += n;
    }

    pub fn cuf(self: *VtState, count: u16) void {
        const g = self.grid();
        g.wrap_pending = false;
        g.cursor.col = @min(self.cols - 1, g.cursor.col +| count);
    }

    pub fn cub(self: *VtState, count: u16) void {
        const g = self.grid();
        g.wrap_pending = false;
        g.cursor.col = g.cursor.col -| count;
    }

    pub fn setCol(self: *VtState, col: u16) void {
        const g = self.grid();
        g.wrap_pending = false;
        g.cursor.col = @min(col, self.cols - 1);
    }

    pub fn carriageReturn(self: *VtState) void {
        const g = self.grid();
        g.wrap_pending = false;
        g.cursor.col = 0;
    }

    pub fn tab(self: *VtState) void {
        self.tabForward(1);
    }

    pub fn tabBack(self: *VtState) void {
        self.tabBackN(1);
    }

    pub fn tabForward(self: *VtState, count: u16) void {
        const g = self.grid();
        g.wrap_pending = false;
        var col = g.cursor.col;
        var left = count;
        var c = col + 1;
        while (c < self.cols and left > 0) : (c += 1) {
            if (tabIsSet(self.tabs, c)) {
                col = c;
                left -= 1;
            }
        }
        if (left != 0) col = self.cols - 1;
        g.cursor.col = col;
    }

    pub fn tabBackN(self: *VtState, count: u16) void {
        const g = self.grid();
        g.wrap_pending = false;
        var col = g.cursor.col;
        var left = count;
        if (col == 0) return;
        var c = col;
        while (c > 0 and left > 0) {
            c -= 1;
            if (tabIsSet(self.tabs, c)) {
                col = c;
                left -= 1;
            }
        }
        if (left != 0) col = 0;
        g.cursor.col = col;
    }

    pub fn setTab(self: *VtState) void {
        tabSet(self.tabs, self.grid().cursor.col);
    }

    pub fn tabClear(self: *VtState, mode: u16) void {
        switch (mode) {
            0 => tabUnset(self.tabs, self.grid().cursor.col),
            3 => @memset(self.tabs, 0),
            else => {},
        }
    }

    pub fn backspace(self: *VtState) void {
        const g = self.grid();
        if (g.wrap_pending) {
            g.wrap_pending = false;
            return;
        }
        if (g.cursor.col == 0) {
            if (self.flags.reverse_wrap and self.flags.auto_wrap) {
                if (g.cursor.row > g.scroll_top) {
                    g.cursor.row -= 1;
                    g.cursor.col = self.cols - 1;
                }
            }
            return;
        }
        g.cursor.col -= 1;
    }

    pub fn goHome(self: *VtState) void {
        const g = self.grid();
        g.wrap_pending = false;
        g.cursor.col = 0;
        g.cursor.row = if (self.flags.origin_mode) g.scroll_top else 0;
    }

    pub fn index(self: *VtState) void {
        const g = self.grid();
        g.wrap_pending = false;
        if (g.cursor.row == g.scroll_bottom) {
            self.regionScrollUp(1);
        } else if (g.cursor.row + 1 < self.rows) {
            g.cursor.row += 1;
        }
    }

    pub fn reverseIndex(self: *VtState) void {
        const g = self.grid();
        g.wrap_pending = false;
        if (g.cursor.row == g.scroll_top) {
            self.regionScrollDown(1);
        } else if (g.cursor.row > 0) {
            g.cursor.row -= 1;
        }
    }

    pub fn ed(self: *VtState, mode: u16) void {
        const g = self.grid();
        const blank = self.eraseCell();
        switch (mode) {
            0 => {
                @memset(g.rowSlice(g.cursor.row, self.cols)[g.cursor.col..], blank);
                self.markDirty(g.cursor.row);
                var r = g.cursor.row + 1;
                while (r < self.rows) : (r += 1) {
                    @memset(g.rowSlice(r, self.cols), blank);
                    self.markDirty(r);
                }
            },
            1 => {
                var r: u16 = 0;
                while (r < g.cursor.row) : (r += 1) {
                    @memset(g.rowSlice(r, self.cols), blank);
                    self.markDirty(r);
                }
                const end = @min(@as(usize, g.cursor.col) + 1, self.cols);
                @memset(g.rowSlice(g.cursor.row, self.cols)[0..end], blank);
                self.markDirty(g.cursor.row);
            },
            3 => {},
            else => {
                var r: u16 = 0;
                while (r < self.rows) : (r += 1) {
                    @memset(g.rowSlice(r, self.cols), blank);
                    self.markDirty(r);
                }
            },
        }
    }

    pub fn el(self: *VtState, mode: u16) void {
        const g = self.grid();
        const line = g.rowSlice(g.cursor.row, self.cols);
        const blank = self.eraseCell();
        switch (mode) {
            0 => @memset(line[g.cursor.col..], blank),
            1 => @memset(line[0..@min(@as(usize, g.cursor.col) + 1, line.len)], blank),
            else => @memset(line, blank),
        }
        self.markDirty(g.cursor.row);
    }

    pub fn ich(self: *VtState, n: u16) void {
        const g = self.grid();
        g.insertCells(g.cursor.row, g.cursor.col, n, self.cols);
        self.markDirty(g.cursor.row);
    }

    pub fn dch(self: *VtState, n: u16) void {
        const g = self.grid();
        g.deleteCells(g.cursor.row, g.cursor.col, n, self.cols);
        self.markDirty(g.cursor.row);
    }

    pub fn ech(self: *VtState, n: u16) void {
        const g = self.grid();
        const end = @min(self.cols, g.cursor.col +| n);
        if (end > g.cursor.col) {
            @memset(g.rowSlice(g.cursor.row, self.cols)[g.cursor.col..end], self.eraseCell());
            self.markDirty(g.cursor.row);
        }
    }

    pub fn il(self: *VtState, n: u16) void {
        const g = self.grid();
        if (g.cursor.row < g.scroll_top or g.cursor.row > g.scroll_bottom) return;
        g.scrollDown(g.cursor.row, g.scroll_bottom, n, self.cols);
        self.markDirtyAll();
    }

    pub fn dl(self: *VtState, n: u16) void {
        const g = self.grid();
        if (g.cursor.row < g.scroll_top or g.cursor.row > g.scroll_bottom) return;
        g.scrollUp(g.cursor.row, g.scroll_bottom, n, self.cols);
        self.markDirtyAll();
    }

    pub fn rep(self: *VtState, n: u16) void {
        const cp = self.last_cp;
        var k: u16 = 0;
        while (k < n) : (k += 1) self.printCodepoint(cp);
    }

    pub fn regionScrollUp(self: *VtState, n: u16) void {
        const g = self.grid();
        if (self.which == 0 and g.scroll_top == 0 and g.scroll_bottom + 1 == self.rows) {
            g.historyScrollUp(n, self.cols, self.rows);
        } else {
            g.scrollUp(g.scroll_top, g.scroll_bottom, n, self.cols);
        }
        const extra: u32 = if (self.which == 0) g.cap - self.rows else 0;
        var k: u16 = 0;
        while (k < n) : (k += 1) {
            self.kitty.scrollUp(self.which, extra);
        }
        self.markDirtyAll();
    }

    pub fn regionScrollDown(self: *VtState, n: u16) void {
        const g = self.grid();
        g.scrollDown(g.scroll_top, g.scroll_bottom, n, self.cols);
        self.markDirtyAll();
    }

    pub fn decstbm(self: *VtState, top1: u16, bot1: u16) void {
        const top: u16 = if (top1 == 0) 1 else top1;
        const bot: u16 = if (bot1 == 0) self.rows else bot1;
        if (top > bot or bot > self.rows) return;
        const g = self.grid();
        g.scroll_top = top - 1;
        g.scroll_bottom = bot - 1;
        self.goHome();
    }

    pub fn saveCursor(self: *VtState) void {
        self.grid().saveCursor();
    }

    pub fn restoreCursor(self: *VtState) void {
        const g = self.grid();
        g.restoreCursor();
        if (g.cursor.row >= self.rows) g.cursor.row = self.rows - 1;
        if (g.cursor.col >= self.cols) {
            g.cursor.col = self.cols - 1;
            g.wrap_pending = false;
        }
    }

    pub fn resetPen(self: *VtState) void {
        const g = self.grid();
        g.fg = self.scheme.fg;
        g.bg = self.scheme.bg;
        g.attrs = .{};
        self.ul_set = false;
    }

    pub fn takeColor(self: *VtState, rest: []const u16, fg: bool) usize {
        if (rest.len == 0) return 0;
        if (rest[0] == 5) {
            if (rest.len < 2) return rest.len;
            const c = indexedColor(self.scheme, rest[1]);
            if (fg) self.grid().fg = c else self.grid().bg = c;
            return 2;
        }
        if (rest[0] == 2) {
            if (rest.len >= 5) {
                self.setRgb(rest[2], rest[3], rest[4], fg);
                return 5;
            }
            if (rest.len >= 4) {
                self.setRgb(rest[1], rest[2], rest[3], fg);
                return 4;
            }
            return rest.len;
        }
        return 1;
    }

    fn setRgb(self: *VtState, r: u16, g: u16, b: u16, fg: bool) void {
        const c = Color{
            .r = clip(r),
            .g = clip(g),
            .b = clip(b),
        };
        if (fg) self.grid().fg = c else self.grid().bg = c;
    }

    pub fn setMode(self: *VtState, params: []const u32, enable: bool) void {
        for (params) |p| {
            switch (p) {
                4 => self.flags.insert_mode = enable,
                else => {},
            }
        }
    }

    pub fn setPrivate(self: *VtState, params: []const u32, enable: bool) void {
        for (params) |p| {
            switch (p) {
                1 => self.flags.app_cursor = enable,
                5 => {
                    if (self.flags.reverse != enable) {
                        self.flags.reverse = enable;
                        self.markDirtyAll();
                    }
                },
                6 => {
                    self.flags.origin_mode = enable;
                    self.goHome();
                },
                7 => self.flags.auto_wrap = enable,
                12 => self.flags.cursor_blink = enable,
                25 => {
                    if (self.flags.cursor_visible != enable) self.markDirty(self.grid().cursor.row);
                    self.flags.cursor_visible = enable;
                },
                45 => self.flags.reverse_wrap = enable,
                47, 1047 => self.setAlt(enable, false, false),
                66 => self.flags.app_keypad = enable,
                80 => self.flags.sixel_display = enable,
                1000 => self.mouse = if (enable) .btn else if (self.mouse == .btn) .off else self.mouse,
                1002 => self.mouse = if (enable) .drag else if (self.mouse == .drag) .off else self.mouse,
                1003 => self.mouse = if (enable) .any else if (self.mouse == .any) .off else self.mouse,
                1004 => self.flags.focus_event = enable,
                1006 => self.flags.mouse_sgr = enable,
                1007 => self.flags.alt_scroll = enable,
                1015 => self.flags.mouse_urxvt = enable,
                1016 => self.flags.mouse_pixels = enable,
                1034 => self.flags.meta_eight_bit = enable,
                1035 => self.flags.num_lock_modifier = enable,
                1036 => self.flags.meta_esc_prefix = enable,
                1042 => self.flags.bell_action = enable,
                1048 => if (enable) self.saveCursor() else self.restoreCursor(),
                1049 => self.setAlt(enable, true, true),
                1070 => self.flags.sixel_private_palette = enable,
                2004 => self.flags.bracket_paste = enable,
                2026 => self.flags.sync_output = enable,
                2027 => self.flags.grapheme_shaping = enable,
                2031 => self.flags.report_theme = enable,
                2033 => {
                    self.flags.visibility_reports = enable;
                    if (enable) self.respond(if (self.visible) "\x1b[?999;1n" else "\x1b[?999;2n");
                },
                2048 => self.flags.size_notifications = enable,
                8452 => self.flags.sixel_cursor_right = enable,
                737769 => self.flags.ime = enable,
                else => {},
            }
        }
    }

    pub fn setModifyKeys(self: *VtState, params: []const u32) void {
        if (params.len == 0) return;
        if (params[0] != 4) return;
        const pv = if (params.len > 1) params[1] else 0;
        self.modify_other_keys = @intCast(@min(pv, 2));
    }

    pub fn setCursorStyle(self: *VtState, n: u32) void {
        const style: CursorStyle = switch (n) {
            0, 1, 2 => .block,
            3, 4 => .underline,
            5, 6 => .bar,
            else => return,
        };
        const blink = n == 0 or n == 1 or n == 3 or n == 5;
        if (self.cursor_style == style and self.flags.cursor_blink == blink) return;
        self.cursor_style = style;
        self.flags.cursor_blink = blink;
        self.markDirty(self.grid().cursor.row);
    }

    pub fn softReset(self: *VtState) void {
        self.flags.origin_mode = false;
        self.flags.auto_wrap = true;
        self.flags.insert_mode = false;
        self.flags.cursor_visible = true;
        self.cursor_style = .block;
        self.flags.cursor_blink = false;
        self.flags.app_cursor = false;
        self.flags.app_keypad = false;
        self.g0 = .ascii;
        self.g1 = .ascii;
        self.g2 = .ascii;
        self.g3 = .ascii;
        self.gl = 0;
        self.ss_active = false;
        self.flags.reverse_wrap = true;
        self.last_cp = ' ';
        self.resetPen();
        const g = self.grid();
        g.wrap_pending = false;
        g.saved_cursor = .{};
        g.saved_wrap_pending = false;
        g.saved_fg = self.scheme.fg;
        g.saved_bg = self.scheme.bg;
        g.saved_attrs = .{};
        g.scroll_top = 0;
        g.scroll_bottom = self.rows - 1;
        self.markDirty(g.cursor.row);
    }

    pub fn savePrivate(self: *VtState, params: []const u32) void {
        for (params) |p| {
            if (p == 1048) {
                self.saveCursor();
            } else if (p != 0) self.saveOnePrivate(p);
        }
    }

    fn saveOnePrivate(self: *VtState, mode: u32) void {
        const raw = self.privateMode(mode);
        const val: u8 = if (raw == 0) 2 else @intCast(raw);
        var slot: ?usize = null;
        for (self.saved_mode, 0..) |m, i| {
            if (m == mode and self.saved_mode_val[i] != 0) {
                slot = i;
                break;
            }
            if (slot == null and self.saved_mode_val[i] == 0) slot = i;
        }
        const i = slot orelse self.saved_mode.len - 1;
        self.saved_mode[i] = mode;
        self.saved_mode_val[i] = val;
    }

    pub fn restorePrivate(self: *VtState, params: []const u32) void {
        for (params) |p| {
            if (p == 0) continue;
            if (p == 1048) {
                self.restoreCursor();
                continue;
            }
            for (self.saved_mode, 0..) |m, i| {
                if (m == p and self.saved_mode_val[i] != 0) {
                    self.setPrivate(&[_]u32{p}, self.saved_mode_val[i] == 1);
                    break;
                }
            }
        }
    }

    pub fn privateMode(self: *const VtState, n: u32) u16 {
        const on: bool = switch (n) {
            1 => self.flags.app_cursor,
            5 => self.flags.reverse,
            6 => self.flags.origin_mode,
            7 => self.flags.auto_wrap,
            9, 67, 1001, 1005 => return 4,
            12 => self.flags.cursor_blink,
            25 => self.flags.cursor_visible,
            45 => self.flags.reverse_wrap,
            47, 1047, 1049 => self.which == 1,
            66 => self.flags.app_keypad,
            80 => self.flags.sixel_display,
            1000 => self.mouse == .btn,
            1002 => self.mouse == .drag,
            1003 => self.mouse == .any,
            1004 => self.flags.focus_event,
            1006 => self.flags.mouse_sgr,
            1007 => self.flags.alt_scroll,
            1015 => self.flags.mouse_urxvt,
            1016 => self.flags.mouse_pixels,
            1034 => self.flags.meta_eight_bit,
            1035 => self.flags.num_lock_modifier,
            1036 => self.flags.meta_esc_prefix,
            1042 => self.flags.bell_action,
            1070 => self.flags.sixel_private_palette,
            2004 => self.flags.bracket_paste,
            2026 => self.flags.sync_output,
            2027 => self.flags.grapheme_shaping,
            2031 => self.flags.report_theme,
            2033 => self.flags.visibility_reports,
            2048 => self.flags.size_notifications,
            8452 => self.flags.sixel_cursor_right,
            737769 => self.flags.ime,
            else => return 0,
        };
        return if (on) 1 else 2;
    }

    pub fn ansiMode(self: *const VtState, n: u32) u16 {
        return switch (n) {
            4 => if (self.flags.insert_mode) 1 else 2,
            else => 0,
        };
    }

    pub fn cursorReportRow(self: *const VtState) u16 {
        const g = self.gridConst();
        const row = if (self.flags.origin_mode) g.cursor.row -| g.scroll_top else g.cursor.row;
        return row + 1;
    }

    pub fn colorIndex(self: *const VtState, i: u32) Color {
        return indexedColor(self.scheme, @intCast(@min(i, 255)));
    }

    pub fn setUnderlineColor(self: *VtState, c: Color) void {
        self.ul_color = c;
        self.ul_set = true;
    }

    pub fn clearUnderlineColor(self: *VtState) void {
        self.ul_set = false;
    }

    pub fn initTable(self: *VtState) void {
        self.table = makeTable(self.scheme);
    }

    pub fn pixelWidth(self: *const VtState, window: bool) u16 {
        _ = window;
        return self.cols *| self.cell_px_w;
    }

    pub fn pixelHeight(self: *const VtState, window: bool) u16 {
        _ = window;
        return self.rows *| self.cell_px_h;
    }

    pub fn pushTitle(self: *VtState) void {
        if (self.title_stack.items.len >= 128) return;
        const copy = self.allocator.dupe(u8, self.title.items) catch return;
        self.title_stack.append(self.allocator, copy) catch {
            self.allocator.free(copy);
        };
    }

    pub fn popTitle(self: *VtState) void {
        const copy = self.title_stack.pop() orelse return;
        self.title.clearRetainingCapacity();
        self.title.appendSlice(self.allocator, copy) catch {};
        self.allocator.free(copy);
    }

    pub fn setTitle(self: *VtState, s: []const u8) void {
        self.title.clearRetainingCapacity();
        self.title.appendSlice(self.allocator, s) catch {};
    }

    pub fn kittyKbdQuery(self: *VtState) void {
        self.respondFmt("\x1b[?{d}u", .{self.kitty_kbd[self.kitty_kbd_idx]});
    }

    pub fn kittyKbdPush(self: *VtState, flags: u32) void {
        var idx = self.kitty_kbd_idx;
        if (idx + 1 >= self.kitty_kbd.len) idx = 0 else idx += 1;
        self.kitty_kbd[idx] = @intCast(flags & KITTY_KBD_SUPPORTED);
        self.kitty_kbd_idx = idx;
    }

    pub fn kittyKbdPop(self: *VtState, count: u32) void {
        const n = @min(count, self.kitty_kbd.len);
        var idx = self.kitty_kbd_idx;
        var i: u16 = 0;
        while (i < n) : (i += 1) {
            self.kitty_kbd[idx] = 0;
            idx = if (idx == 0) @intCast(self.kitty_kbd.len - 1) else idx - 1;
        }
        self.kitty_kbd_idx = idx;
    }

    pub fn kittyKbdSet(self: *VtState, flags: u32, mode: u32) void {
        const bits: u16 = @intCast(flags & KITTY_KBD_SUPPORTED);
        const idx = self.kitty_kbd_idx;
        switch (mode) {
            1 => self.kitty_kbd[idx] = bits,
            2 => self.kitty_kbd[idx] |= bits,
            3 => self.kitty_kbd[idx] &= ~bits,
            else => {},
        }
    }

    pub fn xtPushColors(self: *VtState, slot0: u32) void {
        var slot: u32 = slot0;
        if (slot == 0) slot = @as(u32, self.color_stack_idx) + 1;
        if (slot > self.color_stack.len) slot = self.color_stack.len;
        if (slot == 0) return;
        if (self.color_stack_size < slot) self.color_stack_size = @intCast(slot);
        self.color_stack_idx = @intCast(slot);
        self.color_stack[@intCast(slot - 1)] = .{
            .fg = self.scheme.fg,
            .bg = self.scheme.bg,
            .cursor = self.scheme.cursor,
            .table = self.table,
        };
    }

    pub fn xtPopColors(self: *VtState, slot0: u32) void {
        var slot: u32 = slot0;
        if (slot == 0) slot = self.color_stack_idx;
        if (slot == 0 or slot > self.color_stack_size) return;
        const snap = self.color_stack[@intCast(slot - 1)];
        self.scheme.fg = snap.fg;
        self.scheme.bg = snap.bg;
        self.scheme.cursor = snap.cursor;
        self.table = snap.table;
        self.color_stack_idx = @intCast(slot - 1);
        self.markDirtyAll();
    }

    pub fn xtReportColors(self: *VtState) void {
        self.respondFmt("\x1b[?{d};{d}#Q", .{ self.color_stack_idx, self.color_stack_size });
    }

    pub fn decaln(self: *VtState) void {
        const g = self.grid();
        g.scroll_top = 0;
        g.scroll_bottom = self.rows - 1;
        const attrs = self.paintAttrs();
        var r: u16 = 0;
        while (r < self.rows) : (r += 1) {
            for (g.rowSlice(r, self.cols)) |*c| {
                c.* = .{ .codepoint = 'E', .attrs = attrs, .fg = g.fg, .bg = g.bg };
            }
            self.markDirty(r);
        }
        self.goHome();
    }

    fn rowRelToAbs(self: *const VtState, rel: u32) u16 {
        const r: u16 = @intCast(@min(rel, 65535));
        const g = self.gridConst();
        if (self.flags.origin_mode) {
            return @min(g.scroll_bottom, g.scroll_top +| r);
        }
        return @min(self.rows - 1, r);
    }

    fn rectArea(self: *const VtState, params: []const CsiSeq.Param, first: usize) ?struct { top: u16, left: u16, bottom: u16, right: u16 } {
        const rel_top = paramVal(params, first + 0, 1) -| 1;
        const left: u16 = @intCast(@min(paramVal(params, first + 1, 1) -| 1, @as(u32, self.cols - 1)));
        const rel_bot = paramVal(params, first + 2, self.rows) -| 1;
        const right: u16 = @intCast(@min(paramVal(params, first + 3, self.cols) -| 1, @as(u32, self.cols - 1)));
        if (rel_top > rel_bot or left > right) return null;
        return .{
            .top = self.rowRelToAbs(rel_top),
            .left = left,
            .bottom = self.rowRelToAbs(rel_bot),
            .right = right,
        };
    }

    pub fn deccara(self: *VtState, params: []const CsiSeq.Param) void {
        const area = self.rectArea(params, 0) orelse return;
        var r = area.top;
        while (r <= area.bottom) : (r += 1) {
            var c = area.left;
            while (c <= area.right) : (c += 1) {
                const slot = self.grid().getCell(r, c);
                var a = slot.attrs;
                var i: usize = 4;
                while (i < params.len) : (i += 1) {
                    switch (params[i].value) {
                        0 => {
                            a.bold = false;
                            a.underline = false;
                            a.underline_style = 0;
                            a.blink = false;
                            a.inverse = false;
                        },
                        1 => a.bold = true,
                        4 => a.underline = true,
                        5 => a.blink = true,
                        7 => a.inverse = true,
                        22 => a.bold = false,
                        24 => {
                            a.underline = false;
                            a.underline_style = 0;
                        },
                        25 => a.blink = false,
                        27 => a.inverse = false,
                        else => {},
                    }
                }
                slot.attrs = a;
            }
            self.markDirty(r);
        }
    }

    pub fn decrara(self: *VtState, params: []const CsiSeq.Param) void {
        const area = self.rectArea(params, 0) orelse return;
        var r = area.top;
        while (r <= area.bottom) : (r += 1) {
            var c = area.left;
            while (c <= area.right) : (c += 1) {
                const slot = self.grid().getCell(r, c);
                var a = slot.attrs;
                var i: usize = 4;
                while (i < params.len) : (i += 1) {
                    switch (params[i].value) {
                        0 => {
                            a.bold = !a.bold;
                            a.underline = !a.underline;
                            a.blink = !a.blink;
                            a.inverse = !a.inverse;
                        },
                        1 => a.bold = !a.bold,
                        4 => a.underline = !a.underline,
                        5 => a.blink = !a.blink,
                        7 => a.inverse = !a.inverse,
                        else => {},
                    }
                }
                slot.attrs = a;
            }
            self.markDirty(r);
        }
    }

    pub fn deccra(self: *VtState, params: []const CsiSeq.Param) void {
        const src = self.rectArea(params, 0) orelse return;
        const src_page = paramVal(params, 4, 1);
        const dst_page = paramVal(params, 7, 1);
        if (src_page != 1 or dst_page != 1) return;
        const dst_rel_top = paramVal(params, 5, 1) -| 1;
        const dst_left: u16 = @intCast(@min(paramVal(params, 6, 1) -| 1, @as(u32, self.cols - 1)));
        const height = src.bottom - src.top + 1;
        const width = src.right - src.left + 1;
        const dst_top = self.rowRelToAbs(dst_rel_top);
        const dst_bottom = self.rowRelToAbs(dst_rel_top +| (height - 1));
        const dst_right = @min(dst_left +| (width - 1), self.cols - 1);
        if (dst_left > dst_right or dst_top > dst_bottom) return;
        const row_count = @min(src.bottom - src.top, dst_bottom - dst_top) + 1;
        const cell_count = @min(src.right - src.left, dst_right - dst_left) + 1;

        var copy = self.allocator.alloc(Cell, @as(usize, row_count) * cell_count) catch return;
        defer self.allocator.free(copy);
        var r: u16 = 0;
        while (r < row_count) : (r += 1) {
            const line = self.grid().rowSlice(src.top + r, self.cols);
            @memcpy(copy[@as(usize, r) * cell_count ..][0..cell_count], line[src.left .. src.left + cell_count]);
        }
        r = 0;
        while (r < row_count) : (r += 1) {
            const line = self.grid().rowSlice(dst_top + r, self.cols);
            @memcpy(line[dst_left .. dst_left + cell_count], copy[@as(usize, r) * cell_count ..][0..cell_count]);
            self.markDirty(dst_top + r);
        }
    }

    pub fn decfra(self: *VtState, params: []const CsiSeq.Param) void {
        const ch: u8 = @truncate(paramVal(params, 0, 0));
        if (!((ch >= 32 and ch < 126) or ch >= 160)) return;
        const area = self.rectArea(params, 1) orelse return;
        const attrs = self.paintAttrs();
        const g = self.grid();
        var r = area.top;
        while (r <= area.bottom) : (r += 1) {
            var c = area.left;
            while (c <= area.right) : (c += 1) {
                g.getCell(r, c).* = .{ .codepoint = ch, .attrs = attrs, .fg = g.fg, .bg = g.bg };
            }
            self.markDirty(r);
        }
    }

    pub fn decera(self: *VtState, params: []const CsiSeq.Param) void {
        const area = self.rectArea(params, 0) orelse return;
        const blank = self.eraseCell();
        var r = area.top;
        while (r <= area.bottom) : (r += 1) {
            @memset(self.grid().rowSlice(r, self.cols)[area.left .. area.right + 1], blank);
            self.markDirty(r);
        }
    }

    fn setAlt(self: *VtState, on: bool, save: bool, wipe: bool) void {
        if (on) {
            if (self.which == 1) return;
            if (save) self.saveCursor();
            self.which = 1;
            if (wipe) {
                self.grids[1].reset(self.cols, self.rows, self.scheme);
                self.kitty.dropScreen(1);
            }
        } else {
            if (self.which == 0) return;
            self.which = 0;
            if (save) self.restoreCursor();
        }
        self.markDirtyAll();
    }

    fn feedKitty(self: *VtState, bytes: []const u8) void {
        const cur = self.grid().cursor;
        const next = self.kitty.feed(bytes, .{ .row = cur.row, .col = cur.col }, self.cols, self.rows, self.which);
        if (self.kitty.reply_len != 0) {
            self.respond(self.kitty.reply[0..self.kitty.reply_len]);
        }
        if (next) |c| {
            const g = self.grid();
            g.cursor.row = c.row;
            g.cursor.col = c.col;
        }
        if (self.kitty.dirty) self.markDirtyAll();
    }

    pub fn dumpAlloc(self: *const VtState, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var y: u16 = 0;
        while (y < self.rows) : (y += 1) {
            if (y != 0) try out.append(allocator, '\n');
            for (self.rowCells(y)) |c| {
                const cp: u21 = if (c.codepoint == 0) ' ' else c.codepoint;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch {
                    try out.append(allocator, '?');
                    continue;
                };
                try out.appendSlice(allocator, buf[0..n]);
            }
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn dumpCellsAlloc(self: *const VtState, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var y: u16 = 0;
        while (y < self.rows) : (y += 1) {
            const line = self.rowCells(y);
            var x: u16 = 0;
            while (x < self.cols) : (x += 1) {
                const c = line[x];
                if (cellIsBlank(self.scheme, c)) continue;
                var attr_buf: [9]u8 = undefined;
                const attrs = attrLetters(c.attrs, &attr_buf);
                var buf: [96]u8 = undefined;
                const n = std.fmt.bufPrint(&buf, "{d} {d} U+{X:0>4} #{x:0>2}{x:0>2}{x:0>2} #{x:0>2}{x:0>2}{x:0>2} {s}\n", .{
                    y,
                    x,
                    c.codepoint,
                    c.fg.r,
                    c.fg.g,
                    c.fg.b,
                    c.bg.r,
                    c.bg.g,
                    c.bg.b,
                    attrs,
                }) catch unreachable;
                try out.appendSlice(allocator, n);
            }
        }
        return out.toOwnedSlice(allocator);
    }
};

fn paramVal(params: []const CsiSeq.Param, idx: usize, default: u32) u32 {
    if (idx >= params.len) return default;
    const v = params[idx].value;
    return if (v != 0) v else default;
}

fn colorEq(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn remapColor(c: Color, prev: Scheme, next: Scheme) Color {
    if (colorEq(c, prev.fg)) return next.fg;
    if (colorEq(c, prev.bg)) return next.bg;
    if (colorEq(c, prev.cursor)) return next.cursor;
    for (prev.palette, 0..) |p, i| {
        if (colorEq(c, p)) return next.palette[i];
    }
    return c;
}

fn remapGrid(g: *Grid, prev: Scheme, next: Scheme) void {
    for (g.cells) |*cell| {
        cell.fg = remapColor(cell.fg, prev, next);
        cell.bg = remapColor(cell.bg, prev, next);
    }
    g.fg = remapColor(g.fg, prev, next);
    g.bg = remapColor(g.bg, prev, next);
    g.saved_fg = remapColor(g.saved_fg, prev, next);
    g.saved_bg = remapColor(g.saved_bg, prev, next);
}

fn makeTable(scheme: Scheme) [256]Color {
    var t: [256]Color = undefined;
    for (0..16) |i| t[i] = scheme.palette[i];
    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
    var n: u16 = 16;
    while (n < 232) : (n += 1) {
        const x = n - 16;
        t[n] = .{ .r = levels[x / 36], .g = levels[(x % 36) / 6], .b = levels[x % 6] };
    }
    while (n < 256) : (n += 1) {
        const v: u8 = 8 + 10 * @as(u8, @intCast(n - 232));
        t[n] = .{ .r = v, .g = v, .b = v };
    }
    return t;
}

fn defaultTabs(tabs: []u64, cols: u16) void {
    @memset(tabs, 0);
    var c: u16 = 8;
    while (c < cols) : (c += 8) tabSet(tabs, c);
}

fn tabIsSet(tabs: []const u64, col: u16) bool {
    const i = col / 64;
    if (i >= tabs.len) return false;
    return tabs[i] & (@as(u64, 1) << @intCast(col % 64)) != 0;
}

fn tabSet(tabs: []u64, col: u16) void {
    const i = col / 64;
    if (i >= tabs.len) return;
    tabs[i] |= @as(u64, 1) << @intCast(col % 64);
}

fn tabUnset(tabs: []u64, col: u16) void {
    const i = col / 64;
    if (i >= tabs.len) return;
    tabs[i] &= ~(@as(u64, 1) << @intCast(col % 64));
}

fn clip(v: u16) u8 {
    return @truncate(@min(v, 255));
}

fn indexedColor(scheme: Scheme, i: u16) Color {
    const n: u8 = clip(i);
    if (n < 16) return scheme.palette[n];
    if (n < 232) {
        const x = n - 16;
        const r6 = x / 36;
        const g6 = (x % 36) / 6;
        const b6 = x % 6;
        const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
        return .{ .r = levels[r6], .g = levels[g6], .b = levels[b6] };
    }
    const v: u8 = 8 + 10 * (n - 232);
    return .{ .r = v, .g = v, .b = v };
}

fn cellIsBlank(scheme: Scheme, c: Cell) bool {
    if (c.codepoint != ' ' and c.codepoint != 0) return false;
    if (c.fg.r != scheme.fg.r or c.fg.g != scheme.fg.g or c.fg.b != scheme.fg.b) return false;
    if (c.bg.r != scheme.bg.r or c.bg.g != scheme.bg.g or c.bg.b != scheme.bg.b) return false;
    const z: Attrs = .{};
    return std.meta.eql(c.attrs, z);
}

fn attrLetters(a: Attrs, buf: *[9]u8) []const u8 {
    var n: usize = 0;
    if (a.bold) {
        buf[n] = 'B';
        n += 1;
    }
    if (a.dim) {
        buf[n] = 'D';
        n += 1;
    }
    if (a.italic) {
        buf[n] = 'I';
        n += 1;
    }
    if (a.underline) {
        buf[n] = 'U';
        n += 1;
    }
    if (a.inverse) {
        buf[n] = 'R';
        n += 1;
    }
    if (a.hidden) {
        buf[n] = 'H';
        n += 1;
    }
    if (a.strikethrough) {
        buf[n] = 'S';
        n += 1;
    }
    if (a.blink) {
        buf[n] = 'K';
        n += 1;
    }
    if (a.link) {
        buf[n] = 'L';
        n += 1;
    }
    if (n == 0) {
        buf[0] = '-';
        return buf[0..1];
    }
    return buf[0..n];
}

fn applyCsi(vt: *VtState, seq: []const u8) void {
    var params: [16]CsiSeq.Param = undefined;
    CsiSeq.parse(seq, &params).apply(vt);
}

test "sgr truecolor bg" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    applyCsi(&vt, "\x1b[48;2;30;60;90m");
    vt.printCodepoint('X');
    vt.printCodepoint('Y');
    const c = vt.grid().cellAt(0, 0);
    try std.testing.expectEqual(@as(u21, 'X'), c.codepoint);
    try std.testing.expectEqual(@as(u8, 0x1e), c.bg.r);
    try std.testing.expectEqual(@as(u8, 0x3c), c.bg.g);
    try std.testing.expectEqual(@as(u8, 0x5a), c.bg.b);
}

test "sgr bold italic underline" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    applyCsi(&vt, "\x1b[1;31m");
    vt.printCodepoint('A');
    applyCsi(&vt, "\x1b[0;3m");
    vt.printCodepoint('B');
    applyCsi(&vt, "\x1b[0;4m");
    vt.printCodepoint('C');
    try std.testing.expect(vt.grid().cellAt(0, 0).attrs.bold);
    try std.testing.expectEqual(vt.scheme.palette[1], vt.grid().cellAt(0, 0).fg);
    try std.testing.expect(vt.grid().cellAt(0, 1).attrs.italic);
    try std.testing.expect(vt.grid().cellAt(0, 2).attrs.underline);
}

test "cup el keeps pen on blanks" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    vt.printCodepoint('A');
    vt.printCodepoint('B');
    applyCsi(&vt, "\x1b[41m");
    vt.printCodepoint('C');
    vt.printCodepoint('D');
    applyCsi(&vt, "\x1b[1;3H");
    applyCsi(&vt, "\x1b[K");
    try std.testing.expectEqual(@as(u21, 'A'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), vt.grid().cellAt(0, 2).codepoint);
    try std.testing.expectEqual(vt.scheme.palette[1], vt.grid().cellAt(0, 2).bg);
}

test "alt 1049 wipes" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    vt.printCodepoint('A');
    vt.printCodepoint('B');
    applyCsi(&vt, "\x1b[?1049h");
    vt.printCodepoint('X');
    vt.printCodepoint('Y');
    try std.testing.expectEqual(@as(u1, 1), vt.which);
    try std.testing.expectEqual(@as(u21, 'X'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'A'), vt.grids[0].cellAt(0, 0).codepoint);
}

test "dump cells match fixtures" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    applyCsi(&vt, "\x1b[1;31m");
    vt.printCodepoint('A');
    applyCsi(&vt, "\x1b[0;3m");
    vt.printCodepoint('B');
    applyCsi(&vt, "\x1b[0;4m");
    vt.printCodepoint('C');
    const cells = try vt.dumpCellsAlloc(std.testing.allocator);
    defer std.testing.allocator.free(cells);
    try std.testing.expectEqualStrings(
        "0 0 U+0041 #aa0000 #000000 B\n0 1 U+0042 #aaaaaa #000000 I\n0 2 U+0043 #aaaaaa #000000 U\n",
        cells,
    );
}

test "wrap and cjk width" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 2, 2, &dummy);
    defer vt.deinit();
    for ("ABCD") |b| vt.printCodepoint(b);
    try std.testing.expectEqual(@as(u21, 'A'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), vt.grid().cellAt(0, 3).codepoint);

    var vt2 = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt2.deinit();
    vt2.printCodepoint('日');
    vt2.printCodepoint('本');
    vt2.printCodepoint('語');
    vt2.printCodepoint('A');
    vt2.printCodepoint('B');
    try std.testing.expectEqual(@as(u21, '日'), vt2.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 0), vt2.grid().cellAt(0, 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'A'), vt2.grid().cellAt(0, 6).codepoint);
}

test "sgr colon truecolor" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    applyCsi(&vt, "\x1b[38:2:30:60:90m");
    vt.printCodepoint('X');
    const c = vt.grid().cellAt(0, 0);
    try std.testing.expectEqual(@as(u8, 30), c.fg.r);
    try std.testing.expectEqual(@as(u8, 60), c.fg.g);
    try std.testing.expectEqual(@as(u8, 90), c.fg.b);
}

test "decrqm cursor visible" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    applyCsi(&vt, "\x1b[?25$p");
    try std.testing.expectEqualStrings("\x1b[?25;1$y", vt.reply.items);
}

test "decera fill" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    applyCsi(&vt, "\x1b[65;1;1;1;4$x"); // DECFRA 'A' row1 col1-4
    try std.testing.expectEqual(@as(u21, 'A'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'A'), vt.grid().cellAt(0, 3).codepoint);
    applyCsi(&vt, "\x1b[1;1;1;2$z"); // DECERA first two cells
    try std.testing.expectEqual(@as(u21, ' '), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'A'), vt.grid().cellAt(0, 2).codepoint);
}

test "decaln" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 2, 2, &dummy);
    defer vt.deinit();
    Esc.dispatch(&vt, "\x1b#8");
    try std.testing.expectEqual(@as(u21, 'E'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), vt.grid().cellAt(1, 3).codepoint);
}

test "resize keeps cells" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 2, 8, &dummy);
    defer vt.deinit();
    vt.printCodepoint('A');
    vt.printCodepoint('B');
    try vt.resize(6, 3);
    try std.testing.expectEqual(@as(u16, 6), vt.cols);
    try std.testing.expectEqual(@as(u16, 3), vt.rows);
    try std.testing.expectEqual(@as(u21, 'A'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), vt.grid().cellAt(0, 1).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), vt.grid().cellAt(0, 4).codepoint);
    try vt.resize(3, 2);
    try std.testing.expectEqual(@as(u21, 'A'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), vt.grid().cellAt(0, 1).codepoint);
}

test "print wraps to next line" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 2, 8, &dummy);
    defer vt.deinit();
    for ("ABCDEFGH") |b| vt.printCodepoint(b);
    try std.testing.expectEqual(@as(u21, 'A'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), vt.grid().cellAt(0, 3).codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), vt.grid().cellAt(1, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'H'), vt.grid().cellAt(1, 3).codepoint);
    try std.testing.expectEqual(@as(u8, 1), vt.grid().wraps[(vt.grid().head + 0) % vt.grid().cap]);
}

test "lcf stays on last column until next char" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 3, 8, &dummy);
    defer vt.deinit();
    for ("ABCD") |b| vt.printCodepoint(b);
    try std.testing.expectEqual(@as(u16, 0), vt.grid().cursor.row);
    try std.testing.expectEqual(@as(u16, 3), vt.grid().cursor.col);
    try std.testing.expect(vt.grid().wrap_pending);
    try std.testing.expectEqual(@as(u21, 'A'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), vt.grid().cellAt(0, 3).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), vt.grid().cellAt(1, 0).codepoint);
    vt.printCodepoint('E');
    try std.testing.expectEqual(@as(u16, 1), vt.grid().cursor.row);
    try std.testing.expectEqual(@as(u16, 1), vt.grid().cursor.col);
    try std.testing.expect(!vt.grid().wrap_pending);
    try std.testing.expectEqual(@as(u21, 'E'), vt.grid().cellAt(1, 0).codepoint);
    try std.testing.expectEqual(@as(u8, 1), vt.grid().wraps[(vt.grid().head + 0) % vt.grid().cap]);
}

test "lcf newline does not wrap twice" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 4, 8, &dummy);
    defer vt.deinit();
    for ("ABCD") |b| vt.printCodepoint(b);
    C0.dispatch(&vt, 0x0D);
    C0.dispatch(&vt, 0x0A);
    vt.printCodepoint('E');
    try std.testing.expectEqual(@as(u21, 'A'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), vt.grid().cellAt(0, 3).codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), vt.grid().cellAt(1, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), vt.grid().cellAt(2, 0).codepoint);
    try std.testing.expectEqual(@as(u16, 1), vt.grid().cursor.row);
    try std.testing.expectEqual(@as(u16, 1), vt.grid().cursor.col);
}

test "lcf cpr reports last column" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 2, 8, &dummy);
    defer vt.deinit();
    for ("ABCD") |b| vt.printCodepoint(b);
    applyCsi(&vt, "\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;4R", vt.reply.items);
}

test "wrap at bottom does not duplicate line" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 2, 8, &dummy);
    defer vt.deinit();
    for ("AABBCCDDEE") |b| vt.printCodepoint(b);
    try std.testing.expectEqual(@as(u21, 'C'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), vt.grid().cellAt(0, 3).codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), vt.grid().cellAt(1, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), vt.grid().cellAt(1, 1).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), vt.grid().cellAt(1, 2).codepoint);
}

test "full line crlf at bottom does not duplicate" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 2, 8, &dummy);
    defer vt.deinit();
    for ("AABB") |b| vt.printCodepoint(b);
    C0.dispatch(&vt, 0x0D);
    C0.dispatch(&vt, 0x0A);
    for ("CCDD") |b| vt.printCodepoint(b);
    try std.testing.expectEqual(@as(u21, 'A'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), vt.grid().cellAt(0, 3).codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), vt.grid().cellAt(1, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), vt.grid().cellAt(1, 3).codepoint);
}

test "lcf backspace does not leave last column" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 2, 8, &dummy);
    defer vt.deinit();
    for ("ABCD") |b| vt.printCodepoint(b);
    vt.backspace();
    try std.testing.expectEqual(@as(u16, 3), vt.grid().cursor.col);
    try std.testing.expect(!vt.grid().wrap_pending);
}

test "resize reflows wrapped lines" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 16, &dummy);
    defer vt.deinit();
    for ("ABCDEFGH") |b| vt.printCodepoint(b);
    try vt.resize(4, 4);
    try std.testing.expectEqual(@as(u21, 'A'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), vt.grid().cellAt(0, 3).codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), vt.grid().cellAt(1, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'H'), vt.grid().cellAt(1, 3).codepoint);
    try vt.resize(8, 2);
    try std.testing.expectEqual(@as(u21, 'A'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'H'), vt.grid().cellAt(0, 7).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), vt.grid().cellAt(1, 0).codepoint);
}
