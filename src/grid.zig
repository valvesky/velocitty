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
    .{ .r = 0, .g = 0, .b = 0 },      .{ .r = 170, .g = 0, .b = 0 },
    .{ .r = 0, .g = 170, .b = 0 },    .{ .r = 170, .g = 85, .b = 0 },
    .{ .r = 0, .g = 0, .b = 170 },    .{ .r = 170, .g = 0, .b = 170 },
    .{ .r = 0, .g = 170, .b = 170 },  .{ .r = 170, .g = 170, .b = 170 },
    .{ .r = 85, .g = 85, .b = 85 },   .{ .r = 255, .g = 85, .b = 85 },
    .{ .r = 85, .g = 255, .b = 85 },  .{ .r = 255, .g = 255, .b = 85 },
    .{ .r = 85, .g = 85, .b = 255 },  .{ .r = 255, .g = 85, .b = 255 },
    .{ .r = 85, .g = 255, .b = 255 }, .{ .r = 255, .g = 255, .b = 255 },
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
    /// Underline uses `Cell.ul` instead of fg.
    ul_color: bool = false,
    /// 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed (foot SGR 4:n).
    underline_style: u3 = 0,
    fg_explicit: bool = false,
    bg_explicit: bool = false,
    _padding: u1 = 0,
};

pub const Rgb = packed struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};

/// `@memset` for cells: stores eight 8-byte cells per 64-byte vector.
pub fn fillCells(dst: []Cell, value: Cell) void {
    const bits: u64 = @bitCast(value);
    const pat: @Vector(8, u64) = @splat(bits);
    const words: [*]u64 = @ptrCast(dst.ptr);
    const n = dst.len;
    var i: usize = 0;
    while (i + 8 <= n) : (i += 8) words[i..][0..8].* = pat;
    while (i < n) : (i += 1) words[i] = bits;
}

/// Everything about a cell except its character: colors (resolved RGB, as
/// the pen held them), underline color and attributes. Stored once in
/// `Styles`; cells refer to it by id.
pub const Style = packed struct(u128) {
    fg: Color = Color.default_fg,
    bg: Color = Color.default_bg,
    /// Underline color, used when `attrs.ul_color` is set.
    ul: Rgb = .{},
    attrs: Attrs = .{},
    _pad: u24 = 0,

    pub inline fn key(self: Style) u128 {
        return @bitCast(self);
    }
};

/// Index into `Styles.list`. 0 is `Style{}`'s slot (it is recolored like
/// any other entry, so it is not always `Style{}`).
pub const StyleId = u32;

/// 8 bytes: the character and its interned style. A wide character's
/// second cell holds codepoint 0.
pub const Cell = packed struct(u64) {
    codepoint: u21 = ' ',
    _pad: u11 = 0,
    style: StyleId = 0,
};

