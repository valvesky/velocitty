//! Minimal state modern terminal emulator designed to be fed preparsed runs
//! for optimal parsing speeds.

const std = @import("std");
const assert = std.debug.assert;

const Kitty = @import("kitty.zig");
const EastAsian = @import("type/eastasian.zig");
const CsiSeq = @import("csi.zig");

const Platform = @import("platform/platform.zig");


pub const Color = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const default_fg: Color = .{ .r = 170, .g = 170, .b = 170 };
    pub const default_bg: Color = .{ .r = 0, .g = 0, .b = 0 };
};

pub const vga_palette = [_]Color{
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 170, .g = 0, .b = 0 },
    .{ .r = 0, .g = 170, .b = 0 },
    .{ .r = 170, .g = 85, .b = 0 },
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
    _padding: u7 = 0, // Fill remaining bits up to u16
};

pub const CursorStyle = enum(u8) {
    block,
    underline,
    bar,
};

const Charset = enum { ascii, dec_special };

pub const Cell = packed struct {
    codepoint: u21 = ' ',
    attrs: Attrs = .{},
    _pad: u2 = 0,
    fg: Color = Color.default_fg,
    bg: Color = Color.default_bg,
};

pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
};

pub const default_scrollback: u32 = 256;

const Grid = struct {
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
};

inline fn decodeUtf8At(bytes: []const u8, j: usize) struct { cp: u21, n: usize } {
    const n = std.unicode.utf8ByteSequenceLength(bytes[j]) catch return .{ .cp = 0xFFFD, .n = 1 };
    if (j + n > bytes.len) return .{ .cp = 0xFFFD, .n = 1 };
    const cp = std.unicode.utf8Decode(bytes[j..][0..n]) catch 0xFFFD;
    return .{ .cp = cp, .n = n };
}

