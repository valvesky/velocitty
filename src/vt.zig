//! State machine, VT operations, sequence routing, and flags.

const std = @import("std");
const builtin = @import("builtin");
const GridMod = @import("grid.zig");
const Debug = @import("debug.zig");
const Kitty = @import("kitty.zig");
const CsiSeq = @import("csi.zig");
const Esc = @import("esc.zig");
const Osc = @import("osc.zig");
const Dcs = @import("dcs.zig");
const C0 = @import("c0.zig");
const EastAsian = @import("type/eastasian.zig");
const Ring = @import("circbuffer.zig");
const Run = Ring.Run;
const SIMD = @import("simd.zig");

pub const Color = GridMod.Color;
pub const Scheme = GridMod.Scheme;
pub const Attrs = GridMod.Attrs;
pub const Cell = GridMod.Cell;
pub const Style = GridMod.Style;
pub const StyleId = GridMod.StyleId;
pub const Styles = GridMod.Styles;
pub const Cursor = GridMod.Cursor;
pub const Grid = GridMod.Grid;
const Sixel = @import("sixel.zig");

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
    sixel_display: bool = false,
    sixel_private_palette: bool = true,
    sixel_cursor_right: bool = false,
    grapheme_shaping: bool = false,
    report_theme: bool = false,
    visibility_reports: bool = false,
    size_notifications: bool = false,
    ime: bool = false,
    _pad: u3 = 0,
};

