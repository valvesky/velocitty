//! Run preparation owned by CircBuffer: scan/classify input, cache CSI parses,
//! and omit obsolete painting without changing visible terminal state.
//! Owns metadata only; input bytes, stream buffers, and PTY I/O belong to the ring.

const std = @import("std");
const assert = std.debug.assert;
const SIMD = @import("simd.zig");
const Csi = @import("csiparse.zig");

pub const Run = struct {
    pub const Kind = enum(u8) {
        /// Printable text with spaces, CR, BS, HT and UTF-8: the VT splits it.
        text,
        /// One LF, VT, FF, SO or SI (or BS under reverse wraparound).
        c0,
        esc,
        csi,
        osc,
        /// DCS, APC, PM, SOS.
        str,
    };

    pub const Flags = packed struct(u16) {
        /// Bytes live in the stream buffer instead of the ring.
        stream: bool = false,
        /// Dead text or LF: the cursor moves as if it printed, no cell is
        /// written and an LF at the bottom does not scroll.
        ghost: bool = false,
        // Shared scanner/VT bookkeeping for consumption-time visibility checks.
        screen: u1 = 0,
        /// LF inside a full-screen scroll region.
        scrolls: bool = false,
        /// Moves the cursor up or to an absolute position.
        moves: bool = false,
        _: u1 = 0,
        /// A screen switch or cursor restore: the LF count restarts on
        /// both screens.
        resets: bool = false,
        /// Text: how many leading bytes are printable ASCII (0x20..0x7E),
        /// found in the scanner's pass (`max_plain`: at least that many).
        /// The VT prints them without looking at them again.
        plain: u9 = 0,
    };

    pub const max_plain: u9 = std.math.maxInt(u9);

    kind: Kind,
    role: Role = .text,
    flags: Flags = .{},
    off: u32,
    len: u32,
};

pub const Role = enum(u8) {
    /// Text: paints or moves within a line.
    text,
    /// LF/VT/FF/IND/NEL: counts toward scrolling content off.
    lf,
    /// Upward or absolute cursor motion: earlier lines may be revisited.
    motion,
    /// Paints or moves without revisiting earlier lines.
    content,
    /// Terminal state (modes, title, colors, scroll region).
    state,
    /// Anything else.
    ordered,
    /// SGR: always applied; never counted toward text-run pruning.
    sgr,
    /// Always parsed: the application waits for the reply.
    query,
    /// Clears its whole screen (ED 2, ED 0 from home).
    barrier,
    /// Clears the alt screen (1049 entered from the primary screen).
    barrier_alt,
    /// Clears both screens (RIS).
    barrier_all,
    /// Sixel or kitty graphics: always fed (a dead placement still moves
    /// the cursor, replaces ids and is freed with its line).
    image,
};

/// Terminal state the drain needs to decide what is visible.
pub const View = struct {
    rows: u16,
    alt: bool,
    /// Per screen: the scroll region is the whole screen.
    full_region: [2]bool = .{ true, true },
    /// DECOM: CUP home is the scroll region's top, not the screen's.
    origin: bool = false,
    /// Reverse wraparound (with autowrap, BS at column 0 moves up a line).
    reverse_wrap: bool = false,
};

/// A completed stream to classify before the ring bytes; borrows its bytes.
pub const Initial = struct { run: Run, bytes: []const u8 };

/// Storage work the owner must perform after scanning.
pub const Result = struct {
    /// Incomplete ESC/CSI/UTF-8 bytes to retain for the next read.
    held: u32 = 0,
    /// The bounded metadata workset is full (or allocation failed): consume
    /// this prefix, then retry the rest without losing a run.
    retry: bool = false,
    /// Unterminated string to move out of the ring into stream storage.
    stream: ?Run = null,
};

/// Unterminated CSI/ESC/UTF-8 longer than this is dropped instead of held.
const max_hold: u32 = 4096;

/// Hard workset budgets, independent of input/ring capacity.
pub const max_runs = 4096;
pub const max_csis = 2048;
pub const max_csi_params = 8192;
pub const max_csi_subs = 4096;

/// A parsed CSI in `Preparser.csis` (offsets into `csi_params`/`csi_subs`).
const CsiHead = struct {
    private: u32,
    params: u32,
    subs: u32,
    final: u8,
    n: u8,
    n_subs: u8,
};

