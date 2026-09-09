//! Minimal state modern terminal emulator designed to be fed preparsed runs
//! for optimal parsing speeds.

const std = @import("std");
const assert = std.debug.assert;
const Preparse = @import("preparse.zig");
const Runs = @import("runs.zig");
const Events = @import("events.zig");
const EastAsian = @import("type/east_asian.zig");
const Kitty = @import("kitty.zig");

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

pub const Screen = struct {
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

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) std.mem.Allocator.Error!Screen {
        return initScrollback(allocator, cols, rows, default_scrollback);
    }

    pub fn initScrollback(allocator: std.mem.Allocator, cols: u16, rows: u16, extra: u32) std.mem.Allocator.Error!Screen {
        return initWithScheme(allocator, cols, rows, extra, .{});
    }

    pub fn initWithScheme(allocator: std.mem.Allocator, cols: u16, rows: u16, extra: u32, scheme: Scheme) std.mem.Allocator.Error!Screen {
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

    pub fn deinit(self: *Screen) void {
        self.kitty.deinit();
        self.allocator.free(self.line_dirty);
        self.allocator.free(self.grids[1].starts);
        self.allocator.free(self.grids[1].cells);
        self.allocator.free(self.grids[0].starts);
        self.allocator.free(self.grids[0].cells);
        self.* = undefined;
    }

    pub fn resize(self: *Screen, cols: u16, rows: u16) std.mem.Allocator.Error!void {
        assert(cols > 0);
        assert(rows > 0);
        if (cols == self.cols and rows == self.rows) return;
        const extra = self.cap - self.rows;
        const next = try initWithScheme(self.allocator, cols, rows, extra, self.scheme);
        self.deinit();
        self.* = next;
    }

    pub fn clear(self: *Screen) void {
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

    pub fn cell(self: *const Screen, row: u16, col: u16) Cell {
        assert(row < self.rows);
        assert(col < self.cols);
        return self.viewSlice(row)[col];
    }

    pub fn rowCells(self: *const Screen, row: u16) []const Cell {
        return self.viewSlice(row);
    }

    /// Visual dump: every cell as UTF-8, NUL continuation as space, trailing
    /// spaces kept, rows joined by `\n` (no trailing newline after the last row).
    pub fn dumpAlloc(self: *const Screen, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
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
    pub fn dumpCellsAlloc(self: *const Screen, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
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

    fn cellIsBlank(self: *const Screen, c: Cell) bool {
        if (c.codepoint != ' ' and c.codepoint != 0) return false;
        if (c.fg.r != self.scheme.fg.r or c.fg.g != self.scheme.fg.g or c.fg.b != self.scheme.fg.b) return false;
        if (c.bg.r != self.scheme.bg.r or c.bg.g != self.scheme.bg.g or c.bg.b != self.scheme.bg.b) return false;
        const z: Attrs = .{};
        return std.meta.eql(c.attrs, z);
    }

    pub fn lineDirty(self: *const Screen, row: u16) bool {
        assert(row < self.rows);
        const i = row / 64;
        const b: u6 = @intCast(row % 64);
        return self.line_dirty[i] & (@as(u64, 1) << b) != 0;
    }

    pub fn clearDirty(self: *Screen) void {
        @memset(self.line_dirty, 0);
    }

    fn markDirty(self: *Screen, row: u16) void {
        assert(row < self.rows);
        const i = row / 64;
        const b: u6 = @intCast(row % 64);
        self.line_dirty[i] |= @as(u64, 1) << b;
    }

    fn markDirtyAll(self: *Screen) void {
        @memset(self.line_dirty, std.math.maxInt(u64));
    }

    pub fn cursor(self: *const Screen) Cursor {
        return self.gridConst().cursor;
    }

    pub fn cursorVisible(self: *const Screen) bool {
        return self.cursor_visible;
    }

    pub fn cursorStyle(self: *const Screen) CursorStyle {
        return self.cursor_style;
    }

    pub fn altScreen(self: *const Screen) bool {
        return self.which == 1;
    }

    pub fn inputMode(self: *const Screen) Events.InputMode {
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

    pub fn scrollOffset(self: *const Screen) u32 {
        return self.gridConst().scroll;
    }

    pub fn setScrollOffset(self: *Screen, v: u32) void {
        const g = self.grid();
        const n = @min(v, self.scrollMax());
        if (g.scroll == n) return;
        g.scroll = n;
        self.markDirtyAll();
    }

    pub fn scrollMax(self: *const Screen) u32 {
        return self.gridConst().used - self.rows;
    }

    pub fn scrollBy(self: *Screen, delta: i32) void {
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

    pub fn lineFeed(self: *Screen) void {
        self.grid().cursor.col = 0;
        self.index();
    }

    pub fn feed(self: *Screen, items: []const Runs.Run, src: []const u8) void {
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

    fn feedKitty(self: *Screen, bytes: []const u8) void {
        const cur = self.grid().cursor;
        const which = self.which;
        if (self.kitty.feed(bytes, .{ .row = cur.row, .col = cur.col }, self.cols, self.rows, which)) |next| {
            const g = self.grid();
            g.cursor.row = next.row;
            g.cursor.col = next.col;
        }
        self.markDirtyAll();
    }

    fn feedPlain(self: *Screen, bytes: []const u8) void {
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

    fn feedUtf8(self: *Screen, bytes: []const u8) void {
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

    fn put(self: *Screen, cp: u21) void {
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

    fn mapCp(self: *const Screen, cp: u21) u21 {
        if (cp < 0x20 or cp > 0x7e) return cp;
        const set = if (self.gl == 1) self.g1 else self.g0;
        if (set != .dec_special) return cp;
        return decSpecial(cp);
    }

    fn paintAttrs(self: *const Screen) Attrs {
        var a = self.gridConst().attrs;
        a.link = self.osc8;
        return a;
    }

    fn eraseCell(self: *const Screen) Cell {
        const g = self.gridConst();
        return .{ .fg = g.fg, .bg = g.bg };
    }

    fn feedOsc(self: *Screen, bytes: []const u8) void {
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

    fn feedC0(self: *Screen, bytes: []const u8) void {
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

    fn feedEsc(self: *Screen, bytes: []const u8) void {
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

    fn feedCsi(self: *Screen, bytes: []const u8) void {
        if (bytes.len < 3) return;
        const priv = privateByte(bytes);
        const inter = Preparse.csiIntermediate(bytes);
        var params: [32]u16 = @splat(0);
        const n = Preparse.csiParams(bytes, &params);
        const final = bytes[bytes.len - 1];
        if (priv == '?') {
            switch (final) {
                'h' => self.setPrivate(params[0..n], true),
                'l' => self.setPrivate(params[0..n], false),
                's' => self.savePrivate(params[0..n]),
                'r' => self.restorePrivate(params[0..n]),
                else => {},
            }
            return;
        }
        if (priv == '>' and final == 'm') {
            self.setModifyKeys(params[0..n]);
            return;
        }
        if (priv != 0) return;
        if (inter == '!' and final == 'p') {
            self.softReset();
            return;
        }
        if ((inter == ' ' or inter == 0) and final == 'q') {
            self.setCursorStyle(params[0]);
            return;
        }
        const p0 = params[0];
        const n1: u16 = if (p0 == 0) 1 else p0;
        switch (final) {
            'm' => self.sgr(params[0..n]),
            'H', 'f' => self.cup(n1, if (n > 1 and params[1] != 0) params[1] else 1),
            'J' => self.ed(p0),
            'K' => self.el(p0),
            'A' => self.cursorUp(n1),
            'B', 'e' => self.cursorDown(n1),
            'C', 'a' => {
                const g = self.grid();
                g.cursor.col = @min(g.cursor.col + n1, self.cols - 1);
            },
            'D' => self.grid().cursor.col -|= n1,
            'E' => {
                self.cursorDown(n1);
                self.grid().cursor.col = 0;
            },
            'F' => {
                self.cursorUp(n1);
                self.grid().cursor.col = 0;
            },
            'G', '`' => self.grid().cursor.col = @min(n1 -| 1, self.cols - 1),
            'd' => self.cup(n1, self.grid().cursor.col + 1),
            '@' => self.ich(n1),
            'P' => self.dch(n1),
            'X' => self.ech(n1),
            'L' => self.il(n1),
            'M' => self.dl(n1),
            'S' => self.regionScrollUp(n1),
            'T' => self.regionScrollDown(n1),
            'r' => self.decstbm(p0, if (n > 1) params[1] else 0),
            's' => self.saveCursor(),
            'u' => self.restoreCursor(),
            'h' => self.setMode(params[0..n], true),
            'l' => self.setMode(params[0..n], false),
            'b' => self.rep(n1),
            'I' => {
                var k: u16 = 0;
                while (k < n1) : (k += 1) {
                    const g = self.grid();
                    g.cursor.col += 8 - (g.cursor.col % 8);
                    if (g.cursor.col >= self.cols) g.cursor.col = self.cols - 1;
                }
            },
            'Z' => {
                var k: u16 = 0;
                while (k < n1) : (k += 1) {
                    const g = self.grid();
                    const col = g.cursor.col;
                    const prev = if (col == 0) 0 else col - 1;
                    g.cursor.col = prev - (prev % 8);
                }
            },
            else => {},
        }
    }

    fn setPrivate(self: *Screen, params: []const u16, enable: bool) void {
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

    fn setMode(self: *Screen, params: []const u16, enable: bool) void {
        for (params) |p| {
            switch (p) {
                4 => self.insert_mode = enable,
                else => {},
            }
        }
    }

    fn setModifyKeys(self: *Screen, params: []const u16) void {
        if (params.len == 0) {
            self.modify_other_keys = 0;
            return;
        }
        if (params[0] != 4) return;
        const pv: u16 = if (params.len > 1) params[1] else 0;
        self.modify_other_keys = @intCast(@min(pv, 2));
    }

    fn savePrivate(self: *Screen, params: []const u16) void {
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

    fn saveOnePrivate(self: *Screen, mode: u16) void {
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

    fn restorePrivate(self: *Screen, params: []const u16) void {
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

    fn setCursorStyle(self: *Screen, n: u16) void {
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

    fn softReset(self: *Screen) void {
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

    fn eraseScrollback(self: *Screen) void {
        const g = self.grid();
        if (g.used <= self.rows) return;
        g.head = (g.head + (g.used - self.rows)) % g.cap;
        g.used = self.rows;
        g.scroll = 0;
        self.markDirtyAll();
    }

    pub fn privateMode(self: *const Screen, n: u16) u16 {
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

    pub fn ansiMode(self: *const Screen, n: u16) u16 {
        return switch (n) {
            4 => if (self.insert_mode) 1 else 2,
            else => 0,
        };
    }

    fn sgrString(self: *const Screen, out: []u8) []const u8 {
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

    fn setAlt(self: *Screen, on: bool, save: bool, wipe: bool) void {
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

    fn saveCursor(self: *Screen) void {
        const g = self.grid();
        g.saved_cursor = g.cursor;
        g.saved_fg = g.fg;
        g.saved_bg = g.bg;
        g.saved_attrs = g.attrs;
    }

    fn restoreCursor(self: *Screen) void {
        const g = self.grid();
        g.cursor = g.saved_cursor;
        g.fg = g.saved_fg;
        g.bg = g.saved_bg;
        g.attrs = g.saved_attrs;
        if (g.cursor.row >= self.rows) g.cursor.row = self.rows - 1;
        if (g.cursor.col >= self.cols) g.cursor.col = self.cols - 1;
    }

    fn goHome(self: *Screen) void {
        const g = self.grid();
        g.cursor.col = 0;
        g.cursor.row = if (self.origin_mode) g.scroll_top else 0;
    }

    fn cup(self: *Screen, row1: u16, col1: u16) void {
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

    fn cursorUp(self: *Screen, n: u16) void {
        const g = self.grid();
        g.cursor.row -|= n;
        const floor: u16 = if (self.origin_mode) g.scroll_top else 0;
        if (g.cursor.row < floor) g.cursor.row = floor;
    }

    fn cursorDown(self: *Screen, n: u16) void {
        const g = self.grid();
        const limit: u16 = if (self.origin_mode) g.scroll_bottom else self.rows - 1;
        g.cursor.row = @min(g.cursor.row + n, limit);
    }

    fn decstbm(self: *Screen, top1: u16, bot1: u16) void {
        const top: u16 = if (top1 == 0) 1 else top1;
        const bot: u16 = if (bot1 == 0) self.rows else bot1;
        if (top > bot or bot > self.rows) return;
        const g = self.grid();
        g.scroll_top = top - 1;
        g.scroll_bottom = bot - 1;
        self.goHome();
    }

    fn index(self: *Screen) void {
        const g = self.grid();
        if (g.cursor.row == g.scroll_bottom) {
            self.regionScrollUp(1);
        } else if (g.cursor.row + 1 < self.rows) {
            g.cursor.row += 1;
        }
    }

    fn reverseIndex(self: *Screen) void {
        const g = self.grid();
        if (g.cursor.row == g.scroll_top) {
            self.regionScrollDown(1);
        } else if (g.cursor.row > 0) {
            g.cursor.row -= 1;
        }
    }

    fn ed(self: *Screen, mode: u16) void {
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

    fn el(self: *Screen, mode: u16) void {
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

    fn sgr(self: *Screen, params: []const u16) void {
        if (params.len == 0) {
            self.resetPen();
            return;
        }
        var i: usize = 0;
        while (i < params.len) {
            const p = params[i];
            i += 1;
            switch (p) {
                0 => self.resetPen(),
                1 => self.grid().attrs.bold = true,
                2 => self.grid().attrs.dim = true,
                3 => self.grid().attrs.italic = true,
                4 => self.grid().attrs.underline = true,
                5, 6 => self.grid().attrs.blink = true,
                7 => self.grid().attrs.inverse = true,
                8 => self.grid().attrs.hidden = true,
                9 => self.grid().attrs.strikethrough = true,
                21 => self.grid().attrs.underline = true,
                22 => {
                    self.grid().attrs.bold = false;
                    self.grid().attrs.dim = false;
                },
                23 => self.grid().attrs.italic = false,
                24 => self.grid().attrs.underline = false,
                25, 26 => self.grid().attrs.blink = false,
                27 => self.grid().attrs.inverse = false,
                28 => self.grid().attrs.hidden = false,
                29 => self.grid().attrs.strikethrough = false,
                30...37 => self.grid().fg = self.scheme.palette[p - 30],
                39 => self.grid().fg = self.scheme.fg,
                40...47 => self.grid().bg = self.scheme.palette[p - 40],
                49 => self.grid().bg = self.scheme.bg,
                38 => i += self.takeColor(params[i..], true),
                48 => i += self.takeColor(params[i..], false),
                90...97 => self.grid().fg = self.scheme.palette[p - 90 + 8],
                100...107 => self.grid().bg = self.scheme.palette[p - 100 + 8],
                else => {},
            }
        }
    }

    fn takeColor(self: *Screen, rest: []const u16, fg: bool) usize {
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

    fn setRgb(self: *Screen, r: u16, g: u16, b: u16, fg: bool) void {
        const c = Color{
            .r = clip(r),
            .g = clip(g),
            .b = clip(b),
        };
        if (fg) self.grid().fg = c else self.grid().bg = c;
    }

    fn ich(self: *Screen, n: u16) void {
        const line = self.rowSlice(self.grid().cursor.row);
        const col = @as(usize, self.grid().cursor.col);
        const count = @min(@as(usize, n), line.len - col);
        if (count == 0) return;
        std.mem.copyBackwards(Cell, line[col + count ..], line[col .. line.len - count]);
        @memset(line[col .. col + count], self.eraseCell());
    }

    fn dch(self: *Screen, n: u16) void {
        const line = self.rowSlice(self.grid().cursor.row);
        const col = @as(usize, self.grid().cursor.col);
        const count = @min(@as(usize, n), line.len - col);
        if (count == 0) return;
        std.mem.copyForwards(Cell, line[col .. line.len - count], line[col + count ..]);
        @memset(line[line.len - count ..], self.eraseCell());
    }

    fn ech(self: *Screen, n: u16) void {
        const line = self.rowSlice(self.grid().cursor.row);
        const col = @as(usize, self.grid().cursor.col);
        const count = @min(@as(usize, n), line.len - col);
        @memset(line[col .. col + count], self.eraseCell());
    }

    fn il(self: *Screen, n: u16) void {
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

    fn dl(self: *Screen, n: u16) void {
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

    fn rep(self: *Screen, n: u16) void {
        const cp = self.last_cp;
        var k: u16 = 0;
        while (k < n) : (k += 1) self.put(cp);
    }

    fn rowSlice(self: *Screen, row: u16) []Cell {
        return self.liveSlice(row);
    }

    fn liveSlice(self: *Screen, row: u16) []Cell {
        assert(row < self.rows);
        self.markDirty(row);
        const g = self.grid();
        const off = self.startAt(g, g.used - self.rows + row);
        return g.cells[off .. off + self.cols];
    }

    fn viewSlice(self: *const Screen, row: u16) []const Cell {
        assert(row < self.rows);
        const g = self.gridConst();
        const sc = @min(g.scroll, g.used - self.rows);
        const off = self.startAt(g, g.used - self.rows - sc + row);
        return g.cells[off .. off + self.cols];
    }

    fn startAt(_: *const Screen, g: *const Grid, logical: u32) u32 {
        assert(logical < g.used);
        return g.starts[(g.head + logical) % g.cap];
    }

    fn regionScrollUp(self: *Screen, n: u16) void {
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

    fn regionScrollDown(self: *Screen, n: u16) void {
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

    fn resetPen(self: *Screen) void {
        const g = self.grid();
        g.fg = self.scheme.fg;
        g.bg = self.scheme.bg;
        g.attrs = .{};
    }

    fn ringScrollUp(self: *Screen) void {
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

    fn scrollDown(self: *Screen) void {
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

    fn resetGrid(self: *Screen, i: u1) void {
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
        self.kitty.dropScreen(i);
        self.markDirtyAll();
    }

    fn grid(self: *Screen) *Grid {
        return &self.grids[self.which];
    }

    fn gridConst(self: *const Screen) *const Grid {
        return &self.grids[self.which];
    }
};

pub const Queries = struct {
    da: u8 = 0,
    da2: u8 = 0,
    da3: u8 = 0,
    dsr: u8 = 0,
    cpr: u8 = 0,
    cells: u8 = 0,
    px: u8 = 0,
    cell_px: u8 = 0,
    fg: u8 = 0,
    bg: u8 = 0,
    xtversion: u8 = 0,
    kitty_kb: u8 = 0,
    decrqss_m: u8 = 0,
    decrqss_bad: u8 = 0,
    tcap: [4][16]u8 = @splat(@splat(0)),
    tcap_len: [4]u8 = @splat(0),
    tcap_n: u8 = 0,
    sync_depth: u8 = 0,
    sync_flush: bool = false,
    decrqm: [8]u16 = @splat(0),
    decrqm_priv: [8]u8 = @splat(0),
    decrqm_n: u8 = 0,

    pub fn pending(self: Queries) bool {
        return self.da != 0 or self.da2 != 0 or self.da3 != 0 or self.dsr != 0 or self.cpr != 0 or
            self.cells != 0 or self.px != 0 or self.cell_px != 0 or self.fg != 0 or self.bg != 0 or
            self.xtversion != 0 or self.decrqm_n != 0 or self.kitty_kb != 0 or self.decrqss_m != 0 or
            self.decrqss_bad != 0 or self.tcap_n != 0;
    }

    pub fn add(self: *Queries, src: []const u8) void {
        if (std.mem.indexOfScalar(u8, src, 0x1b) == null) return;
        var i: usize = 0;
        while (i < src.len) {
            if (src[i] != 0x1b) {
                i = Preparse.skipAsciiPrintable(src, i);
                if (i < src.len and src[i] != 0x1b) i += 1;
                continue;
            }
            const seq = Preparse.parseSeq(src, i);
            if (!seq.complete) return;
            self.note(src[seq.start..seq.end], seq.class);
            i = seq.end;
        }
    }

    pub fn write(
        self: *Queries,
        screen: *const Screen,
        px_w: u32,
        px_h: u32,
        cell_w: u32,
        cell_h: u32,
        out: []u8,
    ) usize {
        var n: usize = 0;
        while (self.da > 0) : (self.da -= 1) {
            append(out, &n, "\x1b[?64;1;2;6;9;15;16;21;22c");
        }
        while (self.da2 > 0) : (self.da2 -= 1) {
            append(out, &n, "\x1b[>0;276;0c");
        }
        while (self.da3 > 0) : (self.da3 -= 1) {
            append(out, &n, "\x1bP!|00000000\x1b\\");
        }
        while (self.xtversion > 0) : (self.xtversion -= 1) {
            append(out, &n, "\x1bP>|ZT\x1b\\");
        }
        var qi: u8 = 0;
        while (qi < self.decrqm_n) : (qi += 1) {
            const mode = self.decrqm[qi];
            const priv = self.decrqm_priv[qi];
            const v: u16 = if (priv == '?') screen.privateMode(mode) else screen.ansiMode(mode);
            var tmp: [32]u8 = undefined;
            const s = if (priv == '?')
                std.fmt.bufPrint(&tmp, "\x1b[?{d};{d}$y", .{ mode, v }) catch continue
            else
                std.fmt.bufPrint(&tmp, "\x1b[{d};{d}$y", .{ mode, v }) catch continue;
            append(out, &n, s);
        }
        self.decrqm_n = 0;
        while (self.dsr > 0) : (self.dsr -= 1) {
            append(out, &n, "\x1b[0n");
        }
        while (self.cpr > 0) : (self.cpr -= 1) {
            const cur = screen.cursor();
            const row = cur.row + 1;
            const col = @min(cur.col, screen.cols -| 1) + 1;
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "\x1b[{d};{d}R", .{ row, col }) catch continue;
            append(out, &n, s);
        }
        while (self.cells > 0) : (self.cells -= 1) {
            var tmp: [40]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "\x1b[8;{d};{d}t", .{ screen.rows, screen.cols }) catch continue;
            append(out, &n, s);
        }
        while (self.px > 0) : (self.px -= 1) {
            var tmp: [40]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "\x1b[4;{d};{d}t", .{ px_h, px_w }) catch continue;
            append(out, &n, s);
        }
        while (self.cell_px > 0) : (self.cell_px -= 1) {
            var tmp: [40]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "\x1b[6;{d};{d}t", .{ cell_h, cell_w }) catch continue;
            append(out, &n, s);
        }
        while (self.fg > 0) : (self.fg -= 1) {
            appendOscRgb(out, &n, 10, screen.scheme.fg);
        }
        while (self.bg > 0) : (self.bg -= 1) {
            appendOscRgb(out, &n, 11, screen.scheme.bg);
        }
        while (self.kitty_kb > 0) : (self.kitty_kb -= 1) {
            append(out, &n, "\x1b[?0u");
        }
        while (self.decrqss_m > 0) : (self.decrqss_m -= 1) {
            var tmp: [80]u8 = undefined;
            const sgr = screen.sgrString(tmp[5..]);
            tmp[0] = 0x1b;
            tmp[1] = 'P';
            tmp[2] = '1';
            tmp[3] = '$';
            tmp[4] = 'r';
            const k: usize = 5 + sgr.len;
            if (k + 3 > tmp.len) continue;
            tmp[k] = 'm';
            tmp[k + 1] = 0x1b;
            tmp[k + 2] = '\\';
            append(out, &n, tmp[0 .. k + 3]);
        }
        while (self.decrqss_bad > 0) : (self.decrqss_bad -= 1) {
            append(out, &n, "\x1bP0$r\x1b\\");
        }
        var ti: u8 = 0;
        while (ti < self.tcap_n) : (ti += 1) {
            const name = self.tcap[ti][0..self.tcap_len[ti]];
            append(out, &n, "\x1bP0+r");
            append(out, &n, name);
            append(out, &n, "\x1b\\");
        }
        self.tcap_n = 0;
        return n;
    }

    fn note(self: *Queries, bytes: []const u8, class: Preparse.Class) void {
        switch (class) {
            .csi => {
                if (bytes.len < 3) return;
                const priv = privateByte(bytes);
                const final = bytes[bytes.len - 1];
                var params: [32]u16 = @splat(0);
                const pn = Preparse.csiParams(bytes, &params);
                if (priv == 0 and final == 'c') {
                    self.da +|= 1;
                } else if (priv == '>' and final == 'c') {
                    self.da2 +|= 1;
                } else if (priv == '=' and final == 'c') {
                    self.da3 +|= 1;
                } else if (priv == '>' and final == 'q') {
                    self.xtversion +|= 1;
                } else if (final == 'p' and Preparse.csiIntermediate(bytes) == '$') {
                    if (self.decrqm_n < self.decrqm.len) {
                        self.decrqm[self.decrqm_n] = params[0];
                        self.decrqm_priv[self.decrqm_n] = priv;
                        self.decrqm_n += 1;
                    }
                } else if (priv == 0 and final == 'n') {
                    if (params[0] == 6) self.cpr +|= 1 else self.dsr +|= 1;
                } else if (priv == '?' and final == 'n' and params[0] == 6) {
                    self.cpr +|= 1;
                } else if (priv == 0 and final == 't') {
                    switch (params[0]) {
                        14 => self.px +|= 1,
                        16 => self.cell_px +|= 1,
                        18 => self.cells +|= 1,
                        else => {},
                    }
                } else if (priv == '?' and final == 'u') {
                    self.kitty_kb +|= 1;
                } else if (priv == '?' and (final == 'h' or final == 'l')) {
                    self.noteSync(params[0..pn], final == 'h');
                }
            },
            .osc => {
                if (oscQuery(bytes)) |id| {
                    switch (id) {
                        10 => self.fg +|= 1,
                        11 => self.bg +|= 1,
                        else => {},
                    }
                }
            },
            .dcs => self.noteDcs(bytes),
            else => {},
        }
    }

    fn noteSync(self: *Queries, params: []const u16, enable: bool) void {
        for (params) |p| {
            if (p != 2026) continue;
            if (enable) {
                self.sync_depth +|= 1;
                self.sync_flush = false;
            } else if (self.sync_depth > 0) {
                self.sync_depth -= 1;
                if (self.sync_depth == 0) self.sync_flush = true;
            }
        }
    }

    fn noteDcs(self: *Queries, bytes: []const u8) void {
        const payload = dcsPayload(bytes);
        if (payload.len >= 2 and payload[0] == '$' and payload[1] == 'q') {
            const req = payload[2..];
            if (req.len != 0 and req[req.len - 1] == 'm' and (req.len == 1 or (req.len == 2 and req[0] == '0'))) {
                self.decrqss_m +|= 1;
            } else {
                self.decrqss_bad +|= 1;
            }
            return;
        }
        if (payload.len >= 2 and payload[0] == '+' and payload[1] == 'q') {
            var i: usize = 2;
            while (i < payload.len) {
                const start = i;
                while (i < payload.len and payload[i] != ';') i += 1;
                const name = payload[start..i];
                if (name.len != 0 and self.tcap_n < self.tcap.len) {
                    const n = @min(name.len, self.tcap[0].len);
                    @memcpy(self.tcap[self.tcap_n][0..n], name[0..n]);
                    self.tcap_len[self.tcap_n] = @intCast(n);
                    self.tcap_n += 1;
                }
                if (i < payload.len and payload[i] == ';') i += 1 else break;
            }
        }
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

fn indexedColor(self: *const Screen, i: u16) Color {
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

test "feed plain" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "Hi";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u21, 'H'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'i'), screen.cell(0, 1).codepoint);
    const dump = try screen.dumpAlloc(gpa);
    defer gpa.free(dump);
    try std.testing.expectEqualStrings("Hi      \n        ", dump);
}

test "el at wrap pending does not panic" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 4, 1);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "ABCD\x1b[1K";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u16, 4), screen.cursor().col);
    try std.testing.expectEqual(@as(u21, ' '), screen.cell(0, 0).codepoint);
}

test "sgr and cup" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[31mA\x1b[2;3H";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u8, 170), screen.cell(0, 0).fg.r);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor().row);
    try std.testing.expectEqual(@as(u16, 2), screen.cursor().col);
}

test "sgr 256 and truecolor" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[38;5;196mA\x1b[38:2::10:20:30mB";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u8, 255), screen.cell(0, 0).fg.r);
    try std.testing.expectEqual(@as(u8, 0), screen.cell(0, 0).fg.g);
    try std.testing.expectEqual(@as(u8, 10), screen.cell(0, 1).fg.r);
    try std.testing.expectEqual(@as(u8, 20), screen.cell(0, 1).fg.g);
    try std.testing.expectEqual(@as(u8, 30), screen.cell(0, 1).fg.b);
}

test "osc and str are not drawn" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 16, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "ab\x1b]0;title\x07cd\x1b^hid\x1b\\ef";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u21, 'a'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), screen.cell(0, 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), screen.cell(0, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), screen.cell(0, 3).codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), screen.cell(0, 4).codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), screen.cell(0, 5).codepoint);
}

test "csi insert delete" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "ABC\x1b[2D\x1b[@X";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u21, 'A'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.cell(0, 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cell(0, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), screen.cell(0, 3).codepoint);
}

test "scrollback ring" {
    const gpa = std.testing.allocator;
    var screen = try Screen.initScrollback(gpa, 4, 2, 4);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "a\nb\nc";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u21, 'b'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), screen.cell(1, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 1), screen.scrollMax());
    screen.scrollBy(1);
    try std.testing.expectEqual(@as(u21, 'a'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), screen.cell(1, 0).codepoint);
    screen.scrollBy(8);
    try std.testing.expectEqual(@as(u32, 1), screen.scrollOffset());
    screen.scrollBy(-8);
    try std.testing.expectEqual(@as(u32, 0), screen.scrollOffset());
    try std.testing.expectEqual(@as(u21, 'b'), screen.cell(0, 0).codepoint);
}

test "alt screen preserves primary" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "AB\x1b[?1049hXY\x1b[?1049l";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expect(!screen.altScreen());
    try std.testing.expectEqual(@as(u21, 'A'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cell(0, 1).codepoint);
}

test "alt screen is blank" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "AB\x1b[?1049h";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expect(screen.altScreen());
    try std.testing.expectEqual(@as(u21, ' '), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor().row);
    try std.testing.expectEqual(@as(u16, 0), screen.cursor().col);
}

test "scroll region lf" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 4, 4);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "AAAA\r\nBBBB\r\nCCCC\r\nDDDD\x1b[2;3r\x1b[3;1H\n";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u21, 'A'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), screen.cell(1, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.cell(2, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), screen.cell(3, 0).codepoint);
}

test "private sgr is ignored" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[>4;2mA";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expect(!screen.cell(0, 0).attrs.underline);
    try std.testing.expectEqual(@as(u21, 'A'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u8, 2), screen.inputMode().modify_other_keys);
}

test "save restore cursor" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 4);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[2;3H\x1b7\x1b[H\x1b8";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor().row);
    try std.testing.expectEqual(@as(u16, 2), screen.cursor().col);
}

test "insert mode" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "ABC\x1b[2D\x1b[4hX";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u21, 'A'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.cell(0, 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cell(0, 2).codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), screen.cell(0, 3).codepoint);
}

test "resize" {
    const gpa = std.testing.allocator;
    var screen = try Screen.initScrollback(gpa, 8, 2, 4);
    defer screen.deinit();
    try screen.resize(4, 6);
    try std.testing.expectEqual(@as(u16, 4), screen.cols);
    try std.testing.expectEqual(@as(u16, 6), screen.rows);
    try std.testing.expectEqual(@as(u32, 10), screen.cap);
    try std.testing.expectEqual(@as(u21, ' '), screen.cell(5, 3).codepoint);
    try screen.resize(4, 6);
    try std.testing.expectEqual(@as(u16, 6), screen.rows);
}

test "dec special graphics" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b(0qx\x1b(B";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u21, 0x2500), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 0x2502), screen.cell(0, 1).codepoint);
}

test "mouse and cursor key modes" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[?1h\x1b[?1000;1002;1006h\x1b[?2004h\x1b[?1004h";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    const mode = screen.inputMode();
    try std.testing.expect(mode.app_cursor);
    try std.testing.expectEqual(Events.MouseTracking.drag, mode.mouse);
    try std.testing.expect(mode.mouse_sgr);
    try std.testing.expect(mode.bracket_paste);
    try std.testing.expect(mode.focus_event);
}

test "device reports" {
    var q: Queries = .{};
    q.add("\x1b[c\x1b[6n\x1b[>c\x1b[18t");
    try std.testing.expect(q.pending());
    try std.testing.expectEqual(@as(u8, 1), q.da);
    try std.testing.expectEqual(@as(u8, 1), q.cpr);
    try std.testing.expectEqual(@as(u8, 1), q.da2);
    try std.testing.expectEqual(@as(u8, 1), q.cells);
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 80, 24);
    defer screen.deinit();
    var buf: [128]u8 = undefined;
    const n = q.write(&screen, 800, 384, 10, 16, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1b[?64;1;2;6;9;15;16;21;22c") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1b[1;1R") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1b[8;24;80t") != null);
    try std.testing.expect(!q.pending());
}

test "sgr dim hidden" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[2;8mA";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expect(screen.cell(0, 0).attrs.dim);
    try std.testing.expect(screen.cell(0, 0).attrs.hidden);
}

test "dirty lines on write and clear" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    try std.testing.expect(screen.lineDirty(0));
    screen.clearDirty();
    try std.testing.expect(!screen.lineDirty(0));
    try std.testing.expect(!screen.lineDirty(1));
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "A\nB\nC";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expect(screen.lineDirty(0));
    try std.testing.expect(screen.lineDirty(1));
    screen.clearDirty();
    try std.testing.expect(!screen.lineDirty(0));
    screen.scrollBy(1);
    try std.testing.expect(screen.lineDirty(0));
    try std.testing.expect(screen.lineDirty(1));
    screen.clearDirty();
    screen.clear();
    try std.testing.expect(screen.lineDirty(0));
}

test "decstr soft reset" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 4);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "ABC\x1b[2D\x1b[4h\x1b[2;3r\x1b[31m\x1b[!p\x1b[1;2HX";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u21, 'A'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), screen.cell(0, 1).codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), screen.cell(0, 2).codepoint);
    try std.testing.expectEqual(@as(u8, Color.default_fg.r), screen.cell(0, 1).fg.r);
    try std.testing.expect(!screen.insert_mode);
    try std.testing.expect(screen.auto_wrap);
    try std.testing.expect(!screen.origin_mode);
}

test "hpa hpr vpr" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 4);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[5`A\x1b[H\x1b[3aB\x1b[H\x1b[2eC";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u21, 'A'), screen.cell(0, 4).codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cell(0, 3).codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), screen.cell(2, 0).codepoint);
    try std.testing.expectEqual(@as(u16, 2), screen.cursor().row);
}

test "decscusr" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    try Runs.split(gpa, "\x1b[6 q", &runs);
    screen.feed(runs.items, "\x1b[6 q");
    try std.testing.expectEqual(CursorStyle.bar, screen.cursorStyle());
    runs.clearRetainingCapacity();
    try Runs.split(gpa, "\x1b[4q", &runs);
    screen.feed(runs.items, "\x1b[4q");
    try std.testing.expectEqual(CursorStyle.underline, screen.cursorStyle());
    try std.testing.expect(!screen.cursor_blink);
    runs.clearRetainingCapacity();
    try Runs.split(gpa, "\x1b[1 q", &runs);
    screen.feed(runs.items, "\x1b[1 q");
    try std.testing.expectEqual(CursorStyle.block, screen.cursorStyle());
    try std.testing.expect(screen.cursor_blink);
}

test "ed 3 clears scrollback" {
    const gpa = std.testing.allocator;
    var screen = try Screen.initScrollback(gpa, 4, 2, 4);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "a\nb\nc\nd";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expect(screen.scrollMax() > 0);
    try std.testing.expectEqual(@as(u21, 'c'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), screen.cell(1, 0).codepoint);
    runs.clearRetainingCapacity();
    try Runs.split(gpa, "\x1b[3J", &runs);
    screen.feed(runs.items, "\x1b[3J");
    try std.testing.expectEqual(@as(u32, 0), screen.scrollMax());
    try std.testing.expectEqual(@as(u21, 'c'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), screen.cell(1, 0).codepoint);
}

test "sgr blink and double underline" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[5;21mA\x1b[25;24mB";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expect(screen.cell(0, 0).attrs.blink);
    try std.testing.expect(screen.cell(0, 0).attrs.underline);
    try std.testing.expect(!screen.cell(0, 1).attrs.blink);
    try std.testing.expect(!screen.cell(0, 1).attrs.underline);
}

test "vt and ff are line feeds" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 4);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "A\x0bB\x0cC";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u21, 'A'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), screen.cell(1, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), screen.cell(2, 0).codepoint);
}

test "decrqm da3 xtversion" {
    var q: Queries = .{};
    q.add("\x1b[=c\x1b[>0q\x1b[?25$p\x1b[4$p");
    try std.testing.expect(q.pending());
    try std.testing.expectEqual(@as(u8, 1), q.da3);
    try std.testing.expectEqual(@as(u8, 1), q.xtversion);
    try std.testing.expectEqual(@as(u8, 2), q.decrqm_n);
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 80, 24);
    defer screen.deinit();
    var buf: [128]u8 = undefined;
    const n = q.write(&screen, 800, 384, 10, 16, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1bP!|00000000\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1bP>|ZT\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1b[?25;1$y") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1b[4;2$y") != null);
    try std.testing.expect(!q.pending());
}

test "bce el uses current background" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[41mAB\x1b[1D\x1b[K";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u21, 'A'), screen.cell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), screen.cell(0, 1).codepoint);
    try std.testing.expectEqual(@as(u8, 170), screen.cell(0, 1).bg.r);
    try std.testing.expectEqual(@as(u8, 0), screen.cell(0, 1).bg.g);
}

test "osc 8 sets link attr" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b]8;;http://x\x1b\\A\x1b]8;;\x1b\\B";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expect(screen.cell(0, 0).attrs.link);
    try std.testing.expect(!screen.cell(0, 1).attrs.link);
}

test "xtsave restore private mode" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[?25l\x1b[?25s\x1b[?25h\x1b[?25r";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expect(!screen.cursorVisible());
    try std.testing.expectEqual(@as(u16, 2), screen.privateMode(25));
}

test "modes 1015 1016 2026" {
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 8, 2);
    defer screen.deinit();
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[?1015;1016;2026h";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    const mode = screen.inputMode();
    try std.testing.expect(mode.mouse_urxvt);
    try std.testing.expect(mode.mouse_pixels);
    try std.testing.expectEqual(@as(u16, 1), screen.privateMode(2026));
}

test "kitty decrqss xtgettcap reports" {
    var q: Queries = .{};
    q.add("\x1b[?u\x1bP$qm\x1b\\\x1bP+q4D73\x1b\\");
    try std.testing.expect(q.pending());
    try std.testing.expectEqual(@as(u8, 1), q.kitty_kb);
    try std.testing.expectEqual(@as(u8, 1), q.decrqss_m);
    try std.testing.expectEqual(@as(u8, 1), q.tcap_n);
    const gpa = std.testing.allocator;
    var screen = try Screen.init(gpa, 80, 24);
    defer screen.deinit();
    var buf: [128]u8 = undefined;
    const n = q.write(&screen, 800, 384, 10, 16, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1b[?0u") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1bP1$r0m\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\x1bP0+r4D73\x1b\\") != null);
    try std.testing.expect(!q.pending());
}

test "sync depth from 2026" {
    var q: Queries = .{};
    q.add("\x1b[?2026hX\x1b[?2026l");
    try std.testing.expectEqual(@as(u8, 0), q.sync_depth);
    try std.testing.expect(q.sync_flush);
    q.add("\x1b[?2026h");
    try std.testing.expectEqual(@as(u8, 1), q.sync_depth);
    try std.testing.expect(!q.sync_flush);
}

test "scheme changes default and sgr colors" {
    const gpa = std.testing.allocator;
    const scheme = try @import("scheme.zig").parseScheme(
        \\
        \\foreground = "#fefefe"
        \\background = "#010203"
        \\[normal]
        \\red = "#ff0000"
        \\
    );
    var screen = try Screen.initWithScheme(gpa, 8, 2, default_scrollback, scheme);
    defer screen.deinit();
    try std.testing.expectEqual(@as(u8, 0x01), screen.cell(0, 0).bg.r);
    try std.testing.expectEqual(@as(u8, 0xfe), screen.cell(0, 0).fg.r);
    var runs: std.ArrayList(Runs.Run) = .empty;
    defer runs.deinit(gpa);
    const src = "\x1b[31mA";
    try Runs.split(gpa, src, &runs);
    screen.feed(runs.items, src);
    try std.testing.expectEqual(@as(u8, 0xff), screen.cell(0, 0).fg.r);
    try std.testing.expectEqual(@as(u8, 0x00), screen.cell(0, 0).fg.g);
    try std.testing.expectEqual(@as(u8, 0x01), screen.cell(0, 0).bg.r);
}
