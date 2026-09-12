//! State machine, VT operations, sequence routing, and flags.

const std = @import("std");
const Term = @import("grid.zig");

const Kitty = @import("kitty.zig");
const CsiSeq = @import("csi.zig");
const EscSeq = @import("esc.zig");
const OscSeq = @import("osc.zig");
const C0 = @import("c0.zig");

const Run = @import("circbuffer.zig").Run;

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
    grids: [2]Term.Grid,
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
    scheme: Term.Scheme = .{},
    kitty: Kitty.Store,
    storage: []u8, // backing buffer to read runs of text from

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, scrollback: u32, storage: []u8) !VtState {
        const primary = try Term.Grid.init(allocator, cols, rows, scrollback);
        const alt = try Term.Grid.init(allocator, cols, rows, rows);
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
        self.grids[0].deinit(self.allocator);
        self.grids[1].deinit(self.allocator);
        self.allocator.free(self.line_dirty);
        self.kitty.deinit();
    }

    pub fn feedRuns(self: *VtState, runs: []const Run) void {
        for (runs) |run| {
            const slice = self.storage[run.off .. run.off + run.len];
            switch (run.kind) {
                .plain => {
                    for (slice) |b| {
                        self.printCodepoint(b);
                    }
                },
                .utf8 => {
                    var view = std.unicode.Utf8View.init(slice) catch continue;
                    var iter = view.iterator();
                    while (iter.nextCodepoint()) |cp| {
                        self.printCodepoint(cp);
                    }
                },
                .c0 => {
                    if (slice.len > 0) self.dispatchC0(slice[0]);
                },
                .c1 => {
                    if (slice.len > 0) self.dispatchC1(slice[0]);
                },
                .esc => self.dispatchEsc(slice),
                .csi => |csi| csi.parse(slice);
                .osc => self.dispatchOsc(slice),
                .str => {},
                .esc_kitty => unreachable,
                .esc_sixel => {}, // Reserved for Sixel graphics decoder
            }
        }
    }

    pub inline fn grid(self: *VtState) *Term.Grid {
        return &self.grids[self.which];
    }

    pub inline fn markDirty(self: *VtState, row: u16) void {
        if (row < self.rows) {
            self.line_dirty[row / 64] |= (@as(u64, 1) << @intCast(row % 64));
        }
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

    pub fn printCodepoint(self: *VtState, cp: u21) void {
        const g = self.grid();
        self.last_cp = cp;

        if (g.cursor.col >= self.cols) {
            if (self.flags.auto_wrap) {
                g.cursor.col = 0;
                if (g.cursor.row >= g.scroll_bottom) {
                    g.scrollUp(g.scroll_top, g.scroll_bottom, 1, self.cols);
                } else {
                    g.cursor.row += 1;
                }
            } else {
                g.cursor.col = self.cols - 1;
            }
        }

        if (self.flags.insert_mode) {
            g.insertCells(g.cursor.row, g.cursor.col, 1, self.cols);
        }

        g.writeCell(g.cursor.row, g.cursor.col, cp);
        self.markDirty(g.cursor.row);
        g.cursor.col += 1;
    }

    pub fn dispatchC0(self: *VtState, byte: u8) void {
        const g = self.grid();
        switch (byte) {
            0x07 => {},
            0x08 => self.cub(1),
            0x09 => {
                const next_tab = (g.cursor.col & ~@as(u16, 7)) + 8;
                g.cursor.col = @min(self.cols - 1, next_tab);
            },
            0x0A, 0x0B, 0x0C => { // LF, VT, FF (Line Feed)
                if (g.cursor.row >= g.scroll_bottom) {
                    g.scrollUp(g.scroll_top, g.scroll_bottom, 1, self.cols);
                } else {
                    g.cursor.row += 1;
                }
            },
            0x0D => g.cursor.col = 0, // CR (Carriage Return)
            0x0E => self.gl = 1, // SO (Shift Out -> G1 charset)
            0x0F => self.gl = 0, // SI (Shift In -> G0 charset)
            else => {},
        }
    }

    pub fn dispatchC1(self: *VtState, byte: u8) void {
        switch (byte) {
            0x84 => self.dispatchC0(0x0A), // IND (Index)
            0x85 => { // NEL (Next Line)
                self.grid().cursor.col = 0;
                self.dispatchC0(0x0A);
            },
            0x88 => {}, // HTS (Horizontal Tab Set)
            0x8D => { // RI (Reverse Index / Scroll Down)
                const g = self.grid();
                if (g.cursor.row <= g.scroll_top) {
                    g.scrollDown(g.scroll_top, g.scroll_bottom, 1, self.cols);
                } else {
                    g.cursor.row -= 1;
                }
            },
            else => {},
        }
    }

    pub fn ed(self: *VtState, mode: u8) void {
        const g = self.grid();
        switch (mode) {
            0 => { // Erase from cursor to end of screen
                g.clearRange(g.cursor.row, g.cursor.col, self.cols, self.cols);
                self.markDirty(g.cursor.row);
                var r = g.cursor.row + 1;
                while (r < self.rows) : (r += 1) {
                    g.clearRange(r, 0, self.cols, self.cols);
                    self.markDirty(r);
                }
            },
            1 => { // Erase from start of screen to cursor
                var r: u16 = 0;
                while (r < g.cursor.row) : (r += 1) {
                    g.clearRange(r, 0, self.cols, self.cols);
                    self.markDirty(r);
                }
                g.clearRange(g.cursor.row, 0, g.cursor.col + 1, self.cols);
                self.markDirty(g.cursor.row);
            },
            2, 3 => { // Erase complete screen
                var r: u16 = 0;
                while (r < self.rows) : (r += 1) {
                    g.clearRange(r, 0, self.cols, self.cols);
                    self.markDirty(r);
                }
            },
            else => {},
        }
    }

    pub fn el(self: *VtState, mode: u8) void {
        const g = self.grid();
        switch (mode) {
            0 => g.clearRange(g.cursor.row, g.cursor.col, self.cols, self.cols),
            1 => g.clearRange(g.cursor.row, 0, g.cursor.col + 1, self.cols),
            2 => g.clearRange(g.cursor.row, 0, self.cols, self.cols),
            else => return,
        }
        self.markDirty(g.cursor.row);
    }
};