pub const Preparser = struct {
    allocator: std.mem.Allocator,
    runs: std.ArrayListUnmanaged(Run) = .empty,
    /// Cached CSI heads follow CSI runs in order. On cache OOM the VT
    /// reparses their bytes; no state-changing run is dropped.
    csis: std.ArrayListUnmanaged(CsiHead) = .empty,
    csi_params: std.ArrayListUnmanaged(Csi.Param) = .empty,
    csi_subs: std.ArrayListUnmanaged(u32) = .empty,
    csi_ok: bool = true,
    csi_spare: Csi.Bufs = .{},
    exact: bool = false,
    rows: u16 = 0,
    visibility_ready: bool = false,
    screens: u2 = 0,
    barriers: u2 = 0,
    scroll_lfs: [2]u32 = .{ 0, 0 },
    /// Runs before each screen's cutoff cannot affect its visible cells.
    cut: [2]u32 = .{ 0, 0 },
    /// XTRESTORE has effects the scanner cannot follow safely.
    blind: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Preparser {
        var self: Preparser = .{ .allocator = allocator };
        try self.runs.ensureTotalCapacityPrecise(allocator, 1024);
        return self;
    }

    pub fn deinit(self: *Preparser) void {
        self.runs.deinit(self.allocator);
        self.csis.deinit(self.allocator);
        self.csi_params.deinit(self.allocator);
        self.csi_subs.deinit(self.allocator);
        self.* = undefined;
    }

    /// Frame input and cache its initial view. Obsolescence is evaluated only
    /// when a consumer asks about a span; framing never skips or drops it.
    pub fn prepare(self: *Preparser, slice: []const u8, start: u32, view: View, exact: bool, initial: ?Initial) Result {
        self.exact = exact;
        self.rows = view.rows;
        self.visibility_ready = false;
        self.cut = .{ 0, 0 };
        return self.scan(slice, start, view, initial);
    }

    /// One consumption-time predicate, shared by all spans in this batch.
    /// The reverse proof is lazy and cached, never repeated per text span.
    pub fn isSpanObsolete(self: *Preparser, index: usize) bool {
        const span = self.runs.items[index];
        if (span.kind != .text and span.role != .lf) return false;
        if (self.exact) return false;
        if (span.flags.ghost) return true;
        if (self.blind) return false;
        if (!self.visibility_ready) {
            self.visibility_ready = true;
            const need: u32 = 2 * @as(u32, self.rows) -| 1;
            // No clear and too few scrolling LFs means no safe cutoff:
            // CSI-heavy, non-scrolling input takes this O(1) exit.
            var remaining = self.barriers;
            inline for (0..2) |k| {
                if (self.scroll_lfs[k] >= need) remaining |= @as(u2, 1) << k;
            }
            remaining &= self.screens;
            var lfs = [2]u32{ 0, 0 };
            var i = self.runs.items.len;
            while (i > 0 and remaining != 0) {
                i -= 1;
                const run = self.runs.items[i];
                const screen = run.flags.screen;
                const bit = @as(u2, 1) << screen;
                var kills: u2 = 0;
                switch (run.role) {
                    .lf => {
                        if (!run.flags.scrolls) {
                            lfs[screen] = 0;
                        } else {
                            lfs[screen] += 1;
                            if (lfs[screen] >= need) kills = bit;
                        }
                    },
                    .motion => lfs[screen] = 0,
                    .barrier => kills = bit,
                    .barrier_alt => kills = 0b10,
                    .barrier_all => kills = 0b11,
                    else => {},
                }
                inline for (0..2) |k| {
                    const mask = @as(u2, 1) << k;
                    if (kills & remaining & mask != 0) self.cut[k] = @intCast(i);
                }
                remaining &= ~kills;
                if (run.flags.moves) lfs[screen] = 0;
                if (run.flags.resets) lfs = .{ 0, 0 };
            }
        }
        return index < self.cut[span.flags.screen];
    }

    // ------------------------------------------------------------ scan

    /// A completed stream, if any, is classified before the ring bytes.
    fn scan(self: *Preparser, slice: []const u8, start: u32, view: View, initial: ?Initial) Result {
        self.runs.clearRetainingCapacity();
        self.csis.clearRetainingCapacity();
        self.csi_params.clearRetainingCapacity();
        self.csi_subs.clearRetainingCapacity();
        self.csi_ok = true;
        self.blind = false;
        self.screens = 0;
        self.barriers = 0;
        self.scroll_lfs = .{ 0, 0 };
        var st = Scan{
            .parser = self,
            .rows = view.rows,
            .screen = @intFromBool(view.alt),
            .full = view.full_region,
            .origin_off = !view.origin,
            .rwrap = view.reverse_wrap,
            .track_visibility = !self.exact,
        };
        const to_read: u32 = @intCast(slice.len);
        var i: u32 = 0;
        if (initial) |first| st.classify(first.run, first.bytes);

        while (i < to_read) {
            // One iteration emits at most a text run and a control/escape.
            // Never silently lose a state-changing run on metadata OOM.
            if (self.runs.items.len + 2 > max_runs)
                return .{ .held = to_read - i, .retry = true };
            self.reserveBounded(Run, &self.runs, 2, max_runs) catch
                return .{ .held = to_read - i, .retry = true };
            const text_start = i;
            // Back-to-back escapes skip the text scan.
            if (slice[i] == 0x1B) {
                if (self.escape(&st, slice, start, &i)) |held| return held;
                continue;
            }
            // Under reverse wraparound a BS can move up a line: it gets its
            // own run so the LF count restarts there. The same pass finds
            // the printable-ASCII prefix (`Run.Flags.plain`).
            const t = if (st.rwrap)
                SIMD.scanText(slice[i..], &.{ 0x08, 0x0A, 0x0B, 0x0C, 0x0E, 0x0F, 0x1B })
            else
                SIMD.scanText(slice[i..], &.{ 0x0A, 0x0B, 0x0C, 0x0E, 0x0F, 0x1B });
            i += t.stop;
            const plain: u9 = @intCast(@min(t.plain, Run.max_plain));
            if (i >= to_read) {
                // An incomplete UTF-8 sequence at the very end waits for more.
                const cut = utf8Tail(slice[text_start..i]);
                if (i - cut > text_start) st.push(.{ .kind = .text, .flags = .{ .plain = plain }, .off = start + text_start, .len = i - cut - text_start });
                return .{ .held = cut };
            }
            if (i > text_start) st.push(.{ .kind = .text, .flags = .{ .plain = plain }, .off = start + text_start, .len = i - text_start });
            const c = slice[i];
            if (c != 0x1B) {
                const lf = c >= 0x0A and c <= 0x0C;
                st.push(.{
                    .kind = .c0,
                    .role = if (lf) .lf else if (c == 0x08) .motion else .ordered,
                    .flags = .{ .scrolls = lf and st.full[st.screen] },
                    .off = start + i,
                    .len = 1,
                });
                i += 1;
                continue;
            }
            if (self.escape(&st, slice, start, &i)) |held| return held;
        }
        return .{};
    }

    /// The escape sequence at `slice[i.*]`: tag it and step over it.
    /// Non-null ends the scan: hold an incomplete tail, stream a string,
    /// or consume overlong garbage.
    inline fn escape(self: *Preparser, st: *Scan, slice: []const u8, start: u32, i: *u32) ?Result {
        const rest = slice[i.*..];
        if (rest.len >= 2 and rest[1] == '[') {
            // CSI: found and parsed in one pass, straight into the drain's
            // arrays (the VT applies this parse).
            if (self.csi_ok and (self.csis.items.len == max_csis or
                self.csi_params.items.len + Csi.max_params > max_csi_params or
                self.csi_subs.items.len + Csi.max_subs > max_csi_subs))
                return .{ .held = @intCast(rest.len), .retry = true };
            const ok = self.reserveCsi();
            const r = if (ok)
                Csi.scan(rest, self.csi_params.unusedCapacitySlice(), self.csi_subs.unusedCapacitySlice())
            else
                Csi.scan(rest, &self.csi_spare.params, &self.csi_spare.subs);
            if (r.len == 0) {
                // Garbage longer than any real sequence is dropped.
                return .{ .held = if (rest.len <= max_hold) @intCast(rest.len) else 0 };
            }
            if (ok) self.recordCsi(r.seq);
            st.csiRun(start + i.*, r.len, r.seq);
            i.* += r.len;
            return null;
        }
        const seq = seqExtent(rest);
        if (!seq.complete) {
            if (seq.string) {
                return .{ .stream = .{ .kind = seq.kind, .off = start + i.*, .len = @intCast(rest.len) } };
            }
            return .{ .held = if (rest.len <= max_hold) @intCast(rest.len) else 0 };
        }
        st.classify(.{ .kind = seq.kind, .off = start + i.*, .len = seq.len }, rest[0..seq.len]);
        i.* += seq.len;
        return null;
    }

    /// The k-th CSI run's parse (valid while `csi_ok`, during the feed).
    pub inline fn csiAt(self: *const Preparser, k: usize) Csi.Seq {
        const h = self.csis.items[k];
        return .{
            .private = h.private,
            .final = h.final,
            .params = self.csi_params.items[h.params..][0..h.n],
            .subs = self.csi_subs.items[h.subs..][0..h.n_subs],
        };
    }

    /// Room for one more parsed CSI (`csiAt`); false (and `csi_ok`
    /// cleared: the VT parses the bytes itself) when it cannot grow.
    inline fn reserveCsi(self: *Preparser) bool {
        if (self.csi_ok and self.csis.items.len < self.csis.capacity and
            self.csi_params.capacity - self.csi_params.items.len >= Csi.max_params and
            self.csi_subs.capacity - self.csi_subs.items.len >= Csi.max_subs) return true;
        return self.growCsi();
    }

    noinline fn growCsi(self: *Preparser) bool {
        if (!self.csi_ok) return false;
        self.reserveBounded(CsiHead, &self.csis, 1, max_csis) catch return self.csiFailed();
        self.reserveBounded(Csi.Param, &self.csi_params, Csi.max_params, max_csi_params) catch return self.csiFailed();
        self.reserveBounded(u32, &self.csi_subs, Csi.max_subs, max_csi_subs) catch return self.csiFailed();
        return true;
    }

    /// Reuse a small, cache-sized workset independently of ring/input size.
    /// Precise growth keeps even allocator capacity within the hard limit.
    fn reserveBounded(self: *Preparser, comptime T: type, list: *std.ArrayListUnmanaged(T), extra: usize, limit: usize) !void {
        const need = list.items.len + extra;
        assert(need <= limit);
        if (need <= list.capacity) return;
        try list.ensureTotalCapacityPrecise(self.allocator, @min(limit, @max(need, @max(64, list.capacity * 2))));
    }

    pub fn metadataCapacityBytes(self: *const Preparser) usize {
        return self.runs.capacity * @sizeOf(Run) + self.csis.capacity * @sizeOf(CsiHead) +
            self.csi_params.capacity * @sizeOf(Csi.Param) + self.csi_subs.capacity * @sizeOf(u32);
    }

    pub const max_metadata_bytes = max_runs * @sizeOf(Run) + max_csis * @sizeOf(CsiHead) +
        max_csi_params * @sizeOf(Csi.Param) + max_csi_subs * @sizeOf(u32);

    fn csiFailed(self: *Preparser) bool {
        self.csi_ok = false;
        return false;
    }

    /// `q` was parsed into the unused capacity (`reserveCsi`): keep it.
    inline fn recordCsi(self: *Preparser, q: Csi.Seq) void {
        const p0 = self.csi_params.items.len;
        const s0 = self.csi_subs.items.len;
        self.csi_params.items.len += q.params.len;
        self.csi_subs.items.len += q.subs.len;
        self.csis.appendAssumeCapacity(.{
            .private = q.private,
            .final = q.final,
            .params = @intCast(p0),
            .subs = @intCast(s0),
            .n = @intCast(q.params.len),
            .n_subs = @intCast(q.subs.len),
        });
    }
};