pub const VtState = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    grids: [2]Grid,
    /// Interned cell styles of both grids (heap: the grids point at it).
    styles: *Styles,
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
    /// Feeding dead text (`Run.Flags.ghost`): the cursor moves, cells are
    /// not written. Wraps, insert mode and charsets still take the writing
    /// path; what they write is never seen.
    ghost: bool = false,
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
    win_px_w: u16 = 0,
    win_px_h: u16 = 0,
    dark_theme: bool = true,
    visible: bool = true,
    title_dirty: bool = false,
    notify_pending: bool = false,
    pointer_dirty: bool = false,
    app_id_dirty: bool = false,
    /// Debug-only visual overlay (OSC 556 / CSI ? 556). Always none in Release.
    debug_overlay: Debug.Overlay = .{},
    /// Last OSC numeric id (debug HUD). 0 if none since reset.
    debug_osc_id: u16 = 0,
    /// 0 none, 1 CLIPBOARD, 2 PRIMARY, 3 both.
    clip_kind: u8 = 0,
    pointer: u8 = 0,
    have_sel_fg: bool = false,
    have_sel_bg: bool = false,
    sel_fg: Color = Color.default_fg,
    sel_bg: Color = Color.default_bg,
    cwd: std.ArrayListUnmanaged(u8) = .empty,
    app_id: std.ArrayListUnmanaged(u8) = .empty,
    notify_title: std.ArrayListUnmanaged(u8) = .empty,
    notify_body: std.ArrayListUnmanaged(u8) = .empty,
    clip: std.ArrayListUnmanaged(u8) = .empty,
    sixel_reg: u16 = 256,
    sixel_geo_w: u16 = 0,
    sixel_geo_h: u16 = 0,
    sixel_palette: [256]Color = undefined,
    sixel_palette_ok: bool = false,
    /// Last OSC 133 mark ('A' prompt, 'B' prompt end, 'C' command, 'D' done).
    shell_mark: u8 = 0,
    kitty: Kitty.Store,
    storage: []u8,
    reply: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, scrollback: u32, storage: []u8) !VtState {
        const styles = try Styles.create(allocator);
        errdefer styles.destroy();
        var primary = try Grid.init(allocator, cols, rows, scrollback, styles, 0);
        errdefer primary.deinit(allocator);
        var alt = try Grid.init(allocator, cols, rows, rows, styles, 1);
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
            .styles = styles,
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
        self.cwd.deinit(self.allocator);
        self.app_id.deinit(self.allocator);
        self.notify_title.deinit(self.allocator);
        self.notify_body.deinit(self.allocator);
        self.clip.deinit(self.allocator);
        for (self.title_stack.items) |t| self.allocator.free(t);
        self.title_stack.deinit(self.allocator);
        self.grids[0].deinit(self.allocator);
        self.grids[1].deinit(self.allocator);
        self.styles.destroy();
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
        self.shell_mark = 0;
        self.saved_mode = @splat(0);
        self.saved_mode_val = @splat(0);
        self.ul_set = false;
        self.title_dirty = false;
        self.notify_pending = false;
        self.pointer_dirty = false;
        self.app_id_dirty = false;
        self.debug_overlay = .{};
        self.debug_osc_id = 0;
        self.clip_kind = 0;
        self.pointer = 0;
        self.have_sel_fg = false;
        self.have_sel_bg = false;
        self.sixel_reg = 256;
        self.sixel_geo_w = 0;
        self.sixel_geo_h = 0;
        self.sixel_palette_ok = false;
        self.cwd.clearRetainingCapacity();
        self.app_id.clearRetainingCapacity();
        self.notify_title.clearRetainingCapacity();
        self.notify_body.clearRetainingCapacity();
        self.clip.clearRetainingCapacity();
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
        const Remap = struct {
            prev: Scheme,
            next: Scheme,
            fn apply(ctx: *const @This(), st: *Style) void {
                st.fg = remapColor(st.fg, ctx.prev, ctx.next);
                st.bg = remapColor(st.bg, ctx.prev, ctx.next);
            }
        };
        const remap: Remap = .{ .prev = prev, .next = next };
        self.styles.recolor(&remap, Remap.apply);
        remapPen(&self.grids[0], prev, next);
        remapPen(&self.grids[1], prev, next);
        self.dark_theme = @as(u16, next.bg.r) + next.bg.g + next.bg.b < 384;
        if (self.flags.report_theme) {
            self.respond(if (self.dark_theme) "\x1b[?997;1n" else "\x1b[?997;2n");
        }
        self.markDirtyAll();
    }

    /// Update cells and pens that still refer to terminal defaults, preserving
    /// explicitly selected colors even when their RGB happens to match.
    pub fn setDefaultColor(self: *VtState, fg: bool, c: Color) void {
        if (fg) self.scheme.fg = c else self.scheme.bg = c;
        const Set = struct {
            fg: bool,
            c: Color,
            fn apply(ctx: @This(), st: *Style) void {
                if (ctx.fg) {
                    if (!st.attrs.fg_explicit) st.fg = ctx.c;
                } else {
                    if (!st.attrs.bg_explicit) st.bg = ctx.c;
                }
            }
        };
        self.styles.recolor(Set{ .fg = fg, .c = c }, Set.apply);
        for (&self.grids) |*g| {
            if (fg) {
                if (!g.attrs.fg_explicit) g.fg = c;
                if (!g.saved_attrs.fg_explicit) g.saved_fg = c;
            } else {
                if (!g.attrs.bg_explicit) g.bg = c;
                if (!g.saved_attrs.bg_explicit) g.saved_bg = c;
            }
        }
        self.markDirtyAll();
    }

    pub fn feedRuns(self: *VtState, runs: []const Run) void {
        self.feedFrom(runs, &.{});
    }

    /// Runs with `spill` set are backed by `spill` instead of the ring.
    pub fn feedFrom(self: *VtState, runs: []const Run, spill: []const u8) void {
        self.feedOwned(runs, spill, null);
    }

    /// `feedFrom` for a drain: `owner` is the ring whose spill buffer backs
    /// the runs, so a kitty image whose payload is the last string in it can
    /// keep the buffer instead of copying out of it.
    pub fn feedOwned(self: *VtState, runs: []const Run, spill: []const u8, owner: ?*Ring.CircBuffer) void {
        defer self.ghost = false;
        for (runs) |run| {
            const src = if (run.flags.spill) spill else self.storage;
            const slice = src[run.off .. run.off + run.len];
            self.ghost = run.flags.ghost;
            switch (run.kind) {
                .text => if (!run.flags.ghost or !self.skipDeadLine(slice)) self.feedText(slice),
                .c0 => {
                    if (slice.len > 0) C0.dispatch(self, slice[0]);
                },
                .esc => Esc.dispatch(self, slice),
                .csi => {
                    var params: [16]CsiSeq.Param = undefined;
                    CsiSeq.parse(slice, &params).apply(self);
                },
                .osc => Osc.dispatch(self, slice),
                .str => {
                    if (Kitty.isPrefix(slice)) {
                        const donor: ?Kitty.Donor = if (run.flags.spill and owner != null)
                            .{ .ctx = owner.?, .off = run.off, .len = run.len, .take = takeSpill }
                        else
                            null;
                        self.feedKitty(slice, true, donor);
                    } else Dcs.dispatch(self, slice);
                },
            }
        }
    }

    /// Dead text ending in CR whose wraps cannot move the cursor's row (it
    /// is on the bottom row of a full-screen region, where a dead LF does
    /// not scroll, or autowrap is off): its only effect is column 0 and the
    /// last character for REP. Returns false when it must be fed.
    fn skipDeadLine(self: *VtState, bytes: []const u8) bool {
        var end = bytes.len;
        while (end > 0 and bytes[end - 1] == '\r') end -= 1;
        if (end == bytes.len) return false;
        const body = bytes[0..end];
        // HT, BS and the other C0 controls take the full path (DEL is a
        // no-op, unless it is the last byte and REP's character is wanted).
        if (SIMD.skipToLowerThan(body, 0x20) != body.len) return false;
        const set = switch (self.gl) {
            0 => self.g0,
            1 => self.g1,
            2 => self.g2,
            3 => self.g3,
        };
        if (self.ss_active or set == .dec_special or self.flags.grapheme_shaping) return false;
        const g = self.grid();
        const bottom = g.scroll_top == 0 and g.scroll_bottom + 1 == self.rows and g.cursor.row + 1 == self.rows;
        // A wrap must scroll for real when placements have to move.
        if (self.flags.auto_wrap and (!bottom or self.kitty.placements.items.len != 0)) return false;
        // REP's character is the last one the line prints. Malformed UTF-8
        // can swallow the bytes after it, so non-ASCII lines are decoded
        // (as printing would) rather than read from the end.
        var last = self.last_cp;
        var buf: [256]u32 = undefined;
        var i: usize = 0;
        while (i < body.len) {
            if (body[i] < 0x80) {
                // Printable ASCII and DEL (a no-op).
                const n = SIMD.skipToGreaterThan(body[i..], 0x7F);
                var j = i + n;
                while (j > i and body[j - 1] == 0x7F) j -= 1;
                if (j > i) last = body[j - 1];
                i += n;
                continue;
            }
            // Decode up to the real end: a malformed sequence before the CR
            // can swallow it, and then the line does not end at column 0.
            const r = SIMD.decodeUtf8Run(.printable, bytes[i..], &buf);
            if (r.written != 0) last = @intCast(buf[r.written - 1]);
            i += @max(r.read, 1);
            if (i > end) return false;
        }
        g.cursor.col = 0;
        g.wrap_pending = false;
        self.last_cp = last;
        return true;
    }

    /// Decode one UTF-8 sequence whose length came from its lead byte.
    /// Rejects bad continuation bytes, overlongs, surrogates and > U+10FFFF.
    const decodeUtf8 = SIMD.decodeUtf8Seq;

    /// Printable ASCII and space (0x20..0x7E) in bulk; other C0 and DEL through C0;
    /// UTF-8 from its first non-ASCII byte through `printUtf8` (which also
    /// takes the printable ASCII mixed into it); stray 0x80..0xBF/0xF8.. are
    /// ignored (raw 8-bit C1 controls are not recognized in UTF-8 text).
    fn feedText(self: *VtState, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            const n = SIMD.skipOutRange(bytes[i..], 0x20, 0x7E);
            if (n != 0) self.printPlain(bytes[i..][0..n]);
            i += n;
            if (i >= bytes.len) break;
            const c = bytes[i];
            if (c < 0x80) {
                C0.dispatch(self, c);
                i += 1;
                continue;
            }
            i = self.printUtf8(bytes, i);
        }
    }

    /// Print the run of text at `bytes[start]` (a byte >= 0x80); returns
    /// where it ends. The run is decoded in chunks (`SIMD.decodeUtf8Run`),
    /// then each chunk is printed in a tight loop. With the ASCII charset
    /// the run takes printable ASCII too (as `printPlain` would print it)
    /// and ends at C0/DEL; otherwise it ends at any ASCII byte. Within the
    /// run the pen cannot change, so cells are written straight into the
    /// row with one template; wraps, wide characters at the margin, insert
    /// mode and single shifts take `printCodepoint`.
    // Not inlined into `feedOwned`: its own frame keeps more of the loop in registers.
    noinline fn printUtf8(self: *VtState, bytes: []const u8, start: usize) usize {
        var buf: [256]u32 = undefined;
        if (self.flags.insert_mode or self.ss_active) {
            var i = start;
            while (true) {
                const r = SIMD.decodeUtf8Run(.non_ascii, bytes[i..], &buf);
                i += r.read;
                for (buf[0..r.written]) |v| {
                    const cp: u21 = @intCast(v);
                    if (self.flags.grapheme_shaping and EastAsian.isCombining(cp)) continue;
                    self.printCodepoint(cp);
                }
                if (r.done) return i;
            }
        }
        const set = switch (self.gl) {
            0 => self.g0,
            1 => self.g1,
            2 => self.g2,
            3 => self.g3,
        };
        if (set == .dec_special) {
            return if (self.ghost) self.printUtf8Fast(.non_ascii, false, bytes, start, &buf) else self.printUtf8Fast(.non_ascii, true, bytes, start, &buf);
        }
        return if (self.ghost) self.printUtf8Fast(.printable, false, bytes, start, &buf) else self.printUtf8Fast(.printable, true, bytes, start, &buf);
    }

    /// `printUtf8` without insert mode or a single shift. `paint` false
    /// (ghost text) only moves the cursor. `.printable` needs the ASCII
    /// charset: printable ASCII is then width 1 and printed as itself.
    inline fn printUtf8Fast(self: *VtState, comptime mode: SIMD.Utf8Mode, comptime paint: bool, bytes: []const u8, start: usize, buf: *[256]u32) usize {
        var i = start;
        const cols = self.cols;
        const shaping = self.flags.grapheme_shaping;
        var g = self.grid();
        var row_cells: [*]u64 = @ptrCast(g.cellPtr(g.cursor.row, 0));
        // The template id is fetched again after `printCodepoint`, which
        // may intern a new (erase) style and so compact the table. Ghost
        // text writes no cells and interns nothing here.
        var bits: u64 = if (paint) @bitCast(Cell{ .codepoint = 0, .style = self.penId() }) else 0;
        // Cursor column and REP's character live in locals for the loop
        // (cell stores through `row_cells` could alias `self`) and are
        // written back before `printCodepoint` and on return. The fast
        // path never reaches the last column: a character that would
        // (or a pending wrap: `limit` 0) takes `printCodepoint`, so
        // `wrap_pending` stays false here and is never written.
        var col = g.cursor.col;
        var limit: u16 = if (g.wrap_pending) 0 else cols;
        var last = self.last_cp;
        // Column at the last flush: cells `[seg, col)` are new since then.
        var seg = col;
        while (true) {
            const r = SIMD.decodeUtf8Run(mode, bytes[i..], buf);
            i += r.read;
            for (buf[0..r.written]) |cp| {
                const v: u21 = @intCast(cp);
                if (shaping and EastAsian.isCombining(v)) continue;
                const w: u16 = @max(1, EastAsian.cellWidth(v));
                if (col + w >= limit) {
                    g.cursor.col = col;
                    self.last_cp = last;
                    if (paint and col > seg) self.flushRow(col);
                    self.printCodepoint(v);
                    g = self.grid();
                    row_cells = @ptrCast(g.cellPtr(g.cursor.row, 0));
                    if (paint) bits = @bitCast(Cell{ .codepoint = 0, .style = self.penId() });
                    col = g.cursor.col;
                    limit = if (g.wrap_pending) 0 else cols;
                    last = self.last_cp;
                    seg = col;
                    continue;
                }
                if (paint) {
                    row_cells[col] = bits | v;
                    if (w == 2) row_cells[col + 1] = bits;
                }
                col += w;
                last = v;
            }
            if (r.done) break;
        }
        g.cursor.col = col;
        self.last_cp = last;
        if (paint and col > seg) self.flushRow(col);
        return i;
    }

    /// Record cells `[0, end)` of the cursor row as written and dirty.
    inline fn flushRow(self: *VtState, end: u16) void {
        if (end == 0) return;
        const g = self.grid();
        g.noteWrite(g.cursor.row, end);
        self.markDirty(g.cursor.row);
    }

    /// The drain target for `CircBuffer.drain` / `readSource`.
    pub fn sink(self: *VtState) Ring.Sink {
        return .{ .ctx = self, .feed = sinkFeed, .view = sinkView };
    }

    fn sinkFeed(ctx: *anyopaque, runs: []const Run, spill: []const u8, owner: *Ring.CircBuffer) void {
        const self: *VtState = @ptrCast(@alignCast(ctx));
        self.feedOwned(runs, spill, owner);
    }

    fn takeSpill(ctx: *anyopaque, off: usize, len: usize, allocator: std.mem.Allocator) ?[]u8 {
        const cb: *Ring.CircBuffer = @ptrCast(@alignCast(ctx));
        return cb.takeSpill(allocator, off, len);
    }

    fn sinkView(ctx: *anyopaque) Ring.View {
        const self: *const VtState = @ptrCast(@alignCast(ctx));
        var full: [2]bool = undefined;
        for (&self.grids, 0..) |*g, i| full[i] = g.scroll_top == 0 and g.scroll_bottom + 1 == self.rows;
        return .{
            .rows = self.rows,
            .alt = self.which == 1,
            .full_region = full,
            .origin = self.flags.origin_mode,
            .reverse_wrap = self.flags.reverse_wrap,
        };
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

    /// Leave history view. Typing and paste use this so output is visible again.
    pub fn viewBottom(self: *VtState) void {
        if (self.which != 0) return;
        if (self.grid().scroll == 0) return;
        self.grid().scroll = 0;
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

    /// Decode the images about to be drawn; they stay encoded until then.
    pub fn prepareImages(self: *VtState) void {
        self.kitty.decodeVisible(self.which, self.imageBase(), self.rows, self.cell_px_h);
    }

    /// Absolute line shown on view row 0 (image placements use these lines).
    pub fn imageBase(self: *const VtState) i64 {
        const g = self.gridConst();
        return @as(i64, @intCast(g.base)) - g.scroll;
    }

    /// Oldest absolute line still held by the current grid.
    fn oldestLine(self: *const VtState) i64 {
        const g = self.gridConst();
        return @as(i64, @intCast(g.base)) - (g.used -| self.rows);
    }

    fn imageCursor(self: *VtState) Kitty.Cursor {
        const g = self.grid();
        return .{ .row = g.cursor.row, .col = g.cursor.col, .base = @intCast(g.base) };
    }

    pub fn resize(self: *VtState, cols: u16, rows: u16) !void {
        if (cols == 0 or rows == 0) return;
        if (cols == self.cols and rows == self.rows) return;
        const old_cols = self.cols;
        const old_rows = self.rows;
        try (&self.grids[0]).resize(self.allocator, old_cols, old_rows, cols, rows, self.grids[0].cap, true);
        // Reflow renumbers history lines; on-screen placements keep their rows.
        if (cols != old_cols) self.kitty.dropHistory(0, @intCast(self.grids[0].base));
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
        if (self.flags.grapheme_shaping and EastAsian.isCombining(mapped)) return;
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

        // After `ich`: an id fetched before it could be compacted away.
        const id = self.penId();
        const slot = &g.cellPtr(g.cursor.row, g.cursor.col)[0];
        g.noteWrite(g.cursor.row, @min(g.cursor.col + width, self.cols));
        slot.* = .{ .codepoint = mapped, .style = id };
        if (width == 2 and g.cursor.col + 1 < self.cols) {
            g.cellPtr(g.cursor.row, g.cursor.col + 1)[0] = .{ .codepoint = 0, .style = id };
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

    /// Bulk `printCodepoint` for printable ASCII and space (0x20..0x7E: width 1, never
    /// combining). Fills the rest of the row at once; wrap, insert mode and
    /// charset mapping take the per-codepoint path.
    pub fn printPlain(self: *VtState, bytes: []const u8) void {
        const set = switch (self.gl) {
            0 => self.g0,
            1 => self.g1,
            2 => self.g2,
            3 => self.g3,
        };
        if (self.flags.insert_mode or self.ss_active or set == .dec_special) {
            for (bytes) |b| self.printCodepoint(b);
            return;
        }
        var rest = bytes;
        while (rest.len != 0) {
            const g = self.grid();
            if (g.wrap_pending or g.cursor.col >= self.cols) {
                self.printCodepoint(rest[0]);
                rest = rest[1..];
                continue;
            }
            const n = @min(self.cols - g.cursor.col, rest.len);
            if (!self.ghost) {
                const id = self.penId();
                const cells = g.cellPtr(g.cursor.row, g.cursor.col)[0..n];
                g.noteWrite(g.cursor.row, g.cursor.col + @as(u16, @intCast(n)));
                for (cells, rest[0..n]) |*slot, b| slot.* = .{ .codepoint = b, .style = id };
                self.markDirty(g.cursor.row);
            }
            g.cursor.col += @intCast(n);
            if (g.cursor.col >= self.cols) {
                g.cursor.col = self.cols - 1;
                g.wrap_pending = self.flags.auto_wrap;
            } else {
                g.wrap_pending = false;
            }
            self.last_cp = rest[n - 1];
            rest = rest[n..];
        }
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
        a.ul_color = self.ul_set;
        return a;
    }

    fn penUl(self: *const VtState) GridMod.Rgb {
        if (!self.ul_set) return .{};
        return .{ .r = self.ul_color.r, .g = self.ul_color.g, .b = self.ul_color.b };
    }

    /// The style printed characters get: the pen with the hyperlink and
    /// underline-color state.
    pub fn penStyle(self: *const VtState) Style {
        const g = self.gridConst();
        return .{ .fg = g.fg, .bg = g.bg, .ul = self.penUl(), .attrs = self.paintAttrs() };
    }

    /// `penStyle`'s id: a lookup in the table's memo of recent interns unless
    /// the pen changed. May intern (see `Styles`).
    pub inline fn penId(self: *const VtState) StyleId {
        return self.styles.intern(self.penStyle());
    }

    /// A blank in the erase style (BCE). May intern (see `Styles`).
    pub fn eraseCell(self: *const VtState) Cell {
        return .{ .style = self.styles.intern(self.gridConst().blankStyle()) };
    }

    /// The style a cell refers to.
    pub inline fn styleOf(self: *const VtState, c: Cell) Style {
        return self.styles.of(c);
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
        var left = count;
        while (left > 0) : (left -= 1) {
            const g = self.grid();
            g.wrap_pending = false;
            const start = g.cursor.col;
            var dest = self.cols - 1;
            var c = start + 1;
            while (c < self.cols) : (c += 1) {
                if (tabIsSet(self.tabs, c)) {
                    dest = c;
                    break;
                }
            }
            if (start < dest) {
                const id = self.penId();
                const row = g.cellPtr(g.cursor.row, 0);
                g.noteWrite(g.cursor.row, dest);
                row[start] = .{ .codepoint = '\t', .style = id };
                var x = start + 1;
                while (x < dest) : (x += 1) row[x] = .{ .codepoint = ' ', .style = id };
                self.markDirty(g.cursor.row);
            }
            g.cursor.col = dest;
        }
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
        // A dead LF at the bottom of the screen: the drain guarantees that
        // live LFs scroll everything on screen away, so skip the scroll.
        // Placements are anchored to lines, so a scroll must still move them.
        if (self.ghost and g.cursor.row == g.scroll_bottom and g.scroll_top == 0 and g.scroll_bottom + 1 == self.rows and self.kitty.placements.items.len == 0) return;
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
                if (g.cursor.row == 0 and g.cursor.col == 0) self.dropScreenImages();
                GridMod.fillCells(g.rowSlice(g.cursor.row, self.cols)[g.cursor.col..], blank);
                // An erased line end does not continue on the next row.
                g.setRowWrap(g.cursor.row, false);
                self.markDirty(g.cursor.row);
                var r = g.cursor.row + 1;
                while (r < self.rows) : (r += 1) {
                    g.clearRange(r, 0, self.cols);
                    g.setRowWrap(r, false);
                    self.markDirty(r);
                }
            },
            1 => {
                var r: u16 = 0;
                while (r < g.cursor.row) : (r += 1) {
                    g.clearRange(r, 0, self.cols);
                    g.setRowWrap(r, false);
                    self.markDirty(r);
                }
                const end = @min(@as(usize, g.cursor.col) + 1, self.cols);
                GridMod.fillCells(g.rowSlice(g.cursor.row, self.cols)[0..end], blank);
                self.markDirty(g.cursor.row);
            },
            3 => {
                if (self.which == 0) {
                    g.used = self.rows;
                    g.scroll = 0;
                    self.kitty.dropHistory(0, @intCast(g.base));
                }
            },
            else => {
                self.dropScreenImages();
                var r: u16 = 0;
                while (r < self.rows) : (r += 1) {
                    g.clearRange(r, 0, self.cols);
                    g.setRowWrap(r, false);
                    self.markDirty(r);
                }
            },
        }
    }

    /// A full clear removes the images on screen with the text.
    fn dropScreenImages(self: *VtState) void {
        self.kitty.dropVisible(self.which, @intCast(self.grid().base), self.rows, self.cell_px_h);
    }

    pub fn el(self: *VtState, mode: u16) void {
        const g = self.grid();
        if (mode == 2) {
            g.clearRange(g.cursor.row, 0, self.cols);
            self.markDirty(g.cursor.row);
            return;
        }
        const line = g.rowSlice(g.cursor.row, self.cols);
        const blank = self.eraseCell();
        switch (mode) {
            0 => GridMod.fillCells(line[g.cursor.col..], blank),
            1 => GridMod.fillCells(line[0..@min(@as(usize, g.cursor.col) + 1, line.len)], blank),
            else => GridMod.fillCells(line, blank),
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
            GridMod.fillCells(g.rowSlice(g.cursor.row, self.cols)[g.cursor.col..end], self.eraseCell());
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
        const set = switch (self.gl) {
            0 => self.g0,
            1 => self.g1,
            2 => self.g2,
            3 => self.g3,
        };
        // Plain ASCII on the bulk path: fill cells a row at a time.
        if (cp >= 0x20 and cp <= 0x7E and !self.flags.insert_mode and !self.ss_active and set != .dec_special) {
            var buf: [256]u8 = undefined;
            @memset(&buf, @intCast(cp));
            var left: usize = n;
            while (left != 0) {
                const k = @min(left, buf.len);
                self.printPlain(buf[0..k]);
                left -= k;
            }
            return;
        }
        var k: u16 = 0;
        while (k < n) : (k += 1) self.printCodepoint(cp);
    }

    pub fn regionScrollUp(self: *VtState, n: u16) void {
        const g = self.grid();
        if (self.which == 0 and g.scroll_top == 0 and g.scroll_bottom + 1 == self.rows) {
            g.historyScrollUp(n, self.cols, self.rows);
            self.kitty.expire(0, self.oldestLine());
        } else {
            g.scrollUp(g.scroll_top, g.scroll_bottom, n, self.cols);
            self.kitty.scrollRegion(self.which, @intCast(g.base), g.scroll_top, g.scroll_bottom, n);
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
        self.ul_color = .{ .r = 0, .g = 0, .b = 0 };
    }

    pub fn takeColor(self: *VtState, rest: []const u16, fg: bool) usize {
        if (rest.len == 0) return 0;
        if (rest[0] == 5) {
            if (rest.len < 2) return rest.len;
            const c = indexedColor(self.scheme, rest[1]);
            if (fg) {
                self.grid().fg = c;
                self.grid().attrs.fg_explicit = true;
            } else {
                self.grid().bg = c;
                self.grid().attrs.bg_explicit = true;
            }
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
        if (fg) {
            self.grid().fg = c;
            self.grid().attrs.fg_explicit = true;
        } else {
            self.grid().bg = c;
            self.grid().attrs.bg_explicit = true;
        }
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
                1048 => if (enable) self.saveCursor() else self.restoreCursor(),
                1049 => self.setAlt(enable, true, true),
                1070 => self.flags.sixel_private_palette = enable,
                2004 => self.flags.bracket_paste = enable,
                2026 => self.flags.sync_output = enable,
                2027 => self.flags.grapheme_shaping = enable,
                2031 => {
                    self.flags.report_theme = enable;
                    if (enable) self.respond(if (self.dark_theme) "\x1b[?997;1n" else "\x1b[?997;2n");
                },
                2033 => {
                    self.flags.visibility_reports = enable;
                    if (enable) self.respond(if (self.visible) "\x1b[?999;1n" else "\x1b[?999;2n");
                },
                2048 => {
                    self.flags.size_notifications = enable;
                    if (enable) {
                        self.respondFmt("\x1b[48;{d};{d};{d};{d}t", .{
                            self.rows,
                            self.cols,
                            self.pixelHeight(true),
                            self.pixelWidth(true),
                        });
                    }
                },
                8452 => self.flags.sixel_cursor_right = enable,
                737769 => self.flags.ime = enable,
                556 => {
                    Debug.applyDec(&self.debug_overlay, enable);
                    self.markDirtyAll();
                },
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
            1070 => self.flags.sixel_private_palette,
            2004 => self.flags.bracket_paste,
            2026 => self.flags.sync_output,
            2027 => self.flags.grapheme_shaping,
            2031 => self.flags.report_theme,
            2033 => self.flags.visibility_reports,
            2048 => self.flags.size_notifications,
            8452 => self.flags.sixel_cursor_right,
            737769 => self.flags.ime,
            556 => if (comptime builtin.mode == .debug) self.debug_overlay.any() else return 0,
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
        if (window and self.win_px_w != 0) return self.win_px_w;
        return self.cols *| self.cell_px_w;
    }

    pub fn pixelHeight(self: *const VtState, window: bool) u16 {
        if (window and self.win_px_h != 0) return self.win_px_h;
        return self.rows *| self.cell_px_h;
    }

    pub fn setVisible(self: *VtState, on: bool) void {
        if (self.visible == on) return;
        self.visible = on;
        if (self.flags.visibility_reports) {
            self.respond(if (on) "\x1b[?999;1n" else "\x1b[?999;2n");
        }
    }

    pub fn xtsmgraphics(self: *VtState, pi: u32, pa: u32, pv: u32, pv2: u32) void {
        switch (pi) {
            1 => switch (pa) {
                1 => self.respondFmt("\x1b[?1;0;{d}S", .{self.sixel_reg}),
                2 => {
                    self.sixel_reg = 256;
                    self.respondFmt("\x1b[?1;0;256S", .{});
                },
                3 => {
                    self.sixel_reg = @intCast(std.math.clamp(pv, 2, 256));
                    self.respondFmt("\x1b[?1;0;{d}S", .{self.sixel_reg});
                },
                4 => self.respondFmt("\x1b[?1;0;256S", .{}),
                else => self.respondFmt("\x1b[?1;2;0S", .{}),
            },
            2 => {
                const max_w = self.pixelWidth(true);
                const max_h = self.pixelHeight(true);
                switch (pa) {
                    1 => {
                        const w = if (self.sixel_geo_w != 0) self.sixel_geo_w else max_w;
                        const h = if (self.sixel_geo_h != 0) self.sixel_geo_h else max_h;
                        self.respondFmt("\x1b[?2;0;{d};{d}S", .{ w, h });
                    },
                    2 => {
                        self.sixel_geo_w = 0;
                        self.sixel_geo_h = 0;
                        self.respondFmt("\x1b[?2;0;{d};{d}S", .{ max_w, max_h });
                    },
                    3 => {
                        self.sixel_geo_w = sat16vt(pv);
                        self.sixel_geo_h = sat16vt(pv2);
                        self.respondFmt("\x1b[?2;0;{d};{d}S", .{ self.sixel_geo_w, self.sixel_geo_h });
                    },
                    4 => self.respondFmt("\x1b[?2;0;{d};{d}S", .{ max_w, max_h }),
                    else => self.respondFmt("\x1b[?2;2;0S", .{}),
                }
            },
            else => self.respondFmt("\x1b[?{d};2;0S", .{pi}),
        }
    }

    pub fn feedSixel(self: *VtState, bytes: []const u8) void {
        var i: usize = 0;
        if (bytes.len >= 2 and bytes[0] == 0x1b and bytes[1] == 'P') i = 2;
        var p2: u32 = 0;
        var nparam: u8 = 0;
        var val: u32 = 0;
        var have = false;
        while (i < bytes.len) {
            const c = bytes[i];
            if (c >= '0' and c <= '9') {
                have = true;
                val = val *% 10 +% (c - '0');
                i += 1;
                continue;
            }
            if (c == ';' or c == 'q') {
                if (nparam == 1) p2 = if (have) val else 0;
                nparam += 1;
                val = 0;
                have = false;
                i += 1;
                if (c == 'q') break;
                continue;
            }
            if (c == 'q') {
                i += 1;
                break;
            }
            if (c < 0x20) {
                i += 1;
                continue;
            }
            break;
        }
        const body = payloadTrim(bytes[i..]);
        if (body.len == 0) return;
        if (!self.sixel_palette_ok or self.flags.sixel_private_palette) {
            self.sixel_palette = Sixel.defaultPalette();
            self.sixel_palette_ok = true;
        }
        const max_w = if (self.sixel_geo_w != 0) @as(u32, self.sixel_geo_w) else @as(u32, self.pixelWidth(false));
        const max_h = if (self.sixel_geo_h != 0) @as(u32, self.sixel_geo_h) else @as(u32, self.pixelHeight(false));
        const params: Sixel.Params = .{
            .transparent = p2 == 1,
            .max_w = @max(1, max_w),
            .max_h = @max(1, max_h),
            .palette = &self.sixel_palette,
            .registers = self.sixel_reg,
        };
        // A private palette starts from the default for every image, so the
        // pixels can wait until the image is drawn; only its size is needed
        // now. A shared palette is updated by decoding, in order.
        var img: Kitty.Image = undefined;
        if (self.flags.sixel_private_palette) {
            const size = Sixel.measure(body, params);
            const data = self.allocator.dupe(u8, body) catch return;
            img = .{ .id = 0, .width = size.width, .height = size.height, .rgba = &.{}, .pending = .{
                .data = data,
                .sixel = .{ .transparent = params.transparent, .max_w = params.max_w, .max_h = params.max_h, .registers = params.registers },
            } };
        } else {
            const b = Sixel.decode(self.allocator, body, params) catch return;
            img = .{ .id = 0, .width = b.width, .height = b.height, .rgba = b.rgba };
        }
        const bmp = img;
        const cell_w = @max(@as(u32, 1), self.cell_px_w);
        const cell_h = @max(@as(u32, 1), self.cell_px_h);
        const cols_used: u32 = (bmp.width + cell_w - 1) / cell_w;
        const rows_used: u32 = (bmp.height + cell_h - 1) / cell_h;
        const cur = self.grid().cursor;
        if (!self.flags.sixel_display) {
            const need: u16 = sat16vt(rows_used);
            const room = self.rows -| cur.row;
            if (need > room) self.regionScrollUp(need - room);
        }
        self.kitty.placeImage(img, self.imageCursor(), self.which, cols_used, rows_used);
        const g = self.grid();
        if (self.flags.sixel_cursor_right) {
            g.cursor.col = @min(self.cols - 1, cur.col +| sat16vt(cols_used));
        } else {
            g.wrap_pending = false;
            const down = sat16vt(rows_used);
            var r = cur.row;
            var k: u16 = 0;
            while (k < down) : (k += 1) {
                if (r == g.scroll_bottom) {
                    if (!self.flags.sixel_display) self.regionScrollUp(1);
                } else if (r + 1 < self.rows) {
                    r += 1;
                }
            }
            g.cursor.row = r;
            g.cursor.col = 0;
        }
        self.markDirtyAll();
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
        self.title_dirty = true;
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
        self.setDefaultColor(true, snap.fg);
        self.setDefaultColor(false, snap.bg);
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
        // The pen without its underline color (only the flag).
        const id = self.styles.intern(.{ .attrs = self.paintAttrs(), .fg = g.fg, .bg = g.bg });
        var r: u16 = 0;
        while (r < self.rows) : (r += 1) {
            GridMod.fillCells(g.rowSlice(r, self.cols), .{ .codepoint = 'E', .style = id });
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
                var st = self.styles.of(slot.*);
                var a = st.attrs;
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
                st.attrs = a;
                // Interning may compact, which rewrites `slot` in place first.
                const id = self.styles.intern(st);
                slot.style = id;
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
                var st = self.styles.of(slot.*);
                var a = st.attrs;
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
                st.attrs = a;
                // Interning may compact, which rewrites `slot` in place first.
                const id = self.styles.intern(st);
                slot.style = id;
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
        const g = self.grid();
        const id = self.styles.intern(.{ .attrs = self.paintAttrs(), .fg = g.fg, .bg = g.bg });
        var r = area.top;
        while (r <= area.bottom) : (r += 1) {
            var c = area.left;
            while (c <= area.right) : (c += 1) {
                g.getCell(r, c).* = .{ .codepoint = ch, .style = id };
            }
            self.markDirty(r);
        }
    }

    pub fn decera(self: *VtState, params: []const CsiSeq.Param) void {
        const area = self.rectArea(params, 0) orelse return;
        const blank = self.eraseCell();
        var r = area.top;
        while (r <= area.bottom) : (r += 1) {
            GridMod.fillCells(self.grid().rowSlice(r, self.cols)[area.left .. area.right + 1], blank);
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

    fn feedKitty(self: *VtState, bytes: []const u8, place: bool, donor: ?Kitty.Donor) void {
        const next = self.kitty.feedDonor(bytes, self.imageCursor(), self.cols, self.rows, self.which, place, donor);
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
                const st = self.styleOf(c);
                if (cellIsBlank(self.scheme, c, st)) continue;
                var attr_buf: [9]u8 = undefined;
                const attrs = attrLetters(st.attrs, &attr_buf);
                var buf: [96]u8 = undefined;
                const n = std.fmt.bufPrint(&buf, "{d} {d} U+{X:0>4} #{x:0>2}{x:0>2}{x:0>2} #{x:0>2}{x:0>2}{x:0>2} {s}\n", .{
                    y,
                    x,
                    c.codepoint,
                    st.fg.r,
                    st.fg.g,
                    st.fg.b,
                    st.bg.r,
                    st.bg.g,
                    st.bg.b,
                    attrs,
                }) catch unreachable;
                try out.appendSlice(allocator, n);
            }
        }
        return out.toOwnedSlice(allocator);
    }
};

fn sat16vt(v: u32) u16 {
    return @intCast(@min(v, 65535));
}

fn payloadTrim(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == 0x07) return s[0 .. s.len - 1];
    if (s.len >= 2 and s[s.len - 2] == 0x1b and s[s.len - 1] == '\\') return s[0 .. s.len - 2];
    return s;
}

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

fn remapPen(g: *Grid, prev: Scheme, next: Scheme) void {
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

fn cellIsBlank(scheme: Scheme, c: Cell, st: Style) bool {
    if (c.codepoint != ' ' and c.codepoint != 0) return false;
    if (st.fg.r != scheme.fg.r or st.fg.g != scheme.fg.g or st.fg.b != scheme.fg.b) return false;
    if (st.bg.r != scheme.bg.r or st.bg.g != scheme.bg.g or st.bg.b != scheme.bg.b) return false;
    const z: Attrs = .{};
    return std.meta.eql(st.attrs, z);
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
    try std.testing.expectEqual(@as(u8, 0x1e), vt.styleOf(c).bg.r);
    try std.testing.expectEqual(@as(u8, 0x3c), vt.styleOf(c).bg.g);
    try std.testing.expectEqual(@as(u8, 0x5a), vt.styleOf(c).bg.b);
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
    try std.testing.expect(vt.styleOf(vt.grid().cellAt(0, 0)).attrs.bold);
    try std.testing.expectEqual(vt.scheme.palette[1], vt.styleOf(vt.grid().cellAt(0, 0)).fg);
    try std.testing.expect(vt.styleOf(vt.grid().cellAt(0, 1)).attrs.italic);
    try std.testing.expect(vt.styleOf(vt.grid().cellAt(0, 2)).attrs.underline);
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
    try std.testing.expectEqual(vt.scheme.palette[1], vt.styleOf(vt.grid().cellAt(0, 2)).bg);
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
    try std.testing.expectEqual(@as(u8, 30), vt.styleOf(c).fg.r);
    try std.testing.expectEqual(@as(u8, 60), vt.styleOf(c).fg.g);
    try std.testing.expectEqual(@as(u8, 90), vt.styleOf(c).fg.b);
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

test "lf indexes without carriage return" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 3, 8, &dummy);
    defer vt.deinit();
    vt.printCodepoint('A');
    vt.printCodepoint('B');
    C0.dispatch(&vt, 0x0A);
    try std.testing.expectEqual(@as(u16, 1), vt.grid().cursor.row);
    try std.testing.expectEqual(@as(u16, 2), vt.grid().cursor.col);
    vt.printCodepoint('C');
    try std.testing.expectEqual(@as(u21, 'C'), vt.grid().cellAt(1, 2).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), vt.grid().cellAt(1, 0).codepoint);
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

test "key returns scrollback to the bottom" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 2, 8, &dummy);
    defer vt.deinit();
    for ("AABBCCDDEEFF") |b| vt.printCodepoint(b);
    vt.viewScroll(4);
    try std.testing.expect(vt.scrollOffset() > 0);
    vt.viewBottom();
    try std.testing.expectEqual(@as(u32, 0), vt.scrollOffset());
}

test "ed 3 drops scrollback" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 2, 8, &dummy);
    defer vt.deinit();
    for ("AABBCCDDEEFF") |b| vt.printCodepoint(b);
    try std.testing.expect(vt.grid().used > 2);
    applyCsi(&vt, "\x1b[3J");
    try std.testing.expectEqual(@as(u32, 2), vt.grid().used);
    try std.testing.expectEqual(@as(u32, 0), vt.grid().scroll);
}