pub const Term = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    cap: u32,
    grids: [2]Grid,
    which: u1 = 0,
    origin_mode: bool = false,
    auto_wrap: bool = true,
    insert_mode: bool = false,
    cursor_visible: bool = true,
    cursor_style: CursorStyle = .block,
    cursor_blink: bool = false,
    app_cursor: bool = false,
    app_keypad: bool = false,
    mouse: Events.MouseTracking = .off,
    mouse_sgr: bool = false,
    mouse_urxvt: bool = false,
    mouse_pixels: bool = false,
    mouse_hilite: bool = false,
    focus_event: bool = false,
    bracket_paste: bool = false,
    alt_scroll: bool = false,
    sync_output: bool = false,
    modify_other_keys: u8 = 0,
    osc8: bool = false,
    g0: Charset = .ascii,
    g1: Charset = .ascii,
    gl: u1 = 0,
    last_cp: u21 = ' ',
    saved_mode: [16]u16 = @splat(0),
    saved_mode_val: [16]u8 = @splat(0),
    line_dirty: []u64,
    scheme: Scheme = .{},
    kitty: Kitty.Store,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) std.mem.Allocator.Error!Term {
        return initScrollback(allocator, cols, rows, default_scrollback);
    }

    pub fn initScrollback(allocator: std.mem.Allocator, cols: u16, rows: u16, extra: u32) std.mem.Allocator.Error!Term {
        return initWithScheme(allocator, cols, rows, extra, .{});
    }

    pub fn initWithScheme(allocator: std.mem.Allocator, cols: u16, rows: u16, extra: u32, scheme: Scheme) std.mem.Allocator.Error!Term {
        assert(cols > 0);
        assert(rows > 0);
        const primary_cap = @as(u32, rows) + extra;
        const alt_cap = @as(u32, rows);
        const p_cells = try allocator.alloc(Cell, @as(usize, cols) * primary_cap);
        errdefer allocator.free(p_cells);
        const p_starts = try allocator.alloc(u32, primary_cap);
        errdefer allocator.free(p_starts);
        const a_cells = try allocator.alloc(Cell, @as(usize, cols) * alt_cap);
        errdefer allocator.free(a_cells);
        const a_starts = try allocator.alloc(u32, alt_cap);
        errdefer allocator.free(a_starts);
        const line_dirty = try allocator.alloc(u64, dirtyWords(rows));
        errdefer allocator.free(line_dirty);
        @memset(line_dirty, std.math.maxInt(u64));
        return .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .cap = primary_cap,
            .grids = .{
                makeGrid(p_cells, p_starts, primary_cap, cols, rows, scheme),
                makeGrid(a_cells, a_starts, alt_cap, cols, rows, scheme),
            },
            .line_dirty = line_dirty,
            .scheme = scheme,
            .kitty = Kitty.Store.init(allocator),
        };
    }

    pub fn deinit(self: *Term) void {
        self.kitty.deinit();
        self.allocator.free(self.line_dirty);
        self.allocator.free(self.grids[1].starts);
        self.allocator.free(self.grids[1].cells);
        self.allocator.free(self.grids[0].starts);
        self.allocator.free(self.grids[0].cells);
        self.* = undefined;
    }

    pub fn resize(self: *Term, cols: u16, rows: u16) std.mem.Allocator.Error!void {
        assert(cols > 0);
        assert(rows > 0);
        if (cols == self.cols and rows == self.rows) return;
        const extra = self.cap - self.rows;
        const next = try initWithScheme(self.allocator, cols, rows, extra, self.scheme);
        self.deinit();
        self.* = next;
    }

    pub fn clear(self: *Term) void {
        self.which = 0;
        self.origin_mode = false;
        self.auto_wrap = true;
        self.insert_mode = false;
        self.cursor_visible = true;
        self.cursor_style = .block;
        self.cursor_blink = false;
        self.app_cursor = false;
        self.app_keypad = false;
        self.mouse = .off;
        self.mouse_sgr = false;
        self.mouse_urxvt = false;
        self.mouse_pixels = false;
        self.mouse_hilite = false;
        self.focus_event = false;
        self.bracket_paste = false;
        self.alt_scroll = false;
        self.sync_output = false;
        self.modify_other_keys = 0;
        self.osc8 = false;
        self.saved_mode = @splat(0);
        self.saved_mode_val = @splat(0);
        self.g0 = .ascii;
        self.g1 = .ascii;
        self.gl = 0;
        self.last_cp = ' ';
        self.kitty.clear();
        self.resetGrid(0);
        self.resetGrid(1);
    }

    pub fn cell(self: *const Term, row: u16, col: u16) Cell {
        assert(row < self.rows);
        assert(col < self.cols);
        return self.viewSlice(row)[col];
    }

    pub fn rowCells(self: *const Term, row: u16) []const Cell {
        return self.viewSlice(row);
    }

    /// Visual dump: every cell as UTF-8, NUL continuation as space, trailing
    /// spaces kept, rows joined by `\n` (no trailing newline after the last row).
    pub fn dumpAlloc(self: *const Term, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
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

    /// One line per non-blank cell: `y x U+XXXX #rrggbb #rrggbb ATTRS`.
    pub fn dumpCellsAlloc(self: *const Term, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var y: u16 = 0;
        while (y < self.rows) : (y += 1) {
            const line = self.rowCells(y);
            var x: u16 = 0;
            while (x < self.cols) : (x += 1) {
                const c = line[x];
                if (self.cellIsBlank(c)) continue;
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

    fn cellIsBlank(self: *const Term, c: Cell) bool {
        if (c.codepoint != ' ' and c.codepoint != 0) return false;
        if (c.fg.r != self.scheme.fg.r or c.fg.g != self.scheme.fg.g or c.fg.b != self.scheme.fg.b) return false;
        if (c.bg.r != self.scheme.bg.r or c.bg.g != self.scheme.bg.g or c.bg.b != self.scheme.bg.b) return false;
        const z: Attrs = .{};
        return std.meta.eql(c.attrs, z);
    }

    pub fn lineDirty(self: *const Term, row: u16) bool {
        assert(row < self.rows);
        const i = row / 64;
        const b: u6 = @intCast(row % 64);
        return self.line_dirty[i] & (@as(u64, 1) << b) != 0;
    }

    pub fn clearDirty(self: *Term) void {
        @memset(self.line_dirty, 0);
    }

    fn markDirty(self: *Term, row: u16) void {
        assert(row < self.rows);
        const i = row / 64;
        const b: u6 = @intCast(row % 64);
        self.line_dirty[i] |= @as(u64, 1) << b;
    }

    fn markDirtyAll(self: *Term) void {
        @memset(self.line_dirty, std.math.maxInt(u64));
    }

    pub fn cursor(self: *const Term) Cursor {
        return self.gridConst().cursor;
    }

    pub fn cursorVisible(self: *const Term) bool {
        return self.cursor_visible;
    }

    pub fn cursorStyle(self: *const Term) CursorStyle {
        return self.cursor_style;
    }

    pub fn altTerm(self: *const Term) bool {
        return self.which == 1;
    }

    pub fn inputMode(self: *const Term) Events.InputMode {
        return .{
            .app_cursor = self.app_cursor,
            .app_keypad = self.app_keypad,
            .mouse = self.mouse,
            .mouse_sgr = self.mouse_sgr,
            .mouse_urxvt = self.mouse_urxvt,
            .mouse_pixels = self.mouse_pixels,
            .focus_event = self.focus_event,
            .bracket_paste = self.bracket_paste,
            .alt_scroll = self.alt_scroll,
            .modify_other_keys = self.modify_other_keys,
        };
    }

    pub fn scrollOffset(self: *const Term) u32 {
        return self.gridConst().scroll;
    }

    pub fn setScrollOffset(self: *Term, v: u32) void {
        const g = self.grid();
        const n = @min(v, self.scrollMax());
        if (g.scroll == n) return;
        g.scroll = n;
        self.markDirtyAll();
    }

    pub fn scrollMax(self: *const Term) u32 {
        return self.gridConst().used - self.rows;
    }

    pub fn scrollBy(self: *Term, delta: i32) void {
        const max = self.scrollMax();
        const g = self.grid();
        const old = g.scroll;
        if (delta >= 0) {
            g.scroll = @min(g.scroll + @as(u32, @intCast(delta)), max);
        } else {
            g.scroll -|= @as(u32, @intCast(-delta));
        }
        if (g.scroll != old) self.markDirtyAll();
    }

    pub fn lineFeed(self: *Term) void {
        self.grid().cursor.col = 0;
        self.index();
    }

    pub fn feed(self: *Term, items: []const Run, src: []const u8) void {
        for (items) |run| {
            const bytes = src[run.off .. run.off + run.len];
            switch (run.kind) {
                .plain => self.feedPlain(bytes),
                .utf8 => self.feedUtf8(bytes),
                .c0 => self.feedC0(bytes),
                .esc => self.feedEsc(bytes),
                .csi => self.feedCsi(bytes),
                .osc => self.feedOsc(bytes),
                .esc_kitty => self.feedKitty(bytes),
                .c1, .str, .esc_sixel => {},
            }
        }
    }

    fn feedKitty(self: *Term, bytes: []const u8) void {
        const cur = self.grid().cursor;
        const which = self.which;
        if (self.kitty.feed(bytes, .{ .row = cur.row, .col = cur.col }, self.cols, self.rows, which)) |next| {
            const g = self.grid();
            g.cursor.row = next.row;
            g.cursor.col = next.col;
        }
        self.markDirtyAll();
    }

    fn feedPlain(self: *Term, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const set = if (self.gl == 1) self.g1 else self.g0;
        if (self.insert_mode or set == .dec_special) {
            for (bytes) |c| self.put(c);
            return;
        }
        var i: usize = 0;
        while (i < bytes.len) {
            var g = self.grid();
            if (g.cursor.col >= self.cols) {
                if (self.auto_wrap) {
                    g.cursor.col = 0;
                    self.index();
                    g = self.grid();
                } else {
                    g.cursor.col = self.cols - 1;
                    self.put(bytes[i]);
                    i += 1;
                    continue;
                }
            }
            const room: usize = self.cols - g.cursor.col;
            const n = @min(bytes.len - i, room);
            const line = self.liveSlice(g.cursor.row);
            const fg = g.fg;
            const bg = g.bg;
            const attrs = self.paintAttrs();
            const col = g.cursor.col;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                line[col + k] = .{
                    .codepoint = bytes[i + k],
                    .fg = fg,
                    .bg = bg,
                    .attrs = attrs,
                };
            }
            g.cursor.col = @intCast(col + n);
            self.last_cp = bytes[i + n - 1];
            i += n;
        }
    }

    fn feedUtf8(self: *Term, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (self.insert_mode) {
            var j: usize = 0;
            while (j < bytes.len) {
                const d = decodeUtf8At(bytes, j);
                self.put(d.cp);
                j += d.n;
            }
            return;
        }
        var j: usize = 0;
        var g = self.grid();
        var line = self.liveSlice(g.cursor.row);
        var col = g.cursor.col;
        const fg = g.fg;
        const bg = g.bg;
        const attrs = self.paintAttrs();
        const cell_base = Cell{ .codepoint = 0, .fg = fg, .bg = bg, .attrs = attrs };
        while (j < bytes.len) {
            if (col >= self.cols) {
                if (self.auto_wrap) {
                    g.cursor.col = 0;
                    self.index();
                    g = self.grid();
                    line = self.liveSlice(g.cursor.row);
                    col = 0;
                } else {
                    g.cursor.col = self.cols - 1;
                    const d = decodeUtf8At(bytes, j);
                    self.put(d.cp);
                    j += d.n;
                    g = self.grid();
                    line = self.liveSlice(g.cursor.row);
                    col = g.cursor.col;
                    continue;
                }
            }
            if (j + 3 <= bytes.len and col + 2 <= self.cols) {
                const b0 = bytes[j];
                if (b0 >= 0xE0 and b0 <= 0xEF) {
                    const b1 = bytes[j + 1];
                    const b2 = bytes[j + 2];
                    if (b1 & 0xC0 == 0x80 and b2 & 0xC0 == 0x80) {
                        const cp: u21 = (@as(u21, b0 & 0x0F) << 12) |
                            (@as(u21, b1 & 0x3F) << 6) |
                            (b2 & 0x3F);
                        if (EastAsian.cellWidth(cp) == 2) {
                            line[col] = .{ .codepoint = cp, .fg = fg, .bg = bg, .attrs = attrs };
                            line[col + 1] = cell_base;
                            col += 2;
                            self.last_cp = cp;
                            j += 3;
                            continue;
                        }
                    }
                }
            }
            const d = decodeUtf8At(bytes, j);
            var width: u16 = @max(1, EastAsian.cellWidth(d.cp));
            if (width == 2 and col + 1 >= self.cols) {
                if (self.auto_wrap and col != 0) {
                    g.cursor.col = 0;
                    self.index();
                    g = self.grid();
                    line = self.liveSlice(g.cursor.row);
                    col = 0;
                }
                if (col + 1 >= self.cols) width = 1;
            }
            line[col] = .{ .codepoint = d.cp, .fg = fg, .bg = bg, .attrs = attrs };
            if (width == 2 and col + 1 < self.cols) {
                line[col + 1] = cell_base;
            }
            col += width;
            self.last_cp = d.cp;
            j += d.n;
        }
        self.grid().cursor.col = col;
    }

    fn put(self: *Term, cp: u21) void {
        const mapped = self.mapCp(cp);
        var width: u16 = @max(1, EastAsian.cellWidth(mapped));
        var g = self.grid();
        if (g.cursor.col >= self.cols) {
            if (self.auto_wrap) {
                g.cursor.col = 0;
                self.index();
                g = self.grid();
            } else {
                g.cursor.col = self.cols - 1;
                width = 1;
            }
        }
        if (width == 2 and g.cursor.col + 1 >= self.cols) {
            if (self.auto_wrap and g.cursor.col != 0) {
                g.cursor.col = 0;
                self.index();
                g = self.grid();
            }
            if (g.cursor.col + 1 >= self.cols) width = 1;
        }
        if (self.insert_mode) self.ich(width);
        g = self.grid();
        const line = self.liveSlice(g.cursor.row);
        const attrs = self.paintAttrs();
        line[g.cursor.col] = .{
            .codepoint = mapped,
            .fg = g.fg,
            .bg = g.bg,
            .attrs = attrs,
        };
        if (width == 2 and g.cursor.col + 1 < self.cols) {
            line[g.cursor.col + 1] = .{
                .codepoint = 0,
                .fg = g.fg,
                .bg = g.bg,
                .attrs = attrs,
            };
        }
        g.cursor.col += width;
        self.last_cp = mapped;
    }

    fn mapCp(self: *const Term, cp: u21) u21 {
        if (cp < 0x20 or cp > 0x7e) return cp;
        const set = if (self.gl == 1) self.g1 else self.g0;
        if (set != .dec_special) return cp;
        return decSpecial(cp);
    }

    fn paintAttrs(self: *const Term) Attrs {
        var a = self.gridConst().attrs;
        a.link = self.osc8;
        return a;
    }

    fn eraseCell(self: *const Term) Cell {
        const g = self.gridConst();
        return .{ .fg = g.fg, .bg = g.bg };
    }

    fn feedOsc(self: *Term, bytes: []const u8) void {
        if (bytes.len < 4 or bytes[0] != 0x1b or bytes[1] != ']') return;
        var i: usize = 2;
        var id: u16 = 0;
        var have = false;
        while (i < bytes.len) : (i += 1) {
            const c = bytes[i];
            if (c >= '0' and c <= '9') {
                have = true;
                id = id *% 10 +% (c - '0');
            } else break;
        }
        if (!have or id != 8) return;
        if (i >= bytes.len or bytes[i] != ';') return;
        i += 1;
        while (i < bytes.len and bytes[i] != ';') i += 1;
        if (i >= bytes.len or bytes[i] != ';') return;
        i += 1;
        const uri_start = i;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == 0x07 or bytes[i] == 0x1b) break;
        }
        self.osc8 = i > uri_start;
    }

    fn feedC0(self: *Term, bytes: []const u8) void {
        for (bytes) |c| {
            switch (c) {
                '\n', 0x0b, 0x0c => self.lineFeed(),
                '\r' => self.grid().cursor.col = 0,
                0x08 => self.grid().cursor.col -|= 1,
                '\t' => {
                    const g = self.grid();
                    g.cursor.col += 8 - (g.cursor.col % 8);
                    if (g.cursor.col >= self.cols) g.cursor.col = self.cols - 1;
                },
                0x0e => self.gl = 1,
                0x0f => self.gl = 0,
                else => {},
            }
        }
    }

    fn feedEsc(self: *Term, bytes: []const u8) void {
        if (bytes.len < 2) return;
        switch (bytes[1]) {
            'D' => self.index(),
            'E' => self.lineFeed(),
            'M' => self.reverseIndex(),
            '7' => self.saveCursor(),
            '8' => self.restoreCursor(),
            'c' => self.clear(),
            '=' => self.app_keypad = true,
            '>' => self.app_keypad = false,
            '(' => if (bytes.len >= 3) {
                self.g0 = charsetOf(bytes[2]);
            },
            ')' => if (bytes.len >= 3) {
                self.g1 = charsetOf(bytes[2]);
            },
            else => {},
        }
    }

    fn feedCsi(self: *Term, bytes: []const u8) void {
        if (CsiSeq.parse(bytes)) |seq| {
            seq.apply(self);
        }
    }

    fn setPrivate(self: *Term, params: []const u16, enable: bool) void {
        for (params) |p| {
            switch (p) {
                1 => self.app_cursor = enable,
                6 => {
                    self.origin_mode = enable;
                    self.goHome();
                },
                7 => self.auto_wrap = enable,
                9 => self.mouse = if (enable) .x10 else .off,
                12 => self.cursor_blink = enable,
                25 => {
                    if (self.cursor_visible != enable) self.markDirty(self.grid().cursor.row);
                    self.cursor_visible = enable;
                },
                47, 1047 => self.setAlt(enable, false, false),
                66 => self.app_keypad = enable,
                1000 => self.mouse = if (enable) .btn else if (self.mouse == .btn) .off else self.mouse,
                1002 => self.mouse = if (enable) .drag else if (self.mouse == .drag) .off else self.mouse,
                1003 => self.mouse = if (enable) .any else if (self.mouse == .any) .off else self.mouse,
                1004 => self.focus_event = enable,
                1001 => self.mouse_hilite = enable,
                1006 => self.mouse_sgr = enable,
                1007 => self.alt_scroll = enable,
                1015 => self.mouse_urxvt = enable,
                1016 => self.mouse_pixels = enable,
                1048 => if (enable) self.saveCursor() else self.restoreCursor(),
                1049 => self.setAlt(enable, true, true),
                2004 => self.bracket_paste = enable,
                2026 => self.sync_output = enable,
                else => {},
            }
        }
    }

    fn setMode(self: *Term, params: []const u16, enable: bool) void {
        for (params) |p| {
            switch (p) {
                4 => self.insert_mode = enable,
                else => {},
            }
        }
    }

    fn setModifyKeys(self: *Term, params: []const u16) void {
        if (params.len == 0) {
            self.modify_other_keys = 0;
            return;
        }
        if (params[0] != 4) return;
        const pv: u16 = if (params.len > 1) params[1] else 0;
        self.modify_other_keys = @intCast(@min(pv, 2));
    }

    fn savePrivate(self: *Term, params: []const u16) void {
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

    fn saveOnePrivate(self: *Term, mode: u16) void {
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

    fn restorePrivate(self: *Term, params: []const u16) void {
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

    fn setCursorStyle(self: *Term, n: u16) void {
        const style: CursorStyle = switch (n) {
            0, 1, 2 => .block,
            3, 4 => .underline,
            5, 6 => .bar,
            else => return,
        };
        const blink = n == 0 or n == 1 or n == 3 or n == 5;
        if (self.cursor_style == style and self.cursor_blink == blink) return;
        self.cursor_style = style;
        self.cursor_blink = blink;
        self.markDirty(self.grid().cursor.row);
    }

    fn softReset(self: *Term) void {
        self.origin_mode = false;
        self.auto_wrap = true;
        self.insert_mode = false;
        self.cursor_visible = true;
        self.cursor_style = .block;
        self.cursor_blink = false;
        self.app_cursor = false;
        self.app_keypad = false;
        self.g0 = .ascii;
        self.g1 = .ascii;
        self.gl = 0;
        self.last_cp = ' ';
        const g = self.grid();
        g.fg = self.scheme.fg;
        g.bg = self.scheme.bg;
        g.attrs = .{};
        g.saved_cursor = .{};
        g.saved_fg = self.scheme.fg;
        g.saved_bg = self.scheme.bg;
        g.saved_attrs = .{};
        g.scroll_top = 0;
        g.scroll_bottom = self.rows - 1;
        self.markDirty(g.cursor.row);
    }

    fn eraseScrollback(self: *Term) void {
        const g = self.grid();
        if (g.used <= self.rows) return;
        g.head = (g.head + (g.used - self.rows)) % g.cap;
        g.used = self.rows;
        g.scroll = 0;
        self.markDirtyAll();
    }

    pub fn privateMode(self: *const Term, n: u16) u16 {
        const on: bool = switch (n) {
            1 => self.app_cursor,
            6 => self.origin_mode,
            7 => self.auto_wrap,
            9 => self.mouse == .x10,
            12 => self.cursor_blink,
            25 => self.cursor_visible,
            47, 1047, 1049 => self.which == 1,
            66 => self.app_keypad,
            1000 => self.mouse == .btn,
            1002 => self.mouse == .drag,
            1003 => self.mouse == .any,
            1004 => self.focus_event,
            1001 => self.mouse_hilite,
            1006 => self.mouse_sgr,
            1007 => self.alt_scroll,
            1015 => self.mouse_urxvt,
            1016 => self.mouse_pixels,
            2004 => self.bracket_paste,
            2026 => self.sync_output,
            else => return 0,
        };
        return if (on) 1 else 2;
    }

    pub fn ansiMode(self: *const Term, n: u16) u16 {
        return switch (n) {
            4 => if (self.insert_mode) 1 else 2,
            else => 0,
        };
    }

    fn sgrString(self: *const Term, out: []u8) []const u8 {
        const g = self.gridConst();
        var n: usize = 0;
        const add = struct {
            fn go(buf: []u8, i: *usize, s: []const u8) void {
                if (i.* + s.len > buf.len) return;
                @memcpy(buf[i.*..][0..s.len], s);
                i.* += s.len;
            }
        }.go;
        add(out, &n, "0");
        if (g.attrs.bold) add(out, &n, ";1");
        if (g.attrs.dim) add(out, &n, ";2");
        if (g.attrs.italic) add(out, &n, ";3");
        if (g.attrs.underline) add(out, &n, ";4");
        if (g.attrs.blink) add(out, &n, ";5");
        if (g.attrs.inverse) add(out, &n, ";7");
        if (g.attrs.hidden) add(out, &n, ";8");
        if (g.attrs.strikethrough) add(out, &n, ";9");
        if (g.fg != self.scheme.fg) {
            var tmp: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, ";38;2;{d};{d};{d}", .{ g.fg.r, g.fg.g, g.fg.b }) catch "";
            add(out, &n, s);
        }
        if (g.bg != self.scheme.bg) {
            var tmp: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, ";48;2;{d};{d};{d}", .{ g.bg.r, g.bg.g, g.bg.b }) catch "";
            add(out, &n, s);
        }
        return out[0..n];
    }

    fn setAlt(self: *Term, on: bool, save: bool, wipe: bool) void {
        if (on) {
            if (self.which == 1) return;
            if (save) self.saveCursor();
            self.which = 1;
            if (wipe) self.resetGrid(1);
        } else {
            if (self.which == 0) return;
            self.which = 0;
            if (save) self.restoreCursor();
        }
        self.markDirtyAll();
    }

    fn saveCursor(self: *Term) void {
        const g = self.grid();
        g.saved_cursor = g.cursor;
        g.saved_fg = g.fg;
        g.saved_bg = g.bg;
        g.saved_attrs = g.attrs;
    }

    fn restoreCursor(self: *Term) void {
        const g = self.grid();
        g.cursor = g.saved_cursor;
        g.fg = g.saved_fg;
        g.bg = g.saved_bg;
        g.attrs = g.saved_attrs;
        if (g.cursor.row >= self.rows) g.cursor.row = self.rows - 1;
        if (g.cursor.col >= self.cols) g.cursor.col = self.cols - 1;
    }

    fn goHome(self: *Term) void {
        const g = self.grid();
        g.cursor.col = 0;
        g.cursor.row = if (self.origin_mode) g.scroll_top else 0;
    }

    fn cup(self: *Term, row1: u16, col1: u16) void {
        const g = self.grid();
        var row: u16 = row1 -| 1;
        var col: u16 = col1 -| 1;
        if (self.origin_mode) {
            row = g.scroll_top +| row;
            if (row > g.scroll_bottom) row = g.scroll_bottom;
        } else if (row >= self.rows) {
            row = self.rows - 1;
        }
        if (col >= self.cols) col = self.cols - 1;
        g.cursor.row = row;
        g.cursor.col = col;
    }

    fn cursorUp(self: *Term, n: u16) void {
        const g = self.grid();
        g.cursor.row -|= n;
        const floor: u16 = if (self.origin_mode) g.scroll_top else 0;
        if (g.cursor.row < floor) g.cursor.row = floor;
    }

    fn cursorDown(self: *Term, n: u16) void {
        const g = self.grid();
        const limit: u16 = if (self.origin_mode) g.scroll_bottom else self.rows - 1;
        g.cursor.row = @min(g.cursor.row + n, limit);
    }

    fn decstbm(self: *Term, top1: u16, bot1: u16) void {
        const top: u16 = if (top1 == 0) 1 else top1;
        const bot: u16 = if (bot1 == 0) self.rows else bot1;
        if (top > bot or bot > self.rows) return;
        const g = self.grid();
        g.scroll_top = top - 1;
        g.scroll_bottom = bot - 1;
        self.goHome();
    }

    fn index(self: *Term) void {
        const g = self.grid();
        if (g.cursor.row == g.scroll_bottom) {
            self.regionScrollUp(1);
        } else if (g.cursor.row + 1 < self.rows) {
            g.cursor.row += 1;
        }
    }

    fn reverseIndex(self: *Term) void {
        const g = self.grid();
        if (g.cursor.row == g.scroll_top) {
            self.regionScrollDown(1);
        } else if (g.cursor.row > 0) {
            g.cursor.row -= 1;
        }
    }

    fn ed(self: *Term, mode: u16) void {
        const blank = self.eraseCell();
        switch (mode) {
            0 => {
                const col = @min(@as(usize, self.grid().cursor.col), self.cols);
                @memset(self.liveSlice(self.grid().cursor.row)[col..], blank);
                var r = self.grid().cursor.row + 1;
                while (r < self.rows) : (r += 1) @memset(self.liveSlice(r), blank);
            },
            1 => {
                var r: u16 = 0;
                while (r < self.grid().cursor.row) : (r += 1) @memset(self.liveSlice(r), blank);
                const col = @min(@as(usize, self.grid().cursor.col) + 1, self.cols);
                @memset(self.liveSlice(self.grid().cursor.row)[0..col], blank);
            },
            3 => self.eraseScrollback(),
            else => {
                var r: u16 = 0;
                while (r < self.rows) : (r += 1) @memset(self.liveSlice(r), blank);
            },
        }
    }

    fn el(self: *Term, mode: u16) void {
        const line = self.liveSlice(self.grid().cursor.row);
        const blank = self.eraseCell();
        switch (mode) {
            0 => {
                const col = @min(@as(usize, self.grid().cursor.col), line.len);
                @memset(line[col..], blank);
            },
            1 => {
                const col = @min(@as(usize, self.grid().cursor.col) + 1, line.len);
                @memset(line[0..col], blank);
            },
            else => @memset(line, blank),
        }
    }

    fn takeColor(self: *Term, rest: []const u16, fg: bool) usize {
        if (rest.len == 0) return 0;
        if (rest[0] == 5) {
            if (rest.len < 2) return rest.len;
            const c = indexedColor(self, rest[1]);
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

    fn setRgb(self: *Term, r: u16, g: u16, b: u16, fg: bool) void {
        const c = Color{
            .r = clip(r),
            .g = clip(g),
            .b = clip(b),
        };
        if (fg) self.grid().fg = c else self.grid().bg = c;
    }

    fn ich(self: *Term, n: u16) void {
        const line = self.rowSlice(self.grid().cursor.row);
        const col = @as(usize, self.grid().cursor.col);
        const count = @min(@as(usize, n), line.len - col);
        if (count == 0) return;
        std.mem.copyBackwards(Cell, line[col + count ..], line[col .. line.len - count]);
        @memset(line[col .. col + count], self.eraseCell());
    }

    fn dch(self: *Term, n: u16) void {
        const line = self.rowSlice(self.grid().cursor.row);
        const col = @as(usize, self.grid().cursor.col);
        const count = @min(@as(usize, n), line.len - col);
        if (count == 0) return;
        std.mem.copyForwards(Cell, line[col .. line.len - count], line[col + count ..]);
        @memset(line[line.len - count ..], self.eraseCell());
    }

    fn ech(self: *Term, n: u16) void {
        const line = self.rowSlice(self.grid().cursor.row);
        const col = @as(usize, self.grid().cursor.col);
        const count = @min(@as(usize, n), line.len - col);
        @memset(line[col .. col + count], self.eraseCell());
    }

    fn il(self: *Term, n: u16) void {
        const g = self.grid();
        if (g.cursor.row < g.scroll_top or g.cursor.row > g.scroll_bottom) return;
        var k: u16 = 0;
        while (k < n) : (k += 1) {
            var r = g.scroll_bottom;
            while (r > g.cursor.row) : (r -= 1) {
                @memcpy(self.liveSlice(r), self.liveSlice(r - 1));
            }
            @memset(self.liveSlice(g.cursor.row), self.eraseCell());
        }
    }

    fn dl(self: *Term, n: u16) void {
        const g = self.grid();
        if (g.cursor.row < g.scroll_top or g.cursor.row > g.scroll_bottom) return;
        var k: u16 = 0;
        while (k < n) : (k += 1) {
            var r = g.cursor.row;
            while (r < g.scroll_bottom) : (r += 1) {
                @memcpy(self.liveSlice(r), self.liveSlice(r + 1));
            }
            @memset(self.liveSlice(g.scroll_bottom), self.eraseCell());
        }
    }

    fn rep(self: *Term, n: u16) void {
        const cp = self.last_cp;
        var k: u16 = 0;
        while (k < n) : (k += 1) self.put(cp);
    }

    fn rowSlice(self: *Term, row: u16) []Cell {
        return self.liveSlice(row);
    }

    fn liveSlice(self: *Term, row: u16) []Cell {
        assert(row < self.rows);
        self.markDirty(row);
        const g = self.grid();
        const off = self.startAt(g, g.used - self.rows + row);
        return g.cells[off .. off + self.cols];
    }

    fn viewSlice(self: *const Term, row: u16) []const Cell {
        assert(row < self.rows);
        const g = self.gridConst();
        const sc = @min(g.scroll, g.used - self.rows);
        const off = self.startAt(g, g.used - self.rows - sc + row);
        return g.cells[off .. off + self.cols];
    }

    fn startAt(_: *const Term, g: *const Grid, logical: u32) u32 {
        assert(logical < g.used);
        return g.starts[(g.head + logical) % g.cap];
    }

    fn regionScrollUp(self: *Term, n: u16) void {
        var k: u16 = 0;
        while (k < n) : (k += 1) {
            const g = self.grid();
            if (g.scroll_top == 0 and g.scroll_bottom + 1 == self.rows) {
                self.ringScrollUp();
                continue;
            }
            var r = g.scroll_top;
            while (r < g.scroll_bottom) : (r += 1) {
                @memcpy(self.liveSlice(r), self.liveSlice(r + 1));
            }
            @memset(self.liveSlice(g.scroll_bottom), self.eraseCell());
        }
    }

    fn regionScrollDown(self: *Term, n: u16) void {
        var k: u16 = 0;
        while (k < n) : (k += 1) {
            const g = self.grid();
            if (g.scroll_top == 0 and g.scroll_bottom + 1 == self.rows) {
                self.scrollDown();
                continue;
            }
            var r = g.scroll_bottom;
            while (r > g.scroll_top) : (r -= 1) {
                @memcpy(self.liveSlice(r), self.liveSlice(r - 1));
            }
            @memset(self.liveSlice(g.scroll_top), self.eraseCell());
        }
    }

    fn resetPen(self: *Term) void {
        const g = self.grid();
        g.fg = self.scheme.fg;
        g.bg = self.scheme.bg;
        g.attrs = .{};
    }

    fn ringScrollUp(self: *Term) void {
        const g = self.grid();
        const live = g.scroll == 0;
        const slot = if (g.used < g.cap)
            (g.head + g.used) % g.cap
        else blk: {
            const s = g.head;
            g.head = (g.head + 1) % g.cap;
            break :blk s;
        };
        if (g.used < g.cap) g.used += 1;
        const off = g.starts[slot];
        @memset(g.cells[off .. off + self.cols], self.eraseCell());
        if (g.scroll != 0) g.scroll = @min(g.scroll + 1, self.scrollMax());
        if (live) self.markDirtyAll();
        self.kitty.scrollUp(self.which, if (self.which == 0) self.cap - self.rows else 0);
    }

    fn scrollDown(self: *Term) void {
        if (self.rows == 1) {
            @memset(self.liveSlice(0), self.eraseCell());
            return;
        }
        var r = self.rows - 1;
        while (r > 0) : (r -= 1) {
            @memcpy(self.liveSlice(r), self.liveSlice(r - 1));
        }
        @memset(self.liveSlice(0), self.eraseCell());
    }

    fn resetGrid(self: *Term, i: u1) void {
        const g = &self.grids[i];
        @memset(g.cells, .{ .fg = self.scheme.fg, .bg = self.scheme.bg });
        for (g.starts, 0..) |*s, idx| s.* = @intCast(idx * self.cols);
        g.head = 0;
        g.used = self.rows;
        g.scroll = 0;
        g.cursor = .{};
        g.fg = self.scheme.fg;
        g.bg = self.scheme.bg;
        g.attrs = .{};
        g.saved_cursor = .{};
        g.saved_fg = self.scheme.fg;
        g.saved_bg = self.scheme.bg;
        g.saved_attrs = .{};
        g.scroll_top = 0;
        g.scroll_bottom = self.rows - 1;
        self.kitty.dropTerm(i);
        self.markDirtyAll();
    }

    fn grid(self: *Term) *Grid {
        return &self.grids[self.which];
    }

    fn gridConst(self: *const Term) *const Grid {
        return &self.grids[self.which];
    }
};

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

fn append(out: []u8, n: *usize, s: []const u8) void {
    if (n.* + s.len > out.len) return;
    @memcpy(out[n.*..][0..s.len], s);
    n.* += s.len;
}

fn appendOscRgb(out: []u8, n: *usize, id: u16, color: Color) void {
    var tmp: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{
        id,
        @as(u16, color.r) * 0x101,
        @as(u16, color.g) * 0x101,
        @as(u16, color.b) * 0x101,
    }) catch return;
    append(out, n, s);
}

fn dcsPayload(bytes: []const u8) []const u8 {
    if (bytes.len < 3 or bytes[0] != 0x1b or bytes[1] != 'P') return &.{};
    var end = bytes.len;
    if (end >= 2 and bytes[end - 1] == '\\' and bytes[end - 2] == 0x1b) {
        end -= 2;
    } else if (end >= 1 and bytes[end - 1] == 0x07) {
        end -= 1;
    }
    if (end <= 2) return &.{};
    return bytes[2..end];
}

fn oscQuery(bytes: []const u8) ?u16 {
    if (bytes.len < 5 or bytes[0] != 0x1b or bytes[1] != ']') return null;
    var i: usize = 2;
    var id: u16 = 0;
    var have = false;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (c >= '0' and c <= '9') {
            have = true;
            id = id *% 10 +% (c - '0');
        } else if (c == ';') {
            if (i + 1 < bytes.len and bytes[i + 1] == '?' and have) return id;
            return null;
        } else return null;
    }
    return null;
}

fn charsetOf(c: u8) Charset {
    return if (c == '0') .dec_special else .ascii;
}

fn decSpecial(cp: u21) u21 {
    return switch (cp) {
        '`' => 0x25C6,
        'a' => 0x2592,
        'f' => 0x00B0,
        'g' => 0x00B1,
        'j' => 0x2518,
        'k' => 0x2510,
        'l' => 0x250C,
        'm' => 0x2514,
        'n' => 0x253C,
        'o' => 0x23BA,
        'p' => 0x23BB,
        'q' => 0x2500,
        'r' => 0x23BC,
        's' => 0x23BD,
        't' => 0x251C,
        'u' => 0x2524,
        'v' => 0x2534,
        'w' => 0x252C,
        'x' => 0x2502,
        'y' => 0x2264,
        'z' => 0x2265,
        '{' => 0x03C0,
        '|' => 0x2260,
        '}' => 0x00A3,
        '~' => 0x00B7,
        '_' => 0x00A0,
        else => cp,
    };
}

fn dirtyWords(rows: u16) usize {
    return (@as(usize, rows) + 63) / 64;
}

fn makeGrid(cells: []Cell, starts: []u32, cap: u32, cols: u16, rows: u16, scheme: Scheme) Grid {
    @memset(cells, .{ .fg = scheme.fg, .bg = scheme.bg });
    for (starts, 0..) |*s, i| s.* = @intCast(i * cols);
    return .{
        .cells = cells,
        .starts = starts,
        .cap = cap,
        .used = rows,
        .scroll_bottom = rows - 1,
        .fg = scheme.fg,
        .bg = scheme.bg,
        .saved_fg = scheme.fg,
        .saved_bg = scheme.bg,
    };
}

fn privateByte(bytes: []const u8) u8 {
    assert(bytes.len >= 3);
    const c = bytes[2];
    if (c >= 0x3c and c <= 0x3f) return c;
    return 0;
}

fn clip(v: u16) u8 {
    return @truncate(@min(v, 255));
}

fn indexedColor(self: *const Term, i: u16) Color {
    const n: u8 = clip(i);
    if (n < 16) return self.scheme.palette[n];
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