/// Pass 1 state: which screen and scroll region each event lands in.
const Scan = struct {
    parser: *Preparser,
    rows: u16,
    screen: u1,
    full: [2]bool,
    /// The previous event was CUP to home: ED 0 now clears the screen.
    home: bool = false,
    /// DECOM is known to be off (CUP home is the screen's top-left).
    origin_off: bool = true,
    /// Reverse wraparound is on: BS can move up a line.
    rwrap: bool = false,
    track_visibility: bool = true,

    inline fn push(self: *Scan, run: Run) void {
        var r = run;
        r.flags.screen = self.screen;
        self.pushAt(r);
    }

    inline fn pushAt(self: *Scan, r: Run) void {
        self.home = false;
        // The scan loop reserves both possible runs before touching input.
        self.parser.runs.appendAssumeCapacity(r);
        if (self.track_visibility) {
            self.parser.screens |= @as(u2, 1) << r.flags.screen;
            switch (r.role) {
                .lf => if (r.flags.scrolls) {
                    self.parser.scroll_lfs[r.flags.screen] += 1;
                },
                .barrier => self.parser.barriers |= @as(u2, 1) << r.flags.screen,
                .barrier_alt => self.parser.barriers |= 0b10,
                .barrier_all => self.parser.barriers = 0b11,
                else => {},
            }
        }
    }

    /// Classify only when this batch requested visibility analysis.
    fn classify(self: *Scan, base: Run, bytes: []const u8) void {
        var run = base;
        run.role = .ordered;
        run.flags.screen = self.screen;
        if (self.track_visibility) {
            switch (run.kind) {
                .csi => unreachable,
                .esc => self.esc(&run, bytes),
                .osc => osc(&run, bytes),
                else => str(&run, bytes),
            }
        }
        self.pushAt(run);
    }

    inline fn csiRun(self: *Scan, off: u32, len: u32, seq: Csi.Seq) void {
        var run: Run = .{ .kind = .csi, .role = .ordered, .off = off, .len = len };
        run.flags.screen = self.screen;
        const home = if (self.track_visibility) self.csi(&run, seq) else false;
        self.pushAt(run);
        self.home = home;
    }

    /// Returns whether this is CUP to home. Classifies from the one parse
    /// the VT also applies (`Csi.scan` in `scan`), switching on the same packed
    /// privates and final as `csi.zig`'s `apply`, so the role always
    /// matches what the VT will do (a sequence it rejects is `ordered`).
    inline fn csi(self: *Scan, ev: *Run, q: Csi.Seq) bool {
        ev.role = .ordered;
        if (q.final == 0) return false;
        const p0 = q.value(0);
        switch (q.private) {
            0 => switch (q.final) {
                'm' => ev.role = .sgr,
                'H', 'f' => {
                    // Absolute: nothing earlier affects the cursor.
                    ev.role = .motion;
                    ev.flags.moves = true;
                    return p0 <= 1 and q.value(1) <= 1;
                },
                'A', 'F', 'd', 'L', 'M', 'S', 'T' => ev.role = .motion,
                'B', 'C', 'D', 'E', 'G', '`', 'a', 'e', 'K', 'X', 'P', '@', 'b', 'I', 'Z' => ev.role = .content,
                'J' => ev.role = if (p0 == 2 or (p0 == 0 and self.home and self.origin_off)) .barrier else .content,
                'r' => {
                    ev.role = .state;
                    // As `VtState.decstbm`: an invalid region is ignored
                    // (the cursor does not move either).
                    const top: u32 = if (sat16(p0) == 0) 1 else sat16(p0);
                    const bot: u32 = if (sat16(q.value(1)) == 0) self.rows else sat16(q.value(1));
                    if (top <= bot and bot <= self.rows) {
                        ev.flags.moves = true;
                        self.full[self.screen] = top == 1 and bot == self.rows;
                    }
                },
                'u' => {
                    ev.flags.moves = true;
                    self.origin_off = false;
                },
                'h', 'l' => if (q.params.len <= 1) {
                    ev.role = .state;
                },
                'c', 'n', 'x' => ev.role = .query,
                't' => switch (p0) {
                    14, 15, 16, 18, 19, 20, 21 => ev.role = .query,
                    8 => ev.flags.moves = true,
                    else => {},
                },
                else => {},
            },
            ' ' => if (q.final == 'q') {
                ev.role = .state;
            },
            '$' => ev.role = switch (q.final) {
                'p' => .query,
                'x', 'z', 'r', 't', 'v', '{' => .content,
                else => .ordered,
            },
            '!' => {
                ev.flags.moves = true;
                if (q.final == 'p') {
                    // As `VtState.softReset`.
                    self.origin_off = true;
                    self.rwrap = true;
                    self.full[self.screen] = true;
                }
            },
            // `?` with `$`: DECRQM.
            0x243F => if (q.final == 'p') {
                ev.role = .query;
            },
            '?' => switch (q.final) {
                'h', 'l' => self.decset(ev, q),
                'n', 'u', 'S', 'm' => ev.role = .query,
                'J', 'K' => ev.role = .content,
                // XTRESTORE can switch screens, home the cursor or change
                // DECOM: this drain makes no cut.
                'r' => self.parser.blind = true,
                else => {},
            },
            '>' => switch (q.final) {
                'c', 'q' => ev.role = .query,
                'm' => ev.role = .state,
                else => {},
            },
            '=' => if (q.final == 'c') {
                ev.role = .query;
            },
            else => {},
        }
        return false;
    }

    /// DECSET/DECRST: alt-screen switches move later runs to the other
    /// screen; entering 1049 from the primary screen clears the alt screen
    /// (47 and 1047 keep it, leaving never clears).
    fn decset(self: *Scan, ev: *Run, q: Csi.Seq) void {
        const set = q.final == 'h';
        var clears = false;
        var switched = false;
        // Parameters apply in order: `?47;1049h` from the primary screen
        // switches with 47 and 1049 then finds the alt screen active.
        var screen = self.screen;
        for (q.params) |prm| switch (prm.value) {
            1049, 1047, 47 => {
                const n = prm.value;
                if (n == 1049 and set and screen == 0) clears = true;
                if (n == 1049 and !set) self.origin_off = false;
                screen = @intFromBool(set);
                switched = true;
                // Leaving may restore the primary cursor anywhere.
                ev.flags.resets = true;
            },
            1048 => {
                if (!set) {
                    ev.flags.resets = true;
                    self.origin_off = false;
                }
            },
            6 => {
                self.origin_off = !set;
                // DECOM homes the cursor.
                ev.flags.moves = true;
            },
            45 => self.rwrap = set,
            else => {},
        };
        if (switched) {
            ev.role = if (clears) .barrier_alt else .ordered;
            self.screen = screen;
        } else {
            ev.role = .state;
        }
    }

    fn esc(self: *Scan, ev: *Run, bytes: []const u8) void {
        const final = bytes[bytes.len - 1];
        if (bytes.len == 2) {
            switch (final) {
                '8' => {
                    ev.role = .ordered;
                    ev.flags.moves = true;
                    self.origin_off = false;
                },
                '7' => ev.role = .ordered,
                'D', 'E' => {
                    ev.role = .lf;
                    ev.flags.scrolls = self.full[self.screen];
                },
                'M' => ev.role = .motion,
                'c' => {
                    ev.role = .barrier_all;
                    self.screen = 0;
                    self.full = .{ true, true };
                    self.origin_off = true;
                    self.rwrap = true;
                },
                '=', '>' => {
                    ev.role = .state;
                },
                'N', 'O', '\\' => ev.role = .content,
                else => ev.role = .ordered,
            }
            return;
        }
        ev.role = switch (bytes[1]) {
            '(', ')', '*', '+' => .state,
            '#' => if (final == '8') blk: {
                // DECALN homes the cursor.
                ev.flags.moves = true;
                break :blk .content;
            } else .ordered,
            else => .ordered,
        };
    }

    fn osc(ev: *Run, bytes: []const u8) void {
        ev.role = .ordered;
        const body = stringBody(bytes, 2);
        var i: usize = 0;
        var num: u32 = 0;
        while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) num = num *% 10 +% (body[i] - '0');
        if (i == 0) return;
        const arg = if (i < body.len and body[i] == ';') body[i + 1 ..] else body[i..];
        switch (num) {
            0, 1, 2 => ev.role = .state,
            4 => ev.role = if (std.mem.endsWith(u8, arg, ";?")) .query else .state,
            7, 10, 11, 12, 17, 19, 22, 176 => ev.role = if (std.mem.eql(u8, arg, "?")) .query else .state,
            52 => if (std.mem.endsWith(u8, arg, ";?")) {
                ev.role = .query;
            },
            133 => ev.role = .content,
            else => {},
        }
    }

    /// DCS, APC, PM, SOS.
    fn str(ev: *Run, bytes: []const u8) void {
        ev.role = .ordered;
        if (bytes.len < 2) return;
        switch (bytes[1]) {
            '_' => if (bytes.len > 2 and bytes[2] == 'G') {
                ev.role = .image;
            } else {
                ev.role = .content;
            },
            '^', 'X' => ev.role = .content,
            'P' => {
                const body = stringBody(bytes, 2);
                var i: usize = 0;
                if (i < body.len and body[i] >= '<' and body[i] <= '?') {
                    // DCS = 1 s / = 2 s: synchronized update.
                    if (std.mem.startsWith(u8, body, "=1s") or std.mem.startsWith(u8, body, "=2s")) {
                        ev.role = .state;
                    }
                    return;
                }
                while (i < body.len and ((body[i] >= '0' and body[i] <= '9') or body[i] == ';' or body[i] == ':')) i += 1;
                if (i >= body.len) return;
                if (body[i] == 'q') {
                    ev.role = .image;
                } else if (i + 1 < body.len and body[i + 1] == 'q' and (body[i] == '$' or body[i] == '+')) {
                    ev.role = .query;
                }
            },
            else => {},
        }
    }
};