test "tab writes tab and spaces" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 16, 1, 2, &dummy);
    defer vt.deinit();
    vt.printCodepoint('A');
    C0.dispatch(&vt, 0x09);
    try std.testing.expectEqual(@as(u21, '\t'), vt.grid().cellAt(0, 1).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), vt.grid().cellAt(0, 2).codepoint);
    try std.testing.expectEqual(@as(u16, 8), vt.grid().cursor.col);
}

test "sgr underline color on cell" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 1, 2, &dummy);
    defer vt.deinit();
    applyCsi(&vt, "\x1b[4;58:2:1:2:3m");
    vt.printCodepoint('X');
    const c = vt.grid().cellAt(0, 0);
    try std.testing.expect(vt.styleOf(c).attrs.underline);
    try std.testing.expect(vt.styleOf(c).attrs.ul_color);
    try std.testing.expectEqual(@as(u8, 1), vt.styleOf(c).ul.r);
    try std.testing.expectEqual(@as(u8, 2), vt.styleOf(c).ul.g);
    try std.testing.expectEqual(@as(u8, 3), vt.styleOf(c).ul.b);
}

test "grapheme clustering skips combining" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 1, 2, &dummy);
    defer vt.deinit();
    applyCsi(&vt, "\x1b[?2027h");
    vt.printCodepoint('e');
    vt.printCodepoint(0x0301);
    try std.testing.expectEqual(@as(u16, 1), vt.grid().cursor.col);
    try std.testing.expectEqual(@as(u21, 'e'), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), vt.grid().cellAt(0, 1).codepoint);
}