/// Interned styles shared by both grids of a terminal. The pen interns its
/// style when it prints (a small memo of recent interns makes that a
/// compare while the pen and the erase style do not change); erase paths
/// intern the erase style.
///
/// Lifetime: once `list` reaches `limit`, `compact` marks every id still in
/// a cell (both grids, every ring row including scrollback and rows not in
/// use, and the row-tail blanks), drops the rest, renumbers the survivors
/// in order and rewrites every cell. Pens are kept as raw colors, not ids,
/// so nothing else holds an id across calls. Ids change only there, and
/// entries change only in `recolor`; both bump `gen` (the renderer keeps a
/// cell snapshot and repaints everything when `gen` moves). A caller must
/// not keep an id across a call that may intern a new style (anything that
/// clears with a blank, or prints): fetch it again after.
/// `limit` doubles when more than half the entries survive a compaction,
/// so compaction stays amortized O(1) per new style and a screen with more
/// distinct live styles than any fixed limit still gets exact colors.
pub const Styles = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayListUnmanaged(Style) = .empty,
    map: std.AutoHashMapUnmanaged(u128, StyleId) = .empty,
    limit: u32 = default_limit,
    gen: u32 = 0,
    /// Direct-mapped memo of recent interns (by a cheap hash of the key):
    /// the pen, the erase style and the few styles a TUI cycles through
    /// resolve without the hash map.
    cache: [cache_len]Entry = @splat(no_entry),
    /// The latest intern (usually the pen): checked before the memo.
    last: Entry = no_entry,
    /// The cell buffers whose ids `compact` keeps and rewrites, one per grid.
    roots: [2]Root = .{ .{}, .{} },

    pub const default_limit: u32 = 1 << 16;
    const cache_bits = 5;
    const cache_len = 1 << cache_bits;
    const Entry = struct { key: u128, id: StyleId };
    /// Never a real key: `Style._pad` is always zero.
    const no_entry: Entry = .{ .key = std.math.maxInt(u128), .id = 0 };
    pub const Root = struct { cells: []Cell = &.{}, tail: []u64 = &.{} };

    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*Styles {
        const self = try allocator.create(Styles);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator };
        errdefer self.list.deinit(allocator);
        try self.list.append(allocator, .{});
        try self.map.put(allocator, (Style{}).key(), 0);
        return self;
    }

    pub fn destroy(self: *Styles) void {
        const allocator = self.allocator;
        self.list.deinit(allocator);
        self.map.deinit(allocator);
        allocator.destroy(self);
    }

    pub inline fn get(self: *const Styles, id: StyleId) Style {
        return self.list.items[id];
    }

    pub inline fn of(self: *const Styles, c: Cell) Style {
        return self.list.items[c.style];
    }

    inline fn cacheSlot(k: u128) usize {
        const x = @as(u64, @truncate(k)) ^ @as(u64, @truncate(k >> 64));
        // Top log2(cache_len) bits of a multiplicative hash.
        return @intCast((x *% 0x9E37_79B9_7F4A_7C15) >> (64 - cache_bits));
    }

    pub inline fn intern(self: *Styles, s: Style) StyleId {
        const k = s.key();
        if (self.last.key == k) return self.last.id;
        return self.internSlow(k);
    }

    fn internSlow(self: *Styles, k: u128) StyleId {
        const e = &self.cache[cacheSlot(k)];
        if (e.key != k) {
            const id = self.map.get(k) orelse self.add(k);
            // After `add`: a compaction there clears the memo.
            self.cache[cacheSlot(k)] = .{ .key = k, .id = id };
        }
        self.last = self.cache[cacheSlot(k)];
        return self.last.id;
    }

    fn add(self: *Styles, k: u128) StyleId {
        if (self.list.items.len >= self.limit) self.compact();
        const allocator = self.allocator;
        // Out of memory: the default style (wrong colors, but a valid id).
        self.list.ensureUnusedCapacity(allocator, 1) catch return 0;
        self.map.ensureUnusedCapacity(allocator, 1) catch return 0;
        const id: StyleId = @intCast(self.list.items.len);
        self.list.appendAssumeCapacity(@bitCast(k));
        self.map.putAssumeCapacity(k, id);
        return id;
    }

    /// Drop every entry no cell refers to and renumber the rest (see the
    /// type comment). Skipped if its scratch memory cannot be allocated.
    pub fn compact(self: *Styles) void {
        const allocator = self.allocator;
        const n = self.list.items.len;
        var live = std.DynamicBitSetUnmanaged.initEmpty(allocator, n) catch return;
        defer live.deinit(allocator);
        const remap = allocator.alloc(StyleId, n) catch return;
        defer allocator.free(remap);
        live.set(0);
        for (self.roots) |root| {
            for (root.cells) |c| live.set(c.style);
            for (root.tail) |t| live.set(@as(Cell, @bitCast(t)).style);
        }
        var next: StyleId = 0;
        for (0..n) |i| {
            if (!live.isSet(i)) continue;
            remap[i] = next;
            self.list.items[next] = self.list.items[i];
            next += 1;
        }
        self.list.shrinkRetainingCapacity(next);
        for (self.roots) |root| {
            for (root.cells) |*c| c.style = remap[c.style];
            for (root.tail) |*t| {
                var c: Cell = @bitCast(t.*);
                c.style = remap[c.style];
                t.* = @bitCast(c);
            }
        }
        self.rebuildMap();
        if (@as(u64, next) * 2 > self.limit) self.limit = @intCast(@min(@as(u64, self.limit) * 2, std.math.maxInt(StyleId)));
    }

    /// Apply `f(ctx, &style)` to every entry (a palette or default color
    /// change); cells keep their ids and pick the new colors up.
    pub fn recolor(self: *Styles, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Style) void) void {
        for (self.list.items) |*s| f(ctx, s);
        self.rebuildMap();
    }

    /// Re-key the map after entries changed or moved (equal entries may
    /// now repeat: any of their ids is fine). Bumps `gen`.
    fn rebuildMap(self: *Styles) void {
        // The map only deduplicates: a key it misses (out of memory) just
        // gets a second entry later.
        self.map.clearRetainingCapacity();
        for (self.list.items, 0..) |s, i| self.map.put(self.allocator, s.key(), @intCast(i)) catch break;
        self.cache = @splat(no_entry);
        self.last = no_entry;
        self.gen +%= 1;
    }
};