fn sat16(v: u32) u32 {
    return @min(v, 65535);
}

/// String body without the introducer and terminator.
fn stringBody(bytes: []const u8, intro: usize) []const u8 {
    var end = bytes.len;
    if (end > intro and bytes[end - 1] == 0x07) {
        end -= 1;
    } else if (end >= intro + 2 and bytes[end - 2] == 0x1b and bytes[end - 1] == '\\') {
        end -= 2;
    }
    return if (end > intro) bytes[intro..end] else &.{};
}

const Extent = struct {
    len: u32,
    kind: Run.Kind,
    complete: bool,
    /// OSC/DCS/APC/PM/SOS: may be streamed.
    string: bool = false,
};

/// Length and kind of the escape sequence at `rest[0] == ESC` (not a CSI:
/// `escape` finds and parses those with `Csi.scan`).
fn seqExtent(rest: []const u8) Extent {
    const len: u32 = @intCast(rest.len);
    if (len < 2) return .{ .len = len, .kind = .esc, .complete = false };
    assert(rest[1] != '[');
    switch (rest[1]) {
        ']', 'P', '_', '^', 'X' => {
            const kind: Run.Kind = if (rest[1] == ']') .osc else .str;
            const at = stringEnd(rest, 2) orelse return .{ .len = len, .kind = kind, .complete = false, .string = true };
            return .{ .len = @intCast(at), .kind = kind, .complete = true, .string = true };
        },
        else => {
            var i: u32 = 1;
            while (i < len and rest[i] >= 0x20 and rest[i] <= 0x2F) i += 1;
            if (i >= len) return .{ .len = len, .kind = .esc, .complete = false };
            return .{ .len = i + 1, .kind = .esc, .complete = true };
        },
    }
}