test "xtsmgraphics color registers" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    applyCsi(&vt, "\x1b[?1;1;0S");
    try std.testing.expectEqualStrings("\x1b[?1;0;256S", vt.reply.items);
}

test "osc 7 cwd" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    Osc.dispatch(&vt, "\x1b]7;file://host/tmp/work\x07");
    try std.testing.expectEqualStrings("/tmp/work", vt.cwd.items);
}

test "osc 9 conemu progress is not a notification" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    Osc.dispatch(&vt, "\x1b]9;4;1;0\x1b\\");
    try std.testing.expect(!vt.notify_pending);
    Osc.dispatch(&vt, "\x1b]9;4;0;0\x1b\\");
    try std.testing.expect(!vt.notify_pending);
    Osc.dispatch(&vt, "\x1b]9;hello\x07");
    try std.testing.expect(vt.notify_pending);
    try std.testing.expectEqualStrings("hello", vt.notify_body.items);
}

test "osc 9;9 sets cwd" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    Osc.dispatch(&vt, "\x1b]9;9;/tmp/work\x07");
    try std.testing.expect(!vt.notify_pending);
    try std.testing.expectEqualStrings("/tmp/work", vt.cwd.items);
}

test "osc 777 notify prefix only" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    Osc.dispatch(&vt, "\x1b]777;preedit;foo\x07");
    try std.testing.expect(!vt.notify_pending);
    Osc.dispatch(&vt, "\x1b]777;notify;Title;Body\x07");
    try std.testing.expect(vt.notify_pending);
    try std.testing.expectEqualStrings("Title", vt.notify_title.items);
    try std.testing.expectEqualStrings("Body", vt.notify_body.items);
}