pub const Cursor = struct { row: u16 = 0, col: u16 = 0 };

pub const Grid = struct {
    cells: []Cell,
    starts: []u32,
    /// 1 if this ring row continues onto the next (DECAWM soft wrap).
    wraps: []u8,
    /// Per ring row: cells from `extent` to the row end all equal `tail`
    /// (the blank the row was last cleared with), so clearing it again with
    /// the same blank only needs `[0, extent)`. `full_extent`: unknown.
    extent: []u16,
    tail: []u64,
    /// Style table shared with the other grid; `slot` is this grid's root
    /// in it (the cells `Styles.compact` rewrites).
    styles: *Styles,
    slot: u1,
    /// Cells per row.
    width: u16,
    /// Use `extent` to shorten whole-row clears (tests turn it off to
    /// compare against clearing everything).
    lazy_clear: bool = true,
    cap: u32,
    head: u32 = 0,
    used: u32,
    /// Absolute line number of screen row 0; grows by one per line pushed
    /// into history. The oldest kept line is `base - (used - rows)`.
    base: u64 = 0,
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

    /// The grid registers its buffers as root `slot` of `styles`; the
    /// caller must keep it in place until `deinit` (or call `register`
    /// again after moving it, though only the buffers are recorded).
    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16, cap: u32, styles: *Styles, slot: u1) !Grid {
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
        const extent = try allocator.alloc(u16, cap);
        errdefer allocator.free(extent);
        @memset(extent, 0);
        const tail = try allocator.alloc(u64, cap);
        errdefer allocator.free(tail);
        @memset(tail, @as(u64, @bitCast(Cell{})));

        const g = Grid{
            .cells = cells,
            .starts = starts,
            .wraps = wraps,
            .extent = extent,
            .tail = tail,
            .styles = styles,
            .slot = slot,
            .width = cols,
            .cap = cap,
            .used = rows,
            .scroll_bottom = rows -| 1,
        };
        g.register();
        return g;
    }

    /// Record the current cell and tail buffers in the style table.
    pub fn register(self: *const Grid) void {
        self.styles.roots[self.slot] = .{ .cells = self.cells, .tail = self.tail };
    }

    pub fn deinit(self: *Grid, allocator: std.mem.Allocator) void {
        self.styles.roots[self.slot] = .{};
        allocator.free(self.cells);
        allocator.free(self.starts);
        allocator.free(self.wraps);
        allocator.free(self.extent);
        allocator.free(self.tail);
    }

    pub const full_extent: u16 = std.math.maxInt(u16);

    /// Every row may hold anything (after resize or a whole-grid recolor).
    pub fn markAllWritten(self: *Grid) void {
        @memset(self.extent, full_extent);
    }

    /// Cells `[0, end)` of `row` were written by a tracked writer.
    pub inline fn noteWrite(self: *Grid, row: u16, end: u16) void {
        const j = self.lineIndex(row);
        if (self.extent[j] < end) self.extent[j] = end;
    }

    /// Replace the row-tracking arrays after the ring was rebuilt.
    fn resizeTracking(self: *Grid, allocator: std.mem.Allocator, cap: u32) std.mem.Allocator.Error!void {
        const extent = try allocator.alloc(u16, cap);
        errdefer allocator.free(extent);
        const tail = try allocator.alloc(u64, cap);
        // Never read while the extent is full, but `Styles.compact` scans it.
        @memset(tail, @as(u64, @bitCast(Cell{})));
        allocator.free(self.extent);
        allocator.free(self.tail);
        self.extent = extent;
        self.tail = tail;
        self.markAllWritten();
        self.register();
    }

    pub fn setRowWrap(self: *Grid, row: u16, wrapped: bool) void {
        self.wraps[self.lineIndex(row)] = if (wrapped) 1 else 0;
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
        const blank = self.blankCell();
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

        try self.resizeTracking(allocator, new_cap);
        allocator.free(self.cells);
        allocator.free(self.starts);
        allocator.free(self.wraps);
        self.cells = new_cells;
        self.register();
        self.starts = new_starts;
        self.wraps = new_wraps;
        self.cap = new_cap;
        self.width = new_cols;
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
        const blank = self.blankCell();
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
        var new_wrap_pending = false;

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
                const insertion_offset = offset + @intFromBool(self.wrap_pending);
                if (self.wrap_pending and insertion_offset % new_cols == 0) {
                    mapCursor(insertion_offset - 1, new_cols, before_rows, &new_cur_row, &new_cur_col);
                    new_wrap_pending = true;
                } else {
                    mapCursor(insertion_offset, new_cols, before_rows, &new_cur_row, &new_cur_col);
                }
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

        try self.resizeTracking(allocator, new_cap);
        allocator.free(self.cells);
        allocator.free(self.starts);
        allocator.free(self.wraps);
        self.cells = new_cells;
        self.register();
        self.starts = new_starts;
        self.wraps = new_wraps;
        self.cap = new_cap;
        self.width = new_cols;
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
        self.wrap_pending = new_wrap_pending;
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
        const blank = Cell{ .style = self.styles.intern(.{ .fg = scheme.fg, .bg = scheme.bg }) };
        fillCells(self.cells, blank);
        @memset(self.extent, 0);
        @memset(self.tail, @as(u64, @bitCast(blank)));
        self.width = cols;
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

    /// Ring index of screen row `row` (< cap): a compare instead of `%`.
    pub inline fn lineIndex(self: *const Grid, row: u32) u32 {
        const i = self.head + row;
        return if (i >= self.cap) i - self.cap else i;
    }

    /// Mutable cell: the row counts as fully written. Tracked writers use
    /// `cellPtr` + `noteWrite` instead.
    pub inline fn getCell(self: *Grid, row: u16, col: u16) *Cell {
        const line_idx = self.lineIndex(row);
        self.extent[line_idx] = full_extent;
        return &self.cells[self.starts[line_idx] + col];
    }

    /// Mutable cells of `row` from `col`, without marking the row; the
    /// caller reports what it wrote with `noteWrite`.
    pub inline fn cellPtr(self: *Grid, row: u16, col: u16) [*]Cell {
        const line_idx = self.lineIndex(row);
        return self.cells[self.starts[line_idx] + col ..].ptr;
    }

    pub inline fn cellAt(self: *const Grid, row: u16, col: u16) Cell {
        const line_idx = self.lineIndex(row);
        return self.cells[self.starts[line_idx] + col];
    }

    /// Mutable row: it counts as fully written.
    pub inline fn rowSlice(self: *Grid, row: u16, cols: u16) []Cell {
        const line_idx = self.lineIndex(row);
        self.extent[line_idx] = full_extent;
        const off = self.starts[line_idx];
        return self.cells[off .. off + cols];
    }

    pub inline fn rowSliceConst(self: *const Grid, row: u16, cols: u16) []const Cell {
        const line_idx = self.lineIndex(row);
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

    pub inline fn viewRowWrapped(self: *const Grid, row: u16) bool {
        const line_idx = (self.head + self.cap - self.scroll + row) % self.cap;
        return self.wraps[line_idx] != 0;
    }

    /// Full-grid scroll that keeps the outgoing top line in the ring (primary history).
    pub fn historyScrollUp(self: *Grid, n: u16, cols: u16, rows: u16) void {
        var k: u16 = 0;
        while (k < n) : (k += 1) {
            self.head += 1;
            if (self.head == self.cap) self.head = 0;
            if (self.used < self.cap) self.used += 1;
            self.base += 1;
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

    /// The erase style: pen colors and which of them are explicit.
    pub inline fn blankStyle(self: *const Grid) Style {
        return .{
            .attrs = .{ .fg_explicit = self.attrs.fg_explicit, .bg_explicit = self.attrs.bg_explicit },
            .fg = self.fg,
            .bg = self.bg,
        };
    }

    /// A blank in the erase style. May intern (see `Styles`).
    pub inline fn blankCell(self: *Grid) Cell {
        return .{ .codepoint = ' ', .style = self.styles.intern(self.blankStyle()) };
    }

    /// Primary cell mutation primitive
    pub fn writeCell(self: *Grid, row: u16, col: u16, cp: u21) void {
        const id = self.styles.intern(.{ .attrs = self.attrs, .fg = self.fg, .bg = self.bg });
        const cell = &self.cellPtr(row, col)[0];
        self.noteWrite(row, col + 1);
        cell.* = .{ .codepoint = cp, .style = id };
    }

    /// Clear cell range [start_col, end_col) on a given row
    pub fn clearRange(self: *Grid, row: u16, start_col: u16, end_col: u16) void {
        const line_idx = self.lineIndex(row);
        const row_offset = self.starts[line_idx];
        const blank = self.blankCell();
        const bits: u64 = @bitCast(blank);
        if (start_col == 0 and end_col >= self.width) {
            // A whole row: past `extent` it already holds this blank.
            const ext = self.extent[line_idx];
            const n = if (self.lazy_clear and self.tail[line_idx] == bits and ext != full_extent) @min(ext, end_col) else end_col;
            fillCells(self.cells[row_offset .. row_offset + n], blank);
            self.extent[line_idx] = 0;
            self.tail[line_idx] = bits;
            return;
        }
        fillCells(self.cells[row_offset + start_col .. row_offset + end_col], blank);
        if (self.extent[line_idx] < end_col) self.extent[line_idx] = end_col;
    }

    /// Insert blank characters at row/col, shifting existing cells right
    pub fn insertCells(self: *Grid, row: u16, col: u16, count: u16, cols: u16) void {
        if (col >= cols) return;
        const line_idx = self.lineIndex(row);
        const offset = self.starts[line_idx];
        const shift_count = @min(count, cols - col);
        const copy_len = cols - col - shift_count;
        self.extent[line_idx] = full_extent;

        if (copy_len > 0) {
            std.mem.copyBackwards(
                Cell,
                self.cells[offset + col + shift_count .. offset + cols],
                self.cells[offset + col .. offset + col + copy_len],
            );
        }
        fillCells(self.cells[offset + col .. offset + col + shift_count], self.blankCell());
    }

    /// Delete characters at row/col, shifting remaining cells left
    pub fn deleteCells(self: *Grid, row: u16, col: u16, count: u16, cols: u16) void {
        if (col >= cols) return;
        const line_idx = self.lineIndex(row);
        const offset = self.starts[line_idx];
        const del_count = @min(count, cols - col);
        const copy_len = cols - col - del_count;
        self.extent[line_idx] = full_extent;

        if (copy_len > 0) {
            std.mem.copyForwards(
                Cell,
                self.cells[offset + col .. offset + col + copy_len],
                self.cells[offset + col + del_count .. offset + cols],
            );
        }
        fillCells(self.cells[offset + cols - del_count .. offset + cols], self.blankCell());
    }

    /// Scroll defined region up by n lines
    pub fn scrollUp(self: *Grid, top: u16, bottom: u16, n: u16, cols: u16) void {
        const count = @min(n, bottom - top + 1);
        var i: u16 = top;
        while (@as(u32, i) + count <= bottom) : (i += 1) {
            const src_idx = (self.head + i + count) % self.cap;
            const dst_idx = (self.head + i) % self.cap;
            std.mem.copyForwards(
                Cell,
                self.cells[self.starts[dst_idx] .. self.starts[dst_idx] + cols],
                self.cells[self.starts[src_idx] .. self.starts[src_idx] + cols],
            );
            self.wraps[dst_idx] = self.wraps[src_idx];
            self.extent[dst_idx] = self.extent[src_idx];
            self.tail[dst_idx] = self.tail[src_idx];
        }
        var clear_row: u16 = @intCast(@as(u32, bottom) + 1 - count);
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
            self.extent[dst_idx] = self.extent[src_idx];
            self.tail[dst_idx] = self.tail[src_idx];
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
        if (cp == 0 and n >= 2 and row[n - 2].codepoint != 0 and row[n - 2].codepoint != ' ') break;
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
    const styles = try Styles.create(std.testing.allocator);
    defer styles.destroy();
    var g = try Grid.init(std.testing.allocator, 4, 2, 8, styles, 0);
    defer g.deinit(std.testing.allocator);
    g.writeCell(0, 0, 'A');
    g.writeCell(0, 1, 'B');
    try std.testing.expectEqual(@as(u21, 'A'), g.cellAt(0, 0).codepoint);
    try g.resize(std.testing.allocator, 4, 2, 6, 3, 8, true);
    try std.testing.expectEqual(@as(u21, 'A'), g.cellAt(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), g.cellAt(0, 1).codepoint);
}

test "fillCells matches memset" {
    var a: [19]Cell = undefined;
    var b: [19]Cell = undefined;
    const v: Cell = .{ .codepoint = 'q', .style = 0xdead_beef };
    for (0..19) |n| {
        @memset(&a, Cell{});
        @memset(&b, Cell{});
        @memset(a[0..n], v);
        fillCells(b[0..n], v);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&a), std.mem.sliceAsBytes(&b));
    }
}

test "cells are 8 bytes" {
    try std.testing.expectEqual(8, @sizeOf(Cell));
    try std.testing.expectEqual(16, @sizeOf(Style));
}

test "a full style table compacts without reusing live ids" {
    const gpa = std.testing.allocator;
    const styles = try Styles.create(gpa);
    defer styles.destroy();
    styles.limit = 64;
    var g = try Grid.init(gpa, 8, 4, 6, styles, 0);
    defer g.deinit(gpa);
    var alt = try Grid.init(gpa, 8, 4, 4, styles, 1);
    defer alt.deinit(gpa);
    // Every cell gets its own style; most are overwritten later, so their
    // ids die. Check after every write that each cell still resolves to the
    // style it was written with.
    var want: [2][8 * 6]u32 = @splat(@splat(0));
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var serial: u32 = 1;
    var compactions: u32 = 0;
    for (0..5000) |_| {
        const which = rnd.uintLessThan(u8, 2);
        const grid = if (which == 0) &g else &alt;
        const ncells = grid.cells.len;
        const k = rnd.uintLessThan(usize, ncells);
        // Reuse an old color now and then so lookups hit existing entries.
        const color = if (rnd.uintLessThan(u8, 4) == 0) 1 + rnd.uintLessThan(u32, serial) else serial;
        serial += 1;
        const st: Style = .{ .fg = @bitCast(color), .bg = Color.default_bg };
        const gen = styles.gen;
        grid.cells[k] = .{ .codepoint = 'x', .style = styles.intern(st) };
        if (styles.gen != gen) compactions += 1;
        want[which][k] = color;
        try std.testing.expect(styles.list.items.len <= styles.limit);
        for ([_]*Grid{ &g, &alt }, 0..) |gr, w| {
            for (gr.cells, 0..) |c, i| {
                const got = styles.of(c);
                if (want[w][i] == 0) {
                    try std.testing.expectEqual((Style{}).key(), got.key());
                } else {
                    try std.testing.expectEqual(want[w][i], @as(u32, @bitCast(got.fg)));
                }
            }
        }
    }
    try std.testing.expect(compactions > 10);
    // At most 80 cells + the default are live: the limit stops growing
    // once that is under half of it.
    try std.testing.expect(styles.limit <= 256);
}

test "the style limit grows when every id is live" {
    const gpa = std.testing.allocator;
    const styles = try Styles.create(gpa);
    defer styles.destroy();
    styles.limit = 16;
    var g = try Grid.init(gpa, 10, 10, 10, styles, 0);
    defer g.deinit(gpa);
    for (g.cells, 0..) |*c, i| c.* = .{ .codepoint = 'x', .style = styles.intern(.{ .fg = @bitCast(@as(u32, @intCast(i + 1))) }) };
    for (g.cells, 0..) |c, i| try std.testing.expectEqual(@as(u32, @intCast(i + 1)), @as(u32, @bitCast(styles.of(c).fg)));
    try std.testing.expect(styles.limit >= 101);
}