/// End (exclusive) of a BEL- or ST-terminated string starting at `from`.
pub fn stringEnd(slice: []const u8, from: usize) ?usize {
    var idx: usize = from;
    while (idx < slice.len) {
        idx += SIMD.skipEqualEither(slice[idx..], 0x07, 0x1B);
        if (idx >= slice.len) return null;
        if (slice[idx] == 0x07) return idx + 1;
        if (idx + 1 < slice.len and slice[idx + 1] == '\\') return idx + 2;
        idx += 1;
    }
    return null;
}

/// Bytes of an incomplete UTF-8 sequence at the end of `bytes`.
fn utf8Tail(bytes: []const u8) u32 {
    const n = bytes.len;
    var back: usize = 1;
    while (back <= @min(n, 4)) : (back += 1) {
        const b = bytes[n - back];
        if (b & 0xC0 == 0x80) continue;
        if (b < 0xC0) return 0;
        const need = std.unicode.utf8ByteSequenceLength(b) catch return 0;
        return if (back < need) @intCast(back) else 0;
    }
    return 0;
}

test "isSpanObsolete is lazy cached and never prunes SGR" {
    var parser = try Preparser.init(std.testing.allocator);
    defer parser.deinit();
    const bytes = "a-long-ASCII-run\x1b[31mb\x1b[32mc\x1b[33md\x1b[34me\x1b[35mf\x1b[36mg\x1b[37mh\x1b[0mi\x1b[2JX";
    _ = parser.prepare(bytes, 0, .{ .rows = 4, .alt = false }, false, null);
    try std.testing.expect(!parser.visibility_ready);
    try std.testing.expect(!parser.isSpanObsolete(1)); // SGR needs no visibility proof.
    try std.testing.expect(!parser.visibility_ready);
    try std.testing.expectEqual(@as(usize, 9), parser.csis.items.len);
    var text: usize = 0;
    for (parser.runs.items, 0..) |run, i| {
        try std.testing.expect(!run.flags.ghost); // Framing did not consume or mark text.
        if (run.kind == .text) {
            try std.testing.expectEqual(text < 9, parser.isSpanObsolete(i));
            text += 1;
        } else {
            try std.testing.expect(!parser.isSpanObsolete(i));
        }
    }
    try std.testing.expect(parser.visibility_ready);
    const cut = parser.cut;
    for (0..100) |_| try std.testing.expect(parser.isSpanObsolete(0));
    try std.testing.expectEqualSlices(u32, &cut, &parser.cut);
    try std.testing.expectEqual(@as(u8, 'J'), parser.csiAt(8).final);
}