test "osc 99 kitty close is not a notification" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    Osc.dispatch(&vt, "\x1b]99;i=id:d=2;\x07");
    try std.testing.expect(!vt.notify_pending);
    Osc.dispatch(&vt, "\x1b]99;i=id:d=0:p=body;saved\x07");
    try std.testing.expect(vt.notify_pending);
    try std.testing.expectEqualStrings("saved", vt.notify_body.items);
}

test "xtgettcap name" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    Dcs.dispatch(&vt, "\x1bP+q544e\x1b\\");
    try std.testing.expect(std.mem.indexOf(u8, vt.reply.items, "544e=") != null);
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

test "osc 556 debug overlay" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    Osc.dispatch(&vt, "\x1b]556;wrap,lcf\x07");
    if (comptime builtin.mode == .debug) {
        try std.testing.expect(vt.debug_overlay.wrap);
        try std.testing.expect(vt.debug_overlay.lcf);
        try std.testing.expect(!vt.debug_overlay.grid);
    } else {
        try std.testing.expect(!vt.debug_overlay.any());
    }
    applyCsi(&vt, "\x1b[?556h");
    if (comptime builtin.mode == .debug) {
        try std.testing.expect(vt.debug_overlay.any());
        try std.testing.expectEqual(@as(u16, 1), vt.privateMode(556));
    }
    applyCsi(&vt, "\x1b[?556l");
    try std.testing.expect(!vt.debug_overlay.any());
    Osc.dispatch(&vt, "\x1b]556;off\x07");
    try std.testing.expect(!vt.debug_overlay.any());
}

