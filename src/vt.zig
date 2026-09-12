//! State machine, VT operations, sequence routing, and flags.

const std = @import("std");
const GridMod = @import("grid.zig");
const Kitty = @import("kitty.zig");
const CsiSeq = @import("csi.zig");
const Esc = @import("esc.zig");
const Osc = @import("osc.zig");
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
    _pad: u16 = 0,
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
    modify_other_keys: u8 = 0,
    g0: Charset = .ascii,
    g1: Charset = .ascii,
    gl: u1 = 0,
    last_cp: u21 = ' ',
    saved_mode: [16]u16 = @splat(0),
    saved_mode_val: [16]u8 = @splat(0),
    line_dirty: []u64,
    scheme: Scheme = .{},
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
        @memset(line_dirty, ~@as(u64, 0));

        return VtState{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .grids = .{ primary, alt },
            .line_dirty = line_dirty,
            .kitty = Kitty.Store.init(allocator),
            .storage = storage,
        };
    }

    pub fn deinit(self: *VtState) void {
        self.reply.deinit(self.allocator);
        self.grids[0].deinit(self.allocator);
        self.grids[1].deinit(self.allocator);
        self.allocator.free(self.line_dirty);
        self.kitty.deinit();
    }

    pub fn reset(self: *VtState) void {
        self.which = 0;
        self.flags = .{};
        self.cursor_style = .block;
        self.mouse = .off;
        self.modify_other_keys = 0;
        self.g0 = .ascii;
        self.g1 = .ascii;
        self.gl = 0;
        self.last_cp = ' ';
        self.saved_mode = @splat(0);
        self.saved_mode_val = @splat(0);
        self.reply.clearRetainingCapacity();
        self.kitty.clear();
        self.grids[0].reset(self.cols, self.rows, self.scheme);
        self.grids[1].reset(self.cols, self.rows, self.scheme);
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
                    var params: [16]u16 = undefined;
                    CsiSeq.parse(slice, &params).apply(self);
                },
                .osc => Osc.dispatch(self, slice),
                .str => {
                    if (Kitty.isPrefix(slice)) self.feedKitty(slice);
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
        return self.gridConst().rowSliceConst(row, self.cols);
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

    pub fn printCodepoint(self: *VtState, cp: u21) void {
        const mapped = self.mapCp(cp);
        var width: u16 = @max(1, EastAsian.cellWidth(mapped));
        var g = self.grid();

        if (g.cursor.col >= self.cols) {
            if (self.flags.auto_wrap) {
                g.cursor.col = 0;
                self.index();
                g = self.grid();
            } else {
                g.cursor.col = self.cols - 1;
                width = 1;
            }
        }

        if (width == 2 and g.cursor.col + 1 >= self.cols) {
            if (self.flags.auto_wrap and g.cursor.col != 0) {
                g.cursor.col = 0;
                self.index();
                g = self.grid();
            }
            if (g.cursor.col + 1 >= self.cols) width = 1;
        }

        if (self.flags.insert_mode) self.ich(width);
        g = self.grid();

        const attrs = self.paintAttrs();
        const cell = g.getCell(g.cursor.row, g.cursor.col);
        cell.* = .{
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
        self.last_cp = mapped;
    }

    fn mapCp(self: *const VtState, cp: u21) u21 {
        if (cp < 0x20 or cp > 0x7e) return cp;
        const set = if (self.gl == 1) self.g1 else self.g0;
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

        g.cursor.row = row;
        g.cursor.col = @min(self.cols - 1, col);
    }

    pub fn cuu(self: *VtState, count: u16) void {
        const g = self.grid();
        const top = if (self.flags.origin_mode) g.scroll_top else 0;
        const n = @min(count, g.cursor.row -| top);
        g.cursor.row -= n;
    }

    pub fn cud(self: *VtState, count: u16) void {
        const g = self.grid();
        const bot = if (self.flags.origin_mode) g.scroll_bottom else self.rows - 1;
        const n = @min(count, bot -| g.cursor.row);
        g.cursor.row += n;
    }

    pub fn cuf(self: *VtState, count: u16) void {
        const g = self.grid();
        g.cursor.col = @min(self.cols - 1, g.cursor.col +| count);
    }

    pub fn cub(self: *VtState, count: u16) void {
        const g = self.grid();
        g.cursor.col = g.cursor.col -| count;
    }

    pub fn tab(self: *VtState) void {
        const g = self.grid();
        const next_tab = (g.cursor.col & ~@as(u16, 7)) + 8;
        g.cursor.col = @min(self.cols - 1, next_tab);
    }

    pub fn tabBack(self: *VtState) void {
        const g = self.grid();
        const col = g.cursor.col;
        const prev = if (col == 0) 0 else col - 1;
        g.cursor.col = prev - (prev % 8);
    }

    pub fn goHome(self: *VtState) void {
        const g = self.grid();
        g.cursor.col = 0;
        g.cursor.row = if (self.flags.origin_mode) g.scroll_top else 0;
    }

    pub fn index(self: *VtState) void {
        const g = self.grid();
        if (g.cursor.row == g.scroll_bottom) {
            self.regionScrollUp(1);
        } else if (g.cursor.row + 1 < self.rows) {
            g.cursor.row += 1;
        }
    }

    pub fn reverseIndex(self: *VtState) void {
        const g = self.grid();
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
        g.scrollUp(g.scroll_top, g.scroll_bottom, n, self.cols);
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
        if (g.cursor.col >= self.cols) g.cursor.col = self.cols - 1;
    }

    pub fn resetPen(self: *VtState) void {
        const g = self.grid();
        g.fg = self.scheme.fg;
        g.bg = self.scheme.bg;
        g.attrs = .{};
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

    pub fn setMode(self: *VtState, params: []const u16, enable: bool) void {
        for (params) |p| {
            switch (p) {
                4 => self.flags.insert_mode = enable,
                else => {},
            }
        }
    }

    pub fn setPrivate(self: *VtState, params: []const u16, enable: bool) void {
        for (params) |p| {
            switch (p) {
                1 => self.flags.app_cursor = enable,
                6 => {
                    self.flags.origin_mode = enable;
                    self.goHome();
                },
                7 => self.flags.auto_wrap = enable,
                9 => self.mouse = if (enable) .x10 else .off,
                12 => self.flags.cursor_blink = enable,
                25 => {
                    if (self.flags.cursor_visible != enable) self.markDirty(self.grid().cursor.row);
                    self.flags.cursor_visible = enable;
                },
                47, 1047 => self.setAlt(enable, false, false),
                66 => self.flags.app_keypad = enable,
                1000 => self.mouse = if (enable) .btn else if (self.mouse == .btn) .off else self.mouse,
                1002 => self.mouse = if (enable) .drag else if (self.mouse == .drag) .off else self.mouse,
                1003 => self.mouse = if (enable) .any else if (self.mouse == .any) .off else self.mouse,
                1004 => self.flags.focus_event = enable,
                1001 => self.flags.mouse_hilite = enable,
                1006 => self.flags.mouse_sgr = enable,
                1007 => self.flags.alt_scroll = enable,
                1015 => self.flags.mouse_urxvt = enable,
                1016 => self.flags.mouse_pixels = enable,
                1048 => if (enable) self.saveCursor() else self.restoreCursor(),
                1049 => self.setAlt(enable, true, true),
                2004 => self.flags.bracket_paste = enable,
                2026 => self.flags.sync_output = enable,
                else => {},
            }
        }
    }

    pub fn setModifyKeys(self: *VtState, params: []const u16) void {
        if (params.len == 0) {
            self.modify_other_keys = 0;
            return;
        }
        if (params[0] != 4) return;
        const pv: u16 = if (params.len > 1) params[1] else 0;
        self.modify_other_keys = @intCast(@min(pv, 2));
    }

    pub fn setCursorStyle(self: *VtState, n: u16) void {
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
        self.gl = 0;
        self.last_cp = ' ';
        self.resetPen();
        const g = self.grid();
        g.saved_cursor = .{};
        g.saved_fg = self.scheme.fg;
        g.saved_bg = self.scheme.bg;
        g.saved_attrs = .{};
        g.scroll_top = 0;
        g.scroll_bottom = self.rows - 1;
        self.markDirty(g.cursor.row);
    }

    pub fn savePrivate(self: *VtState, params: []const u16) void {
        const all = params.len == 0 or (params.len == 1 and params[0] == 0);
        if (all) {
            const modes = [_]u16{ 1, 6, 7, 9, 12, 25, 47, 66, 1000, 1001, 1002, 1003, 1004, 1006, 1007, 1015, 1016, 1047, 1049, 2004, 2026 };
            for (modes) |m| self.saveOnePrivate(m);
            return;
        }
        for (params) |p| {
            if (p != 0) self.saveOnePrivate(p);
        }
    }

    fn saveOnePrivate(self: *VtState, mode: u16) void {
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

    pub fn restorePrivate(self: *VtState, params: []const u16) void {
        const all = params.len == 0 or (params.len == 1 and params[0] == 0);
        if (all) {
            for (self.saved_mode, 0..) |m, i| {
                if (self.saved_mode_val[i] != 0) self.setPrivate(&[_]u16{m}, self.saved_mode_val[i] == 1);
            }
            return;
        }
        for (params) |p| {
            if (p == 0) continue;
            for (self.saved_mode, 0..) |m, i| {
                if (m == p and self.saved_mode_val[i] != 0) {
                    self.setPrivate(&[_]u16{p}, self.saved_mode_val[i] == 1);
                    break;
                }
            }
        }
    }

    pub fn privateMode(self: *const VtState, n: u16) u16 {
        const on: bool = switch (n) {
            1 => self.flags.app_cursor,
            6 => self.flags.origin_mode,
            7 => self.flags.auto_wrap,
            9 => self.mouse == .x10,
            12 => self.flags.cursor_blink,
            25 => self.flags.cursor_visible,
            47, 1047, 1049 => self.which == 1,
            66 => self.flags.app_keypad,
            1000 => self.mouse == .btn,
            1002 => self.mouse == .drag,
            1003 => self.mouse == .any,
            1004 => self.flags.focus_event,
            1001 => self.flags.mouse_hilite,
            1006 => self.flags.mouse_sgr,
            1007 => self.flags.alt_scroll,
            1015 => self.flags.mouse_urxvt,
            1016 => self.flags.mouse_pixels,
            2004 => self.flags.bracket_paste,
            2026 => self.flags.sync_output,
            else => return 0,
        };
        return if (on) 1 else 2;
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
        if (self.kitty.feed(bytes, .{ .row = cur.row, .col = cur.col }, self.cols, self.rows, self.which)) |next| {
            const g = self.grid();
            g.cursor.row = next.row;
            g.cursor.col = next.col;
        }
        self.markDirtyAll();
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
    var params: [16]u16 = undefined;
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