test "exact mode bypasses obsolescence and a new batch resets its cache" {
    var parser = try Preparser.init(std.testing.allocator);
    defer parser.deinit();
    const view: View = .{ .rows = 4, .alt = false };
    _ = parser.prepare("old\x1b[2Jnew", 0, view, true, null);
    parser.runs.items[0].flags.ghost = true; // Exact mode must override old tags too.
    for (parser.runs.items, 0..) |_, i| try std.testing.expect(!parser.isSpanObsolete(i));
    try std.testing.expect(!parser.visibility_ready);
    _ = parser.prepare("old\x1b[2Jnew", 0, view, false, null);
    try std.testing.expect(parser.isSpanObsolete(0));
    try std.testing.expect(parser.visibility_ready);
    _ = parser.prepare("fresh", 0, view, false, null);
    try std.testing.expect(!parser.visibility_ready);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0 }, &parser.cut);
    try std.testing.expect(!parser.isSpanObsolete(0));
}

test "size and SGR pressure never prove visible text obsolete" {
    var parser = try Preparser.init(std.testing.allocator);
    defer parser.deinit();
    _ = parser.prepare("A\x1b[31mB\x1b[32mC", 0, .{ .rows = 4, .alt = false }, false, null);
    for (parser.runs.items, 0..) |_, i| try std.testing.expect(!parser.isSpanObsolete(i));
}