test "full region delete lines clears without underflow" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 2, 2, &dummy);
    defer vt.deinit();
    vt.printCodepoint('A');
    applyCsi(&vt, "\x1b[H");
    applyCsi(&vt, "\x1b[2M");
    try std.testing.expectEqual(@as(u21, ' '), vt.grid().cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, ' '), vt.grid().cellAt(1, 0).codepoint);
}

test "reflow retains trailing wide continuation" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 2, 2, &dummy);
    defer vt.deinit();
    vt.printCodepoint('a');
    vt.printCodepoint('b');
    vt.printCodepoint('界');
    try vt.resize(5, 2);
    vt.printCodepoint('X');
    try std.testing.expectEqual(@as(u21, 0), vt.grid().cellAt(0, 3).codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), vt.grid().cellAt(0, 4).codepoint);
}

test "osc default and palette resets preserve explicit colors" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 2, 2, &dummy);
    defer vt.deinit();
    const original = vt.orig;
    @import("osc.zig").dispatch(&vt, "\x1b]4;1;#123456\x07");
    @import("osc.zig").dispatch(&vt, "\x1b]104\x07");
    try std.testing.expectEqual(original.palette[1], vt.table[1]);
    try std.testing.expectEqual(original.palette[1], vt.scheme.palette[1]);
    vt.printCodepoint('a');
    applyCsi(&vt, "\x1b[38;2;170;170;170;48;2;0;0;0m");
    vt.printCodepoint('b');
    @import("osc.zig").dispatch(&vt, "\x1b]10;#112233\x07");
    @import("osc.zig").dispatch(&vt, "\x1b]11;#123456\x07");
    const fg = Color{ .r = 0x11, .g = 0x22, .b = 0x33 };
    const bg = Color{ .r = 0x12, .g = 0x34, .b = 0x56 };
    try std.testing.expectEqual(fg, vt.styleOf(vt.grid().cellAt(0, 0)).fg);
    try std.testing.expectEqual(bg, vt.styleOf(vt.grid().cellAt(0, 0)).bg);
    try std.testing.expectEqual(original.fg, vt.styleOf(vt.grid().cellAt(0, 1)).fg);
    try std.testing.expectEqual(original.bg, vt.styleOf(vt.grid().cellAt(0, 1)).bg);
    applyCsi(&vt, "\x1b[39;49m");
    vt.printCodepoint('c');
    try std.testing.expectEqual(fg, vt.styleOf(vt.grid().cellAt(0, 2)).fg);
    try std.testing.expectEqual(bg, vt.styleOf(vt.grid().cellAt(0, 2)).bg);
    @import("osc.zig").dispatch(&vt, "\x1b]110\x07");
    @import("osc.zig").dispatch(&vt, "\x1b]111\x07");
    try std.testing.expectEqual(original.fg, vt.styleOf(vt.grid().cellAt(0, 2)).fg);
    try std.testing.expectEqual(original.bg, vt.styleOf(vt.grid().cellAt(0, 2)).bg);
}


test "color stack restores default cells and pens" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 4, 2, 2, &dummy);
    defer vt.deinit();
    const original = vt.scheme.bg;
    vt.printCodepoint('a');
    vt.xtPushColors(0);
    @import("osc.zig").dispatch(&vt, "\x1b]11;#123456\x07");
    vt.printCodepoint('b');
    applyCsi(&vt, "\x1b[48;2;18;52;86m");
    vt.printCodepoint('c');
    vt.xtPopColors(0);
    try std.testing.expectEqual(original, vt.scheme.bg);
    try std.testing.expectEqual(original, vt.styleOf(vt.grid().cellAt(0, 0)).bg);
    try std.testing.expectEqual(original, vt.styleOf(vt.grid().cellAt(0, 1)).bg);
    try std.testing.expectEqual(Color{ .r = 18, .g = 52, .b = 86 }, vt.styleOf(vt.grid().cellAt(0, 2)).bg);
    applyCsi(&vt, "\x1b[49m");
    vt.printCodepoint('d');
    try std.testing.expectEqual(original, vt.styleOf(vt.grid().cellAt(0, 3)).bg);
}

test "printPlain matches per-codepoint printing" {
    const gpa = std.testing.allocator;
    var dummy: [1]u8 = .{0};
    const text = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ!#$%";
    // Start column, DECAWM, insert mode, DEC special graphics.
    const cases = [_]struct { col: u16, wrap: bool, insert: bool, dec: bool, pending: bool }{
        .{ .col = 0, .wrap = true, .insert = false, .dec = false, .pending = false },
        .{ .col = 5, .wrap = true, .insert = false, .dec = false, .pending = false },
        .{ .col = 9, .wrap = true, .insert = false, .dec = false, .pending = true },
        .{ .col = 3, .wrap = false, .insert = false, .dec = false, .pending = false },
        .{ .col = 2, .wrap = true, .insert = true, .dec = false, .pending = false },
        .{ .col = 1, .wrap = true, .insert = false, .dec = true, .pending = false },
    };
    for (cases) |case| {
        for ([_]usize{ 1, 7, 10, 23, text.len }) |len| {
            var a = try VtState.init(gpa, 10, 4, 4, &dummy);
            defer a.deinit();
            var b = try VtState.init(gpa, 10, 4, 4, &dummy);
            defer b.deinit();
            for ([_]*VtState{ &a, &b }) |vt| {
                applyCsi(vt, "\x1b[1;31m");
                vt.flags.auto_wrap = case.wrap;
                vt.flags.insert_mode = case.insert;
                if (case.dec) vt.g0 = .dec_special;
                vt.grid().cursor = .{ .row = 1, .col = case.col };
                vt.grid().wrap_pending = case.pending;
                vt.clearDirty();
            }
            a.printPlain(text[0..len]);
            for (text[0..len]) |ch| b.printCodepoint(ch);
            var r: u16 = 0;
            while (r < 4) : (r += 1) {
                try expectSameCells(&b, b.rowCells(r), &a, a.rowCells(r));
                try std.testing.expectEqual(b.lineDirty(r), a.lineDirty(r));
            }
            try std.testing.expectEqual(b.cursor(), a.cursor());
            try std.testing.expectEqual(b.grid().wrap_pending, a.grid().wrap_pending);
            try std.testing.expectEqual(b.last_cp, a.last_cp);
        }
    }
}

test "sixel follows its scrollback line until history drops it" {
    var dummy: [1]u8 = .{0};
    var vt = try VtState.init(std.testing.allocator, 8, 4, 8, &dummy);
    defer vt.deinit();
    vt.cell_px_w = 1;
    vt.cell_px_h = 6;
    vt.index();
    vt.feedSixel("\x1bPq#0;2;100;0;0#0~~\x1b\\");
    try std.testing.expectEqual(@as(usize, 1), vt.kitty.placements.items.len);
    try std.testing.expectEqual(@as(i64, 1), vt.kitty.placements.items[0].row);
    try std.testing.expectEqual(@as(i64, 1), vt.kitty.placements.items[0].row - vt.imageBase());
    var k: u16 = 0;
    while (k < 3) : (k += 1) vt.regionScrollUp(1);
    // Scrolled off screen but still in history; visible when scrolled back.
    try std.testing.expectEqual(@as(i64, -2), vt.kitty.placements.items[0].row - vt.imageBase());
    vt.grid().scroll = 3;
    try std.testing.expectEqual(@as(i64, 1), vt.kitty.placements.items[0].row - vt.imageBase());
    vt.grid().scroll = 0;
    while (vt.oldestLine() <= 1) vt.regionScrollUp(1);
    try std.testing.expectEqual(@as(usize, 0), vt.kitty.placements.items.len);
    try std.testing.expectEqual(@as(usize, 0), vt.kitty.images.items.len);
}

test "large kitty images arrive through the ring, chunked or as one string" {
    const gpa = std.testing.allocator;
    const w = 3840;
    const h = 2160;
    const rgba = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(rgba);
    for (rgba, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
    const b64 = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(rgba.len));
    defer gpa.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, rgba);

    for ([_]bool{ true, false }) |chunked| {
        var stream: std.ArrayListUnmanaged(u8) = .empty;
        defer stream.deinit(gpa);
        if (chunked) {
            var off: usize = 0;
            while (off < b64.len) {
                const end = @min(off + 4096, b64.len);
                const more: u8 = @intFromBool(end < b64.len);
                if (off == 0) {
                    try stream.print(gpa, "\x1b_Ga=T,f=32,s={d},v={d},i=7,q=2,c=20,r=10,m={d};", .{ w, h, more });
                } else try stream.print(gpa, "\x1b_Gm={d};", .{more});
                try stream.appendSlice(gpa, b64[off..end]);
                try stream.appendSlice(gpa, "\x1b\\");
                off = end;
            }
        } else {
            try stream.print(gpa, "\x1b_Ga=T,f=32,s={d},v={d},i=7,q=2,c=20,r=10;", .{ w, h });
            try stream.appendSlice(gpa, b64);
            try stream.appendSlice(gpa, "\x1b\\");
        }
        var ring = try Ring.CircBuffer.create(gpa, 64 * 1024);
        defer ring.destroy();
        var vt = try VtState.init(gpa, 80, 24, 100, ring.storage);
        defer vt.deinit();
        var off: usize = 0;
        while (off < stream.items.len) {
            const free: usize = @intCast(ring.capacity - (ring.head - ring.tail));
            const n = @min(free, stream.items.len - off);
            const at: usize = @intCast(ring.head & (ring.capacity - 1));
            @memcpy(ring.storage[at..][0..n], stream.items[off..][0..n]);
            if (!ring.mapped) @memcpy(ring.storage[at + ring.capacity ..][0..n], ring.storage[at..][0..n]);
            ring.head += n;
            off += n;
            if (ring.capacity - (ring.head - ring.tail) < ring.capacity / 4) ring.drain(vt.sink());
        }
        ring.drain(vt.sink());
        const img = vt.kitty.find(7) orelse return error.ImageDropped;
        try std.testing.expectEqual(@as(u32, w), img.width);
        try std.testing.expectEqual(@as(usize, 1), vt.kitty.placements.items.len);
        vt.prepareImages();
        const shown = vt.kitty.find(7).?;
        try std.testing.expectEqualSlices(u8, rgba, shown.rgba);
        // The transfer buffers gave their memory back.
        try std.testing.expectEqual(@as(usize, 0), vt.kitty.chunks.capacity);
        try std.testing.expect(ring.spill.capacity <= 1024 * 1024);
    }
}

test "REP of plain ASCII matches printing it" {
    var dummy: [1]u8 = .{0};
    var a = try VtState.init(std.testing.allocator, 7, 3, 8, &dummy);
    defer a.deinit();
    var b = try VtState.init(std.testing.allocator, 7, 3, 8, &dummy);
    defer b.deinit();
    a.printCodepoint('z');
    a.rep(12);
    for (0..13) |_| b.printCodepoint('z');
    const da = try a.dumpAlloc(std.testing.allocator);
    defer std.testing.allocator.free(da);
    const db = try b.dumpAlloc(std.testing.allocator);
    defer std.testing.allocator.free(db);
    try std.testing.expectEqualStrings(db, da);
    try std.testing.expectEqual(b.cursor(), a.cursor());
    try std.testing.expectEqual(b.grid().wrap_pending, a.grid().wrap_pending);
}

test "inline UTF-8 decode matches std" {
    const cases = [_][]const u8{ "\xc3\xa9", "\xe6\x97\xa6", "\xf0\x9f\x98\x80", "\xc0\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe6\x97\x41" };
    for (cases) |c| {
        const want: ?u21 = std.unicode.utf8Decode(c) catch null;
        try std.testing.expectEqual(want, VtState.decodeUtf8(c));
    }
}

test "bulk UTF-8 printing matches printCodepoint" {
    const gpa = std.testing.allocator;
    const sample = "旦海司有幼雞‘’“”😀😛 —–§¶ ÀÁÂ ū̀n̂o᷵H̨ a\u{301}\u{302}\u{303}x\xff\xc3\n\té最後";
    var dummy: [1]u8 = .{0};
    for ([_]u16{ 5, 7, 13 }) |cols| for ([_]bool{ true, false }) |shaping| {
        var a = try VtState.init(gpa, cols, 4, 8, &dummy);
        defer a.deinit();
        var b = try VtState.init(gpa, cols, 4, 8, &dummy);
        defer b.deinit();
        a.flags.grapheme_shaping = shaping;
        b.flags.grapheme_shaping = shaping;
        for (0..3) |_| a.feedText(sample);
        for (0..3) |_| {
            var k: usize = 0;
            while (k < sample.len) {
                const c = sample[k];
                if (c < 0x80) {
                    if (c >= 0x21 and c <= 0x7E) b.printCodepoint(c) else C0.dispatch(&b, c);
                    k += 1;
                    continue;
                }
                const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                if (len == 1) {
                    k += 1;
                    continue;
                }
                if (k + len > sample.len) break;
                const cp: ?u21 = std.unicode.utf8Decode(sample[k..][0..len]) catch null;
                k += len;
                if (cp) |v| b.printCodepoint(v);
            }
        }
        const da = try a.dumpCellsAlloc(gpa);
        defer gpa.free(da);
        const db = try b.dumpCellsAlloc(gpa);
        defer gpa.free(db);
        try std.testing.expectEqualStrings(db, da);
        try std.testing.expectEqual(b.cursor(), a.cursor());
        try std.testing.expectEqual(b.grid().wrap_pending, a.grid().wrap_pending);
    };
}

/// Same characters and resolved styles (ids depend on interning order).
fn expectSameCells(va: *const VtState, want: []const Cell, vb: *const VtState, got: []const Cell) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try std.testing.expectEqual(w.codepoint, g.codepoint);
        try std.testing.expectEqual(va.styleOf(w).key(), vb.styleOf(g).key());
    }
}

/// Per-codepoint reference for `feedText`: printable ASCII and decoded
/// UTF-8 through `printCodepoint`, other ASCII through C0.
fn feedTextReference(vt: *VtState, bytes: []const u8) void {
    var k: usize = 0;
    while (k < bytes.len) {
        const c = bytes[k];
        if (c < 0x80) {
            if (c >= 0x20 and c <= 0x7E) vt.printCodepoint(c) else C0.dispatch(vt, c);
            k += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (len == 1) {
            k += 1;
            continue;
        }
        if (k + len > bytes.len) break;
        const cp: ?u21 = std.unicode.utf8Decode(bytes[k..][0..len]) catch null;
        k += len;
        if (cp) |v| vt.printCodepoint(v);
    }
}

test "chunked UTF-8 printing matches printCodepoint on random text" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xc0de_0017);
    const rnd = prng.random();
    const pieces = [_][]const u8{
        "旦", "海", "：", "雞", "é", "ß", "Ω", "😀", "\u{301}", "\u{36f}", "\u{200d}", "a", "Zq", " ", "hello world ",
        "\n", "\r", "\t", "\x08", "\x0e", "\x0f", "\x7f", "\xff", "\x80", "\xc3", "\xe6\x97", "\xed\xa0\x80", "\xe6\x41\x42",
        "0123456789012345678901234567890123456789",
    };
    var dummy: [1]u8 = .{0};
    var text: [700]u8 = undefined;
    for (0..400) |_| {
        var len: usize = 0;
        const target = rnd.uintLessThan(usize, text.len - 64);
        const clean = rnd.boolean();
        while (len < target) {
            const piece = pieces[rnd.uintLessThan(usize, if (clean) 15 else pieces.len)];
            @memcpy(text[len..][0..piece.len], piece);
            len += piece.len;
        }
        const cols: u16 = 2 + rnd.uintLessThan(u16, 30);
        var a = try VtState.init(gpa, cols, 5, 12, &dummy);
        defer a.deinit();
        var b = try VtState.init(gpa, cols, 5, 12, &dummy);
        defer b.deinit();
        const shaping = rnd.boolean();
        const wrap = rnd.uintLessThan(u8, 4) != 0;
        const insert = rnd.uintLessThan(u8, 6) == 0;
        const g1_special = rnd.boolean();
        const ghost = rnd.uintLessThan(u8, 5) == 0;
        for ([_]*VtState{ &a, &b }) |vt| {
            vt.flags.grapheme_shaping = shaping;
            vt.flags.auto_wrap = wrap;
            vt.flags.insert_mode = insert;
            if (g1_special) vt.g1 = .dec_special;
            applyCsi(vt, "\x1b[1;31m");
            vt.ghost = ghost;
        }
        a.feedText(text[0..len]);
        feedTextReference(&b, text[0..len]);
        if (!ghost) {
            const da = try a.dumpCellsAlloc(gpa);
            defer gpa.free(da);
            const db = try b.dumpCellsAlloc(gpa);
            defer gpa.free(db);
            try std.testing.expectEqualStrings(db, da);
        }
        try std.testing.expectEqual(b.cursor(), a.cursor());
        try std.testing.expectEqual(b.grid().wrap_pending, a.grid().wrap_pending);
        try std.testing.expectEqual(b.last_cp, a.last_cp);
        try std.testing.expectEqual(b.gl, a.gl);
    }
}