test "obsolete spans distinguish screens and keep XTRESTORE conservative" {
    var parser = try Preparser.init(std.testing.allocator);
    defer parser.deinit();
    const view: View = .{ .rows = 4, .alt = false };
    _ = parser.prepare("A\x1b[?1049hB", 0, view, false, null);
    try std.testing.expect(!parser.isSpanObsolete(0));
    try std.testing.expectEqual(@as(u32, 0), parser.cut[0]);
    try std.testing.expectEqual(@as(u32, 1), parser.cut[1]);
    _ = parser.prepare("A\x1b[?1049hB\x1bcC", 0, view, false, null);
    try std.testing.expect(parser.isSpanObsolete(0));
    try std.testing.expect(parser.isSpanObsolete(2));
    try std.testing.expect(!parser.isSpanObsolete(4));
    _ = parser.prepare("A\x1b[2JB\x1b[?1r", 0, view, false, null);
    try std.testing.expect(parser.blind);
    try std.testing.expect(!parser.isSpanObsolete(0));
    try std.testing.expectEqualSlices(u32, &.{ 0, 0 }, &parser.cut);
}

test "framing preserves source offsets and incomplete tails" {
    var parser = try Preparser.init(std.testing.allocator);
    defer parser.deinit();
    const result = parser.prepare("abc\x1b[31mX\xc3", 100, .{ .rows = 4, .alt = false }, true, null);
    try std.testing.expectEqual(@as(u32, 1), result.held);
    try std.testing.expect(result.stream == null);
    try std.testing.expectEqual(@as(usize, 3), parser.runs.items.len);
    try std.testing.expectEqual(@as(u32, 100), parser.runs.items[0].off);
    try std.testing.expectEqual(@as(u9, 3), parser.runs.items[0].flags.plain);
    try std.testing.expectEqual(@as(u32, 103), parser.runs.items[1].off);
    try std.testing.expectEqual(@as(u32, 31), parser.csiAt(0).value(0));
    try std.testing.expectEqual(@as(u32, 108), parser.runs.items[2].off);
    const next = parser.prepare("\x1b[2;", 7, .{ .rows = 4, .alt = false }, true, null);
    try std.testing.expectEqual(@as(u32, 4), next.held);
    try std.testing.expectEqual(@as(usize, 0), parser.runs.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.csis.items.len);
}