test "a tiny style table compacts often and every cell keeps its style" {
    const gpa = std.testing.allocator;
    const pieces = [_][]const u8{
        "hello", " world", "\r\n", "\n", "\t", "\x1b[41m", "\x1b[0m", "\x1b[1;4:3;58:2:9:8:7m", "\x1b[K", "\x1b[1K", "\x1b[2K",
        "\x1b[J", "\x1b[2J", "\x1b[3J", "\x1b[3@", "\x1b[2P", "\x1b[4X", "\x1b[2;5r", "\x1b[r", "\x1b[S", "\x1b[T", "\x1b[2L",
        "\x1b[M", "\x1b[H", "\x1b[5;9H", "\x1bM", "\x1b[?1049h", "\x1b[?1049l", "\x1b#8", "旦海😀", "e\u{301}", "x\x1b[7b",
        "\x1b]11;#102030\x07", "\x1b]10;#c0c0c0\x07", "\x1b]111\x07", "\x1b[2;3;4;6$z", "\x1b[1;1;3;5;7$r", "\x1b[65;2;2;3;5$x",
        "\x1b]8;;http://x\x07", "\x1b]8;;\x07", "\x1b[39;49m", "\x1b[7m", "\x1b[2;3;4;6;1;1;1$v",
    };
    var prng = std.Random.DefaultPrng.init(11);
    const rand = prng.random();
    for (0..12) |_| {
        var ring_a = try Ring.CircBuffer.create(gpa, 4096);
        defer ring_a.destroy();
        var ring_b = try Ring.CircBuffer.create(gpa, 4096);
        defer ring_b.destroy();
        ring_a.exact = true;
        ring_b.exact = true;
        var a = try VtState.init(gpa, 13, 6, 30, ring_a.storage);
        defer a.deinit();
        var b = try VtState.init(gpa, 13, 6, 30, ring_b.storage);
        defer b.deinit();
        a.styles.limit = 16;
        var gens: u32 = 0;
        for (0..1500) |step| {
            var color_buf: [40]u8 = undefined;
            const piece = if (rand.uintLessThan(u8, 3) == 0)
                std.fmt.bufPrint(&color_buf, "\x1b[38;2;{d};{d};{d};48;5;{d}m", .{ rand.int(u8), rand.int(u8), rand.uintLessThan(u8, 4), rand.int(u8) }) catch unreachable
            else
                pieces[rand.uintLessThan(usize, pieces.len)];
            const gen = a.styles.gen;
            for ([_]*Ring.CircBuffer{ &ring_a, &ring_b }, [_]*VtState{ &a, &b }) |ring, vt| {
                const at: usize = @intCast(ring.head & (ring.capacity - 1));
                @memcpy(ring.storage[at..][0..piece.len], piece);
                if (!ring.mapped) @memcpy(ring.storage[at + ring.capacity ..][0..piece.len], piece);
                ring.head += piece.len;
                ring.drain(vt.sink());
            }
            if (a.styles.gen != gen) gens += 1;
            if (step % 211 == 210) {
                const cols: u16 = @intCast(8 + rand.uintLessThan(u16, 10));
                try a.resize(cols, 6);
                try b.resize(cols, 6);
            }
            if (step % 307 == 306) {
                var next = a.scheme;
                next.palette[rand.uintLessThan(usize, 16)] = .{ .r = rand.int(u8), .g = 1, .b = 2 };
                a.applyScheme(next);
                b.applyScheme(next);
            }
            // Every cell of both rings (scrollback and unused rows too).
            for (0..2) |k| try expectSameCells(&b, b.grids[k].cells, &a, a.grids[k].cells);
        }
        try std.testing.expect(gens > 20);
        try std.testing.expect(a.styles.list.items.len <= a.styles.limit);
    }
}

test "row extents never change what the grid holds" {
    const gpa = std.testing.allocator;
    const pieces = [_][]const u8{
        "hello", " world", "\r\n", "\n", "\t", "\x1b[41m", "\x1b[0m", "\x1b[44;33m", "\x1b[K", "\x1b[1K", "\x1b[2K",
        "\x1b[J", "\x1b[1J", "\x1b[2J", "\x1b[3J", "\x1b[3@", "\x1b[2P", "\x1b[4X", "\x1b[2;5r", "\x1b[r", "\x1b[S",
        "\x1b[T", "\x1b[2L", "\x1b[M", "\x1b[H", "\x1b[5;9H", "\x1bM", "\x1bD", "\x1b[4h", "\x1b[4l", "x\x1b[7b",
        "旦海😀", "e\u{301}", "\x1b[?1049h", "\x1b[?1049l", "\x1b#8", "\x1b[?7l", "\x1b[?7h", "\x1b]11;#102030\x07",
        "\x1b[2;3;4;6$z", "\x1b[65;2;2;3;5$x", "0123456789012345678901234567890",
    };
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    for (0..40) |round| {
        var ring_a = try Ring.CircBuffer.create(gpa, 4096);
        defer ring_a.destroy();
        var ring_b = try Ring.CircBuffer.create(gpa, 4096);
        defer ring_b.destroy();
        ring_a.exact = true;
        ring_b.exact = true;
        var a = try VtState.init(gpa, 13, 6, 20, ring_a.storage);
        defer a.deinit();
        var b = try VtState.init(gpa, 13, 6, 20, ring_b.storage);
        defer b.deinit();
        for (&b.grids) |*g| g.lazy_clear = false;
        for (0..400) |step| {
            const piece = pieces[rand.uintLessThan(usize, pieces.len)];
            for ([_]*Ring.CircBuffer{ &ring_a, &ring_b }, [_]*VtState{ &a, &b }) |ring, vt| {
                const at: usize = @intCast(ring.head & (ring.capacity - 1));
                @memcpy(ring.storage[at..][0..piece.len], piece);
                if (!ring.mapped) @memcpy(ring.storage[at + ring.capacity ..][0..piece.len], piece);
                ring.head += piece.len;
                ring.drain(vt.sink());
            }
            if (step % 97 == 96) {
                const cols: u16 = @intCast(8 + rand.uintLessThan(u16, 10));
                try a.resize(cols, 6);
                try b.resize(cols, 6);
                for (&b.grids) |*g| g.lazy_clear = false;
            }
            for (0..2) |k| {
                std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(b.grids[k].cells), std.mem.sliceAsBytes(a.grids[k].cells)) catch |err| {
                    std.debug.print("round {d} step {d} grid {d} after {any}\n", .{ round, step, k, piece });
                    return err;
                };
            }
        }
    }
}

test "drain dropping dead SGRs ends with the pen and screen of an exact parse" {
    const gpa = std.testing.allocator;
    const pieces = [_][]const u8{
        "hello ", "x", "\r\n", "\r\n", "\x1b[m", "\x1b[0m", "\x1b[1m", "\x1b[31m", "\x1b[44;33m", "\x1b[0;4m", "\x1b[;7m",
        "\x1b[38;5;9m", "\x1b[38;2;1;2;3m", "\x1b[3m", "\x1b[22m", "\x1b7", "\x1b8", "\x1b[s", "\x1b[2J", "\x1b[H",
        "\x1b[?1049h", "\x1b[?1049l", "\x1bc",
    };
    for (0..60) |round| {
        var ring_a = try Ring.CircBuffer.create(gpa, 4096);
        defer ring_a.destroy();
        var ring_b = try Ring.CircBuffer.create(gpa, 4096);
        defer ring_b.destroy();
        ring_b.exact = true;
        var a = try VtState.init(gpa, 13, 4, 20, ring_a.storage);
        defer a.deinit();
        var b = try VtState.init(gpa, 13, 4, 20, ring_b.storage);
        defer b.deinit();
        for (0..40) |step| {
            for ([_]*Ring.CircBuffer{ &ring_a, &ring_b }, [_]*VtState{ &a, &b }) |ring, vt| {
                var local = std.Random.DefaultPrng.init(round * 1000 + step);
                const lr = local.random();
                for (0..30) |_| {
                    const piece = pieces[lr.uintLessThan(usize, pieces.len)];
                    const at: usize = @intCast(ring.head & (ring.capacity - 1));
                    @memcpy(ring.storage[at..][0..piece.len], piece);
                    if (!ring.mapped) @memcpy(ring.storage[at + ring.capacity ..][0..piece.len], piece);
                    ring.head += piece.len;
                }
                ring.drain(vt.sink());
            }
            for (0..2) |k| {
                const ga = &a.grids[k];
                const gb = &b.grids[k];
                try std.testing.expectEqual(gb.attrs, ga.attrs);
                try std.testing.expectEqual(gb.fg, ga.fg);
                try std.testing.expectEqual(gb.bg, ga.bg);
            }
            try std.testing.expectEqual(b.ul_set, a.ul_set);
        }
    }
}

test "skipDeadLine ends where feeding the dead line would" {
    const gpa = std.testing.allocator;
    var dummy: [1]u8 = .{0};
    const pool = [_][]const u8{ "a", "Z", " ", "~", "\x7f", "é", "旦", "😀", "\xc2", "\xe6\x97", "\xf0\x9f", "\x80", "\xff", "\xc2A", "\xe6A\x97", "\xcc\x81" };
    var prng = std.Random.DefaultPrng.init(11);
    const rand = prng.random();
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    for (0..3000) |_| {
        line.clearRetainingCapacity();
        const n = rand.uintLessThan(usize, 60);
        for (0..n) |_| try line.appendSlice(gpa, pool[rand.uintLessThan(usize, pool.len)]);
        try line.append(gpa, '\r');
        for ([_]bool{ true, false }) |wrap| {
            var a = try VtState.init(gpa, 9, 4, 8, &dummy);
            defer a.deinit();
            var b = try VtState.init(gpa, 9, 4, 8, &dummy);
            defer b.deinit();
            for ([_]*VtState{ &a, &b }) |vt| {
                vt.flags.auto_wrap = wrap;
                vt.grid().cursor.row = 3;
                vt.last_cp = 'Q';
                vt.ghost = true;
            }
            if (!a.skipDeadLine(line.items)) continue;
            b.feedText(line.items);
            try std.testing.expectEqual(b.last_cp, a.last_cp);
            try std.testing.expectEqual(b.grid().cursor, a.grid().cursor);
            try std.testing.expectEqual(b.grid().wrap_pending, a.grid().wrap_pending);
        }
    }
}