test "unterminated strings request owner stream storage" {
    var parser = try Preparser.init(std.testing.allocator);
    defer parser.deinit();
    const bytes = "text\x1b]0;unfinished";
    const result = parser.prepare(bytes, 50, .{ .rows = 4, .alt = false }, false, null);
    try std.testing.expectEqual(@as(u32, 0), result.held);
    try std.testing.expectEqual(Run.Kind.osc, result.stream.?.kind);
    try std.testing.expectEqual(@as(u32, 54), result.stream.?.off);
    try std.testing.expectEqual(@as(u32, bytes.len - 4), result.stream.?.len);
    try std.testing.expectEqual(@as(usize, 1), parser.runs.items.len);
}

test "completed stream precedes ring spans without taking ownership" {
    var parser = try Preparser.init(std.testing.allocator);
    defer parser.deinit();
    const bytes = "\x1b_Ga=q,i=1;AAAA\x1b\\";
    _ = parser.prepare("\x1b[32mX", 20, .{ .rows = 4, .alt = false }, true, .{
        .run = .{ .kind = .str, .flags = .{ .stream = true }, .off = 9, .len = bytes.len },
        .bytes = bytes,
    });
    try std.testing.expectEqual(@as(usize, 3), parser.runs.items.len);
    try std.testing.expect(parser.runs.items[0].flags.stream);
    try std.testing.expectEqual(@as(u32, 9), parser.runs.items[0].off);
    try std.testing.expectEqual(@as(u32, 32), parser.csiAt(0).value(0));
}

test "CSI cache allocation failure still frames all spans" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var parser = try Preparser.init(failing.allocator());
    defer parser.deinit();
    failing.fail_index = failing.alloc_index;
    _ = parser.prepare("\x1b[2JX", 0, .{ .rows = 4, .alt = false }, false, null);
    try std.testing.expect(!parser.csi_ok);
    try std.testing.expectEqual(@as(usize, 2), parser.runs.items.len);
    try std.testing.expectEqual(Role.barrier, parser.runs.items[0].role);
}

test "metadata is bounded and reused without allocation after warmup" {
    const gpa = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(gpa, .{});
    var parser = try Preparser.init(failing.allocator());
    defer parser.deinit();
    // Exercise the run, CSI-head, parameter and subparameter limits separately.
    for ([_][]const u8{ "\n", "\x1b[m", "\x1b[38;2;1;2;3;48;2;4;5;6mX", "\x1b[38:2::1:2:3;48:2::4:5:6mX" }) |pattern| {
        const input = try gpa.alloc(u8, pattern.len * 20000);
        defer gpa.free(input);
        for (0..20000) |i| @memcpy(input[i * pattern.len ..][0..pattern.len], pattern);
        failing.fail_index = std.math.maxInt(usize);
        for (0..2) |pass| {
            const allocations = failing.alloc_index;
            if (pass == 1) failing.fail_index = allocations;
            var off: usize = 0;
            var batches: usize = 0;
            while (off < input.len) {
                const result = parser.prepare(input[off..], @intCast(off), .{ .rows = 4, .alt = false }, true, null);
                try std.testing.expect(parser.csi_ok);
                try std.testing.expect(result.stream == null);
                try std.testing.expect(parser.runs.capacity <= max_runs);
                try std.testing.expect(parser.csis.capacity <= max_csis);
                try std.testing.expect(parser.csi_params.capacity <= max_csi_params);
                try std.testing.expect(parser.csi_subs.capacity <= max_csi_subs);
                try std.testing.expect(parser.metadataCapacityBytes() <= Preparser.max_metadata_bytes);
                var covered: usize = 0;
                for (parser.runs.items) |run| {
                    try std.testing.expectEqual(off + covered, run.off);
                    covered += run.len;
                }
                try std.testing.expect(covered > 0);
                try std.testing.expectEqual(input.len - off - result.held, covered);
                if (result.held != 0) try std.testing.expect(result.retry);
                off += covered;
                batches += 1;
            }
            try std.testing.expect(batches > 1);
            if (pass == 1) try std.testing.expectEqual(allocations, failing.alloc_index);
        }
    }
}
