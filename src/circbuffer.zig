//! Mirrored circular buffer for dealing with firehose PTY input.
//!
//! The ring is never overwritten before it is consumed.
//! When it fills (or the frame deadline passes) it is drained: the
//! bytes are tagged into runs and handed to the terminal through a `Sink`.
//!
//! Text that can no longer reach the screen is fed without painting. That
//! is decided per screen by a cutoff event: content before the last full
//! clear (ED 2, ED 0 from home, RIS, entering 1049 for the alt screen) or
//! before `2 * rows - 1` scrolling line feeds with no upward motion after
//! them is dead. Every escape sequence is still parsed, in order, so the
//! screen, cursor, modes, replies and images equal a full parse.
//!
//! Strings that are not terminated when the ring drains (OSC, DCS, APC)
//! move into a separate spill buffer that grows as needed (up to
//! `max_spill`) and is freed when idle, so payloads larger than the ring
//! arrive whole. Only the bytes already in the ring are copied there; while
//! the string is open `readSource` reads straight into the spill buffer's
//! spare capacity (searching just the new bytes for the terminator and
//! putting whatever follows it back into the ring), so a large payload is
//! written once, by read(2). The finished string is a run with
//! `Flags.spill`; a consumer that keeps it (a kitty image) may take the
//! buffer itself (`takeSpill`) instead of copying out of it.
//!
//! Keeping everything here guarantees that runs indeed point to the
//! correct buffer. Runs live in dynamic arrays that only grow.

const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const posix = std.posix;

const SIMD = @import("simd.zig");

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
        /// Bytes live in the spill buffer instead of the ring.
        spill: bool = false,
        /// Dead text or LF: the cursor moves as if it printed, no cell is
        /// written and an LF at the bottom does not scroll.
        ghost: bool = false,
        // The rest is drain bookkeeping; the VT ignores it.
        screen: u1 = 0,
        /// LF inside a full-screen scroll region.
        scrolls: bool = false,
        /// Moves the cursor up or to an absolute position.
        moves: bool = false,
        superseded: bool = false,
        /// A screen switch or cursor restore: the LF count restarts on
        /// both screens.
        resets: bool = false,
        _: u9 = 0,
    };

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
    /// SGR: always parsed when live; in a dead region only the ones that a
    /// later full reset does not make irrelevant (see `markPen`).
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

/// Receives the runs of a drain, in byte order. `spill` backs runs with
/// `Run.Flags.spill` set; `owner` is the buffer they come from, for
/// `takeSpill` (valid only during the call).
pub const Sink = struct {
    ctx: *anyopaque,
    feed: *const fn (ctx: *anyopaque, runs: []const Run, spill: []const u8, owner: *CircBuffer) void,
    view: *const fn (ctx: *anyopaque) View,
};

/// Unterminated CSI/ESC/UTF-8 longer than this is dropped instead of held.
const max_hold: u32 = 4096;
/// Default spill cap (as kitty's largest image); a longer string is
/// discarded through its terminator.
pub const default_max_spill: usize = 320 * 1024 * 1024;
/// Spill capacity kept between strings; larger buffers are freed.
const spill_keep: usize = 1024 * 1024;

const none: u32 = std.math.maxInt(u32);


/// Events that decide which SGRs matter: SGRs (`reset`: a full reset),
/// RIS, and runs that read the pen (DECSC, SCOSC, XTPUSHSGR, queries, DCS,
/// alt-screen switches, screen clears).
const PenKind = enum(u8) { sgr, reset, ris, reader };
const PenRef = struct { run: u32, kind: PenKind };

const SpillState = struct {
    kind: Run.Kind,
    /// Where the open string starts in `spill`.
    base: usize,
    /// The last byte appended was ESC: `\` completes ST.
    esc: bool = false,
    discard: bool = false,
    /// `readSource` read the terminator straight into `spill`: the string is
    /// complete and the next drain emits it as a run, before the ring.
    closed: bool = false,
};

pub const CircBuffer = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    capacity: usize,
    mapped: bool,
    head: u64 = 0,
    tail: u64 = 0,
    /// `head` when an incomplete ESC/CSI/UTF-8 run was parked at the end.
    /// `pending` stays false until more bytes arrive so we do not spin.
    hold_at_head: u64 = 0,
    /// A drain fed runs since the flag was last cleared.
    fed: bool = false,
    /// Feed everything, dead or not (reference parses and debugging).
    exact: bool = false,
    runs: std.ArrayListUnmanaged(Run) = .empty,
    pens: std.ArrayListUnmanaged(PenRef) = .empty,
    spill: std.ArrayListUnmanaged(u8) = .empty,
    max_spill: usize = default_max_spill,
    open: ?SpillState = null,
    /// Per screen: runs before this index are dead (pass 2).
    cut: [2]u32 = .{ 0, 0 },
    /// Pass 1 saw something whose effect it cannot follow (XTRESTORE):
    /// nothing in this drain is dead.
    blind: bool = false,

    /// Create circular buffer
    pub fn create(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!CircBuffer {
        assert(capacity > 0);
        assert(std.math.isPowerOfTwo(capacity));

        var runs: std.ArrayListUnmanaged(Run) = .empty;
        try runs.ensureTotalCapacity(allocator, 1024);
        errdefer runs.deinit(allocator);

        if (mapMirror(capacity)) |storage| {
            return .{
                .allocator = allocator,
                .storage = storage,
                .capacity = capacity,
                .mapped = true,
                .runs = runs,
            };
        }

        const storage = try allocator.alloc(u8, capacity * 2);
        return .{
            .allocator = allocator,
            .storage = storage,
            .capacity = capacity,
            .mapped = false,
            .runs = runs,
        };
    }

    /// Destroy circular buffer.
    pub fn destroy(self: *CircBuffer) void {
        if (self.mapped) {
            switch (builtin.os.tag) {
                .linux => posix.munmap(@alignCast(self.storage)),
                else => unreachable,
            }
        } else {
            self.allocator.free(self.storage);
        }
        self.runs.deinit(self.allocator);
        self.pens.deinit(self.allocator);
        self.spill.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn pending(self: *const CircBuffer) bool {
        if (self.open) |sp| if (sp.closed) return true;
        if (self.head == self.tail) return false;
        if (self.hold_at_head != 0 and self.head == self.hold_at_head) return false;
        return true;
    }

    /// The circular buffer read directly from the PTY using
    /// it's very particular logic.
    ///
    /// 1. Bytes are never overwritten before they are consumed. When less
    /// than a quarter of the ring is free, it is drained into `sink` (see
    /// `drain`): firehose output is truncated there, by dropping what can
    /// no longer reach the screen, instead of by overwriting. Without a
    /// sink reading stops when the ring is full.
    ///
    /// 2. So as to not completely freeze the program, we will
    /// return on EAGAIN IF AND ONLY IF 1/hz has passed. By default
    /// hz should be 30.
    pub const Pump = struct {
        fd: c_int,
        ctx: *anyopaque,
        tick: *const fn (*anyopaque) void,
    };

    pub fn readPTY(self: *CircBuffer, pty: posix.fd_t, hz: u32, sink: ?Sink) error{Hangup}!void {
        return self.readPTYPump(pty, hz, null, sink);
    }

    /// Same return rules as `readPTY`. `pump` is ticked when its fd wakes during the EAGAIN wait
    /// so window events are not frozen for 1/hz.
    pub fn readPTYPump(self: *CircBuffer, pty: posix.fd_t, hz: u32, pump: ?Pump, sink: ?Sink) error{Hangup}!void {
        return self.readSource(FdSource{ .fd = pty }, hz, pump, sink);
    }

    /// A nonblocking source retains the same firehose/EOF/EAGAIN contract on every OS.
    pub fn readSource(self: *CircBuffer, source: anytype, hz: u32, pump: ?Pump, sink: ?Sink) error{Hangup}!void {
        const rate: u32 = if (hz == 0) 30 else hz;
        const period_ns: i128 = @divTrunc(1_000_000_000, rate);
        const start_ns = nowNs();
        const mask = self.capacity - 1;

        while (true) {
            if (self.capacity - (self.head - self.tail) < self.capacity / 4) {
                const s = sink orelse return;
                self.drain(s);
            }
            // A string left open by the drain takes the read directly (the
            // ring is empty then).
            const direct = self.directDest();
            var off: usize = 0;
            var dest: []u8 = undefined;
            if (direct) |d| {
                dest = d;
            } else {
                const free: usize = @intCast(self.capacity - (self.head - self.tail));
                if (free == 0) return;
                off = @intCast(self.head & mask);
                dest = self.storage[off..][0..free];
            }
            const n = source.read(dest) catch |err| switch (err) {
                error.WouldBlock => {
                    const elapsed = nowNs() - start_ns;
                    if (elapsed >= period_ns) return;
                    // Never poll(0): a readable X fd plus 0ms timeout busy-loops.
                    const remaining_ns = period_ns - elapsed;
                    const timeout_ms: i32 = @intCast(@min(@max(@divTrunc(remaining_ns + 999_999, 1_000_000), 1), 1000));
                    if (pump) |p| {
                        const t0 = nowNs();
                        source.wait(p.fd, timeout_ms);
                        p.tick(p.ctx);
                        // Motion/XI floods keep the X fd readable so poll returns
                        // immediately. Sleep on the PTY only for the rest of the
                        // frame instead of spinning at 100% CPU.
                        if (nowNs() - t0 < 200_000) {
                            const elapsed2 = nowNs() - start_ns;
                            if (elapsed2 >= period_ns) return;
                            const rest = period_ns - elapsed2;
                            const rest_ms: i32 = @intCast(@min(@max(@divTrunc(rest + 999_999, 1_000_000), 1), 1000));
                            source.wait(null, rest_ms);
                        }
                    } else {
                        source.wait(null, timeout_ms);
                    }
                    continue;
                },
                else => return error.Hangup,
            };
            if (n == 0) return error.Hangup;
            if (direct != null) {
                self.spillRead(n);
                continue;
            }
            self.syncMirror(off, n);
            self.head += n;
        }
    }

    /// Spare capacity of the open string's spill buffer to read into, or null
    /// when reads go to the ring (no open string, one that is already
    /// complete or discarded, or unconsumed bytes in the ring).
    fn directDest(self: *CircBuffer) ?[]u8 {
        const sp = &(self.open orelse return null);
        if (sp.closed or sp.discard or self.head != self.tail) return null;
        const len = self.spill.items.len - sp.base;
        // One read more than fits is enough to know the string is over the cap;
        // never more than the ring holds, so the bytes after the terminator
        // always fit back into it. A read is also no larger than what the
        // string already holds (at least 4 KiB): the bytes after the
        // terminator are copied back, which must stay small next to the
        // string (a short string that merely straddles a drain).
        const room = self.max_spill -| len +| 2;
        const want = @min(@min(room, self.capacity), @max(len, 4096));
        if (self.spill.capacity - self.spill.items.len < want) {
            const grown = @min(@max(self.spill.items.len + want, self.spill.capacity *| 2), self.spill.items.len + room);
            self.spill.ensureTotalCapacityPrecise(self.allocator, grown) catch return null;
        }
        return self.spill.unusedCapacitySlice()[0..want];
    }

    /// `n` bytes were read into the spare capacity of `spill`: keep them up
    /// to the terminator (as `continueSpill` does for ring bytes) and return
    /// the rest to the ring.
    fn spillRead(self: *CircBuffer, n: usize) void {
        const sp = &self.open.?;
        const at = self.spill.items.len;
        const new = self.spill.unusedCapacitySlice()[0..n];
        const end: ?usize = if (sp.esc and new[0] == '\\') 1 else stEnd(new, 0);
        const take = end orelse n;
        sp.esc = end == null and new[n - 1] == 0x1B;
        if (at - sp.base + take > self.max_spill) {
            sp.discard = true;
            self.spill.shrinkRetainingCapacity(sp.base);
        } else {
            self.spill.items.len = at + take;
        }
        const e = end orelse return;
        if (sp.discard) self.open = null else sp.closed = true;
        // `new` is still intact past `take`: back into the (empty) ring.
        const rest = new[e..];
        if (rest.len == 0) return;
        const off: usize = @intCast(self.head & (self.capacity - 1));
        @memcpy(self.storage[off..][0..rest.len], rest);
        self.syncMirror(off, rest.len);
        self.head += rest.len;
    }

    /// Take the spill buffer itself, for the consumer of the run at
    /// `off..off + len` in it (during `Sink.feed`). Only a run that ends the
    /// buffer, longer than half a ring (smaller strings are cheaper to copy
    /// than to keep a buffer for), with no string open behind it. The
    /// caller owns the whole returned allocation, which holds the run at
    /// `off` (free it with the `allocator` given, which must be the one the
    /// ring uses), and no slice into the spill may be used afterwards.
    pub fn takeSpill(self: *CircBuffer, allocator: std.mem.Allocator, off: usize, len: usize) ?[]u8 {
        if (self.open != null or len < self.capacity / 2) return null;
        if (off + len != self.spill.items.len) return null;
        if (allocator.ptr != self.allocator.ptr or allocator.vtable != self.allocator.vtable) return null;
        var buf = self.spill.allocatedSlice();
        self.spill = .empty;
        // Give back growth slack when it is cheap (realloc in place).
        if (buf.len - (off + len) > buf.len / 8) {
            if (allocator.remap(buf, off + len)) |small| buf = small;
        }
        return buf;
    }

    fn syncMirror(self: *CircBuffer, off: usize, n: usize) void {
        if (self.mapped or n == 0) return;
        const cap = self.capacity;
        const a = self.storage;
        const first = @min(n, cap - off);
        if (first != 0) {
            @memcpy(a[off + cap ..][0..first], a[off..][0..first]);
        }
        const rest = n - first;
        if (rest != 0) {
            @memcpy(a[0..rest], a[cap..][0..rest]);
        }
    }

    /// Consume every unconsumed byte: tag, drop what is dead, feed `sink`.
    /// An incomplete trailing ESC/CSI/UTF-8 run stays in the ring; an
    /// unterminated string moves to the spill buffer.
    pub fn drain(self: *CircBuffer, sink: Sink) void {
        assert(self.tail <= self.head);
        if (!self.pending()) return;
        const view = sink.view(sink.ctx);
        const held = self.scan(view);
        self.mark(view.rows);
        self.compact();
        if (self.runs.items.len != 0) {
            self.fed = true;
            sink.feed(sink.ctx, self.runs.items, self.spill.items, self);
        }
        self.finishConsume(held);
        if (self.open == null) {
            if (self.spill.capacity > spill_keep) self.spill.clearAndFree(self.allocator) else self.spill.clearRetainingCapacity();
        } else {
            // Strings completed by this drain were fed; only the open one
            // stays, at the start of the buffer, before it grows by reads.
            self.compactSpill();
        }
    }

    fn finishConsume(self: *CircBuffer, held: u32) void {
        if (held == 0 or held > self.head - self.tail) {
            self.tail = self.head;
            self.hold_at_head = 0;
            return;
        }
        self.tail = self.head - held;
        self.hold_at_head = self.head;
    }

    /// Move the open string to the start of `spill`.
    fn compactSpill(self: *CircBuffer) void {
        const st = &(self.open orelse return);
        if (st.base == 0) return;
        const rest = self.spill.items[st.base..];
        @memmove(self.spill.items[0..rest.len], rest);
        self.spill.shrinkRetainingCapacity(rest.len);
        st.base = 0;
    }

    // ------------------------------------------------------------ pass 1

    /// Tag [tail, head) into runs. Returns the number of trailing bytes
    /// held in the ring for the next drain.
    fn scan(self: *CircBuffer, view: View) u32 {
        self.runs.clearRetainingCapacity();
        self.pens.clearRetainingCapacity();
        self.blind = false;
        var st = Scan{
            .cb = self,
            .rows = view.rows,
            .screen = @intFromBool(view.alt),
            .full = view.full_region,
            .origin_off = !view.origin,
            .rwrap = view.reverse_wrap,
        };
        const to_read: u32 = @intCast(self.head - self.tail);
        const start: u32 = @intCast(self.tail & (self.capacity - 1));
        const slice = self.storage[start..][0..to_read];

        var i: u32 = 0;
        if (self.open != null) {
            i = self.continueSpill(slice, &st);
            if (i >= to_read) return 0;
        }

        while (i < to_read) {
            const text_start = i;
            // Under reverse wraparound a BS can move up a line: it gets its
            // own run so the LF count restarts there.
            i += if (st.rwrap)
                SIMD.skipToAny(slice[i..], &.{ 0x08, 0x0A, 0x0B, 0x0C, 0x0E, 0x0F, 0x1B })
            else
                SIMD.skipToAny(slice[i..], &.{ 0x0A, 0x0B, 0x0C, 0x0E, 0x0F, 0x1B });
            if (i >= to_read) {
                // An incomplete UTF-8 sequence at the very end waits for more.
                const cut = utf8Tail(slice[text_start..i]);
                if (i - cut > text_start) st.push(.{ .kind = .text, .off = start + text_start, .len = i - cut - text_start });
                return cut;
            }
            if (i > text_start) st.push(.{ .kind = .text, .off = start + text_start, .len = i - text_start });
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
            const rest = slice[i..];
            const seq = seqExtent(rest);
            if (!seq.complete) {
                if (seq.string) {
                    self.openSpill(rest, seq.kind);
                    return 0;
                }
                if (rest.len <= max_hold) return @intCast(rest.len);
                // Garbage longer than any real sequence: drop it.
                break;
            }
            st.classify(.{ .kind = seq.kind, .off = start + i, .len = seq.len }, rest[0..seq.len]);
            i += seq.len;
        }
        return 0;
    }

    /// Append the open string's bytes up to its terminator. Returns how much
    /// of `slice` was consumed.
    fn continueSpill(self: *CircBuffer, slice: []const u8, st: *Scan) u32 {
        const sp = &self.open.?;
        if (sp.closed) {
            // Read directly into `spill`; the terminator is already in.
            self.finishSpill(st);
            return 0;
        }
        const end: ?usize = if (sp.esc and slice.len != 0 and slice[0] == '\\') 1 else stEnd(slice, 0);
        const take = end orelse slice.len;
        sp.esc = end == null and slice.len != 0 and slice[slice.len - 1] == 0x1B;
        self.appendSpill(slice[0..take]);
        if (end == null) return @intCast(slice.len);
        self.finishSpill(st);
        return @intCast(take);
    }

    /// The open string is complete: its run is the tag, pointing into `spill`.
    fn finishSpill(self: *CircBuffer, st: *Scan) void {
        const done = self.open.?;
        self.open = null;
        if (done.discard) return;
        const bytes = self.spill.items[done.base..];
        st.classify(.{ .kind = done.kind, .flags = .{ .spill = true }, .off = @intCast(done.base), .len = @intCast(bytes.len) }, bytes);
    }

    fn openSpill(self: *CircBuffer, bytes: []const u8, kind: Run.Kind) void {
        self.open = .{ .kind = kind, .base = self.spill.items.len };
        self.open.?.esc = bytes[bytes.len - 1] == 0x1B;
        self.appendSpill(bytes);
    }

    fn appendSpill(self: *CircBuffer, bytes: []const u8) void {
        const sp = &self.open.?;
        if (sp.discard) return;
        if (self.spill.items.len - sp.base + bytes.len > self.max_spill) {
            sp.discard = true;
            self.spill.shrinkRetainingCapacity(sp.base);
            return;
        }
        self.spill.appendSlice(self.allocator, bytes) catch {
            sp.discard = true;
            self.spill.shrinkRetainingCapacity(sp.base);
        };
    }

    // ------------------------------------------------------------ pass 2

    /// Cutoffs per screen, walking backward; then superseded state.
    fn mark(self: *CircBuffer, rows: u16) void {
        self.cut = .{ 0, 0 };
        if (self.exact or self.blind) return;
        // From any row, 2 * rows - 1 scrolling LFs with no upward or
        // absolute motion push every line on screen out of view.
        const need: u32 = 2 * @as(u32, rows) -| 1;
        var found = [2]bool{ false, false };
        var lfs = [2]u32{ 0, 0 };
        const runs = self.runs.items;
        var i: usize = runs.len;
        while (i > 0) {
            i -= 1;
            const r = runs[i];
            const s = r.flags.screen;
            const kills: u2 = switch (r.role) {
                .lf => blk: {
                    if (!r.flags.scrolls) {
                        lfs[s] = 0;
                    } else {
                        lfs[s] += 1;
                        if (lfs[s] >= need and !found[s]) {
                            self.cut[s] = @intCast(i);
                            found[s] = true;
                        }
                    }
                    break :blk 0;
                },
                .motion => blk: {
                    lfs[s] = 0;
                    break :blk 0;
                },
                .barrier => @as(u2, 1) << s,
                .barrier_alt => 0b10,
                .barrier_all => 0b11,
                else => 0,
            };
            if (kills != 0) for (0..2) |k| {
                if (kills & (@as(u2, 1) << @intCast(k)) != 0 and !found[k]) {
                    self.cut[k] = @intCast(i);
                    found[k] = true;
                }
            };
            if (r.flags.moves) lfs[s] = 0;
            if (r.flags.resets) lfs = .{ 0, 0 };
        }
        if (found[0] or found[1]) self.markPen();
    }

    /// Dead SGRs that a later dead full reset (or RIS) on their screen
    /// overrides, with no pen reader in between, are superseded.
    fn markPen(self: *CircBuffer) void {
        const runs = self.runs.items;
        var reset = [2]bool{ false, false };
        var k = self.pens.items.len;
        while (k > 0) {
            k -= 1;
            const ref = self.pens.items[k];
            const r = &runs[ref.run];
            const s = r.flags.screen;
            switch (ref.kind) {
                .reader => reset = .{ false, false },
                .ris => reset = .{ true, true },
                .sgr, .reset => {
                    if (ref.run >= self.cut[s]) continue;
                    r.flags.superseded = reset[s];
                    if (ref.kind == .reset) reset[s] = true;
                },
            }
        }
    }

    // ------------------------------------------------------------ pass 3

    /// Runs before the cut are dead: nothing they paint can be seen. Every
    /// run is still fed, so the cursor, modes, replies and palette end up
    /// exactly as if all bytes were parsed; only the paint is skipped (dead
    /// text moves the cursor without writing cells, dead images update
    /// everything but their placement), and dead SGRs a later dead reset
    /// overrides are dropped.
    fn compact(self: *CircBuffer) void {
        if (self.cut[0] == 0 and self.cut[1] == 0) return;
        const runs = self.runs.items;
        var w: usize = 0;
        for (runs, 0..) |r, idx| {
            const dead = idx < self.cut[r.flags.screen];
            var out = r;
            if (dead) switch (r.role) {
                .text, .lf => out.flags.ghost = true,
                .sgr => if (r.flags.superseded) continue,
                else => {},
            };
            runs[w] = out;
            w += 1;
        }
        self.runs.shrinkRetainingCapacity(w);
    }

    fn mapMirror(size: usize) ?[]u8 {
        if (builtin.os.tag != .linux) return null;
        if (size == 0 or size % std.heap.pageSize() != 0) return null;
        const fd = posix.memfd_create("zt-ring", 0) catch return null;
        defer _ = std.os.linux.close(fd);
        if (std.os.linux.errno(std.os.linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return null;
        const reserved = posix.mmap(
            null,
            size * 2,
            .{},
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return null;
        const half: [*]align(std.heap.page_size_min) u8 = @ptrCast(reserved.ptr);
        _ = posix.mmap(
            half,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED, .FIXED = true },
            fd,
            0,
        ) catch {
            posix.munmap(reserved);
            return null;
        };
        const rest: [*]align(std.heap.page_size_min) u8 = @alignCast(half + size);
        _ = posix.mmap(
            rest,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED, .FIXED = true },
            fd,
            0,
        ) catch {
            posix.munmap(reserved);
            return null;
        };
        return reserved;
    }
};

/// Pass 1 state: which screen and scroll region each event lands in.
const Scan = struct {
    cb: *CircBuffer,
    rows: u16,
    screen: u1,
    full: [2]bool,
    /// The previous event was CUP to home: ED 0 now clears the screen.
    home: bool = false,
    /// DECOM is known to be off (CUP home is the screen's top-left).
    origin_off: bool = true,
    /// Reverse wraparound is on: BS can move up a line.
    rwrap: bool = false,
    /// Pen event of the run being classified (null: derived from its role).
    pen: ?PenKind = null,

    inline fn push(self: *Scan, run: Run) void {
        var r = run;
        r.flags.screen = self.screen;
        self.pushAt(r);
    }

    inline fn pushAt(self: *Scan, r: Run) void {
        self.home = false;
        const runs = &self.cb.runs;
        if (runs.items.len == runs.capacity) {
            @branchHint(.cold);
            runs.ensureUnusedCapacity(self.cb.allocator, 1) catch return;
        }
        runs.appendAssumeCapacity(r);
    }

    /// Tag an escape sequence. Its screen is the one in effect before it
    /// (an alt-screen switch belongs to the screen it leaves).
    fn classify(self: *Scan, base: Run, bytes: []const u8) void {
        var r = base;
        r.role = .ordered;
        r.flags.screen = self.screen;
        self.pen = null;
        const at: u32 = @intCast(self.cb.runs.items.len);
        var home = false;
        switch (r.kind) {
            .csi => home = self.csi(&r, bytes),
            .esc => self.esc(&r, bytes),
            .osc => osc(&r, bytes),
            else => str(&r, bytes),
        }
        self.pushAt(r);
        self.home = home;
        const pen: ?PenKind = self.pen orelse switch (r.role) {
            .query, .barrier, .barrier_alt => .reader,
            .barrier_all => .ris,
            else => if (r.kind == .str) .reader else null,
        };
        if (pen) |kind| self.cb.pens.append(self.cb.allocator, .{ .run = at, .kind = kind }) catch {};
    }

    /// Returns whether this is CUP to home.
    fn csi(self: *Scan, ev: *Run, bytes: []const u8) bool {
        var q = CsiInfo.quick(bytes);
        // Most CSIs are decided by their final byte; parameters are parsed
        // only for the few finals that need them.
        switch (q.final) {
            'H', 'f', 'J', 'r', 'h', 'l', 't', 'm' => if (q.final != 'm' or q.prefix == '>') q.params(bytes),
            else => {},
        }
        switch (q.prefix) {
            0 => switch (q.inter) {
                0 => switch (q.final) {
                    'm' => {
                        ev.role = .sgr;
                        self.pen = if (resetsPen(bytes)) .reset else .sgr;
                    },
                    'H', 'f' => {
                        // Absolute: nothing earlier affects the cursor.
                        ev.role = .motion;
                        ev.flags.moves = true;
                        return q.p0 <= 1 and q.p1 <= 1;
                    },
                    'A', 'F', 'd', 'L', 'M', 'S', 'T' => ev.role = .motion,
                    'B', 'C', 'D', 'E', 'G', '`', 'a', 'e', 'K', 'X', 'P', '@', 'b', 'I', 'Z' => ev.role = .content,
                    'J' => ev.role = if (q.p0 == 2 or (q.p0 == 0 and self.home and self.origin_off)) .barrier else .content,
                    'r' => {
                        ev.role = .state;
                        // As `VtState.decstbm`: an invalid region is ignored
                        // (the cursor does not move either).
                        const top: u32 = if (q.p0 == 0) 1 else q.p0;
                        const bot: u32 = if (q.p1 == 0) self.rows else q.p1;
                        if (top <= bot and bot <= self.rows) {
                            ev.flags.moves = true;
                            self.full[self.screen] = top == 1 and bot == self.rows;
                        }
                    },
                    's' => {
                        ev.role = .ordered;
                        self.pen = .reader;
                    },
                    'u' => {
                        ev.role = .ordered;
                        ev.flags.moves = true;
                        self.origin_off = false;
                    },
                    'h', 'l' => if (q.n <= 1) {
                        ev.role = .state;
                    } else {
                        ev.role = .ordered;
                    },
                    'c', 'n', 'x' => ev.role = .query,
                    't' => switch (q.p0) {
                        14, 15, 16, 18, 19, 20, 21 => ev.role = .query,
                        8 => {
                            ev.role = .ordered;
                            ev.flags.moves = true;
                        },
                        else => ev.role = .ordered,
                    },
                    else => ev.role = .ordered,
                },
                ' ' => if (q.final == 'q') {
                    ev.role = .state;
                } else {
                    ev.role = .ordered;
                },
                '$' => ev.role = switch (q.final) {
                    'p' => .query,
                    'x', 'z', 'r', 't', 'v', '{' => .content,
                    else => .ordered,
                },
                '!' => {
                    ev.role = .ordered;
                    ev.flags.moves = true;
                    if (q.final == 'p') {
                        // As `VtState.softReset`.
                        self.origin_off = true;
                        self.rwrap = true;
                        self.full[self.screen] = true;
                    }
                },
                '#' => {
                    ev.role = .ordered;
                    if (q.final == '{' or q.final == 'p') self.pen = .reader;
                },
                else => ev.role = .ordered,
            },
            '?' => {
                if (q.inter == '$') {
                    ev.role = if (q.final == 'p') .query else .ordered;
                    return false;
                }
                switch (q.final) {
                    'h', 'l' => self.decset(ev, bytes, q),
                    'n', 'u', 'S', 'm' => ev.role = .query,
                    'J', 'K' => ev.role = .content,
                    'r' => {
                        // XTRESTORE can switch screens, home the cursor or
                        // change DECOM: this drain makes no cut.
                        ev.role = .ordered;
                        self.cb.blind = true;
                    },
                    else => ev.role = .ordered,
                }
            },
            '>' => switch (q.final) {
                'c', 'q' => ev.role = .query,
                'm' => {
                    ev.role = .state;
                },
                else => ev.role = .ordered,
            },
            '=' => ev.role = if (q.final == 'c') .query else .ordered,
            else => ev.role = .ordered,
        }
        return false;
    }

    /// DECSET/DECRST: alt-screen switches move later runs to the other
    /// screen; entering 1049 from the primary screen clears the alt screen
    /// (47 and 1047 keep it, leaving never clears).
    fn decset(self: *Scan, ev: *Run, bytes: []const u8, q: CsiInfo) void {
        const set = q.final == 'h';
        var clears = false;
        var switched = false;
        // Parameters apply in order: `?47;1049h` from the primary screen
        // switches with 47 and 1049 then finds the alt screen active.
        var screen = self.screen;
        var it = CsiInfo.paramIter(bytes);
        while (it.next()) |n| switch (n) {
            1049, 1047, 47 => {
                if (n == 1049 and set and screen == 0) clears = true;
                if (n == 1049 and !set) self.origin_off = false;
                screen = @intFromBool(set);
                switched = true;
                // Leaving may restore the primary cursor anywhere.
                ev.flags.resets = true;
                self.pen = .reader;
            },
            1048 => {
                self.pen = .reader;
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
                '7' => {
                    ev.role = .ordered;
                    self.pen = .reader;
                },
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

/// `CSI m` whose first parameter is 0 or empty: the pen is reset before
/// anything else applies (`CSI 0;1 m` resets, `CSI 38;0 m` and `CSI 0:1 m`
/// do not count).
fn resetsPen(bytes: []const u8) bool {
    var i: usize = 2;
    const end = bytes.len - 1;
    while (i < end and bytes[i] == '0') i += 1;
    return i == end or bytes[i] == ';';
}

/// Prefix, first parameters, last intermediate and final byte of a CSI.
const CsiInfo = struct {
    prefix: u8 = 0,
    inter: u8 = 0,
    final: u8,
    p0: u32 = 0,
    p1: u32 = 0,
    /// Number of `;`-separated parameters (0 when there are none).
    n: u32 = 0,

    /// Prefix, last intermediate and final byte without the parameters.
    fn quick(bytes: []const u8) CsiInfo {
        var q = CsiInfo{ .final = bytes[bytes.len - 1] };
        const end = bytes.len - 1;
        if (2 < end and bytes[2] >= '<' and bytes[2] <= '?') q.prefix = bytes[2];
        if (end > 2 and bytes[end - 1] >= 0x20 and bytes[end - 1] <= 0x2F) q.inter = bytes[end - 1];
        return q;
    }

    /// Fill `p0`, `p1` and `n`.
    fn params(q: *CsiInfo, bytes: []const u8) void {
        var i: usize = 2;
        const end = bytes.len - 1;
        if (q.prefix != 0) i += 1;
        var idx: u32 = 0;
        var any = false;
        while (i < end) : (i += 1) {
            const c = bytes[i];
            switch (c) {
                '0'...'9' => {
                    any = true;
                    const d = c - '0';
                    if (idx == 0) q.p0 = q.p0 *| 10 +| d else if (idx == 1) q.p1 = q.p1 *| 10 +| d;
                },
                ';' => {
                    any = true;
                    idx += 1;
                },
                else => {},
            }
        }
        q.n = if (any) idx + 1 else 0;
    }

    const Params = struct {
        bytes: []const u8,
        i: usize,
        fn next(self: *Params) ?u32 {
            const end = self.bytes.len - 1;
            if (self.i >= end) return null;
            var v: u32 = 0;
            var any = false;
            while (self.i < end) : (self.i += 1) {
                const c = self.bytes[self.i];
                if (c >= '0' and c <= '9') {
                    v = v *| 10 +| (c - '0');
                    any = true;
                } else if (c == ';') {
                    self.i += 1;
                    return v;
                } else if (any) {
                    break;
                }
            }
            self.i = end;
            return if (any) v else null;
        }
    };

    fn paramIter(bytes: []const u8) Params {
        var i: usize = 2;
        if (i < bytes.len and bytes[i] >= '<' and bytes[i] <= '?') i += 1;
        return .{ .bytes = bytes, .i = i };
    }
};

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
    /// OSC/DCS/APC/PM/SOS: may be spilled.
    string: bool = false,
};

/// Length and kind of the escape sequence at `rest[0] == ESC`.
fn seqExtent(rest: []const u8) Extent {
    const len: u32 = @intCast(rest.len);
    if (len < 2) return .{ .len = len, .kind = .esc, .complete = false };
    switch (rest[1]) {
        '[' => {
            if (len < 3) return .{ .len = len, .kind = .csi, .complete = false };
            const at = 2 + SIMD.skipInRange(rest[2..], 0x40, 0x7E);
            if (at >= len) return .{ .len = len, .kind = .csi, .complete = false };
            return .{ .len = at + 1, .kind = .csi, .complete = true };
        },
        ']', 'P', '_', '^', 'X' => {
            const kind: Run.Kind = if (rest[1] == ']') .osc else .str;
            const at = stEnd(rest, 2) orelse return .{ .len = len, .kind = kind, .complete = false, .string = true };
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
fn stEnd(slice: []const u8, from: usize) ?usize {
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

fn nowNs() i128 {
    return @intCast(std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds);
}

const FdSource = struct {
    fd: posix.fd_t,
    pub fn read(self: FdSource, dest: []u8) !usize {
        return posix.read(self.fd, dest);
    }
    pub fn wait(self: FdSource, event_fd: ?c_int, timeout_ms: c_int) void {
        if (event_fd) |fd| waitReadable2(self.fd, fd, timeout_ms) else waitReadable(self.fd, timeout_ms);
    }
};

fn waitReadable(fd: posix.fd_t, timeout_ms: i32) void {
    var fds = [_]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
    };
    _ = posix.poll(&fds, timeout_ms) catch {};
}

fn waitReadable2(a: posix.fd_t, b: posix.fd_t, timeout_ms: i32) void {
    var fds = [_]posix.pollfd{
        .{ .fd = a, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = b, .events = posix.POLL.IN, .revents = 0 },
    };
    _ = posix.poll(&fds, timeout_ms) catch {};
}


// ------------------------------------------------------------------ tests

/// Records the runs a drain feeds and the bytes it paints (ghost text is
/// fed but paints nothing).
const TestSink = struct {
    gpa: std.mem.Allocator,
    view_: View,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    runs: std.ArrayListUnmanaged(Run) = .empty,
    storage: []const u8,

    fn deinit(self: *TestSink) void {
        self.bytes.deinit(self.gpa);
        self.runs.deinit(self.gpa);
    }
    fn sink(self: *TestSink) Sink {
        return .{ .ctx = self, .feed = feed, .view = view };
    }
    fn feed(ctx: *anyopaque, runs: []const Run, spill: []const u8, owner: *CircBuffer) void {
        _ = owner;
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        for (runs) |r| {
            const src = if (r.flags.spill) spill else self.storage;
            if (!(r.flags.ghost and r.kind == .text)) self.bytes.appendSlice(self.gpa, src[r.off..][0..r.len]) catch unreachable;
            self.runs.append(self.gpa, r) catch unreachable;
        }
    }
    fn view(ctx: *anyopaque) View {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        return self.view_;
    }
};

fn append(buf: *CircBuffer, src: []const u8) void {
    const cap = buf.capacity;
    const off: usize = @intCast(buf.head & (cap - 1));
    assert(src.len <= cap - (buf.head - buf.tail));
    @memcpy(buf.storage[off..][0..src.len], src);
    buf.syncMirror(off, src.len);
    buf.head += src.len;
}

test "run stays small" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Run));
}

test "text that scrolls off is fed as ghost text" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, std.heap.pageSize());
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 3, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    // Four LFs could leave a line on a 3-row screen (from the top row they
    // scroll only twice); 2 * 3 - 1 = 5 scroll everything out.
    append(&buf, "a\r\nb\r\nc\r\nd\r\ne");
    buf.drain(ts.sink());
    try std.testing.expectEqualStrings("a\r\nb\r\nc\r\nd\r\ne", ts.bytes.items);
    ts.bytes.clearRetainingCapacity();
    ts.runs.clearRetainingCapacity();
    append(&buf, "a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng");
    buf.drain(ts.sink());
    // a and b only move the cursor; every LF is still fed.
    try std.testing.expectEqualStrings("\n\nc\r\nd\r\ne\r\nf\r\ng", ts.bytes.items);
    try std.testing.expect(ts.runs.items[0].flags.ghost);
    try std.testing.expect(!ts.runs.items[ts.runs.items.len - 1].flags.ghost);
    try std.testing.expect(!buf.pending());
}

fn drainAll(buf: *CircBuffer, ts: *TestSink, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const free: usize = @intCast(buf.capacity - (buf.head - buf.tail));
        const n = @min(free, bytes.len - off);
        append(buf, bytes[off..][0..n]);
        off += n;
        if (buf.capacity - (buf.head - buf.tail) < buf.capacity / 4) buf.drain(ts.sink());
    }
    buf.drain(ts.sink());
}

fn lines(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (0..n) |i| try out.print(gpa, "line {d}\r\n", .{i});
    return out.toOwnedSlice(gpa);
}

test "a dead region feeds every run but text" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, std.heap.pageSize());
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 2, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    append(&buf, "\x1b[?2004hA\r\n\x1b[cB\x1b[1mC\x1b[?2004l\x1b]2;one\x07\x1b]2;two\x07D\r\nE\r\nF\r\nG");
    buf.drain(ts.sink());
    const got = ts.bytes.items;
    // Text before the cut paints nothing; every escape is still parsed.
    try std.testing.expect(std.mem.indexOfScalar(u8, got, 'A') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, got, 'D') == null);
    for ([_][]const u8{ "\x1b[?2004h", "\x1b[c", "\x1b[1m", "\x1b[?2004l", "one", "two" }) |want| {
        try std.testing.expect(std.mem.indexOf(u8, got, want) != null);
    }
    try std.testing.expect(std.mem.endsWith(u8, got, "\nE\r\nF\r\nG"));
}

test "clear is a barrier; upward motion keeps earlier lines" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, std.heap.pageSize());
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 2, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    append(&buf, "old\r\nold\x1b[H\x1b[2Jnew");
    buf.drain(ts.sink());
    try std.testing.expectEqualStrings("\n\x1b[H\x1b[2Jnew", ts.bytes.items);

    ts.bytes.clearRetainingCapacity();
    append(&buf, "a\r\nb\r\nc\x1b[3Ad");
    buf.drain(ts.sink());
    try std.testing.expectEqualStrings("a\r\nb\r\nc\x1b[3Ad", ts.bytes.items);

    // ED 3 only clears the scrollback; under DECOM home is the region's top.
    for ([_][]const u8{ "keep\x1b[3J", "keep\x1b[2;3r\x1b[?6h\x1b[H\x1b[J\x1b[?6l" }) |in| {
        ts.bytes.clearRetainingCapacity();
        append(&buf, in);
        buf.drain(ts.sink());
        try std.testing.expectEqualStrings(in, ts.bytes.items);
    }
}

test "only entering 1049 from the primary screen clears the alt screen" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, std.heap.pageSize());
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 2, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    // Leaving keeps the alt screen; 47 and 1047 never clear it.
    for ([_][]const u8{ "prompt\x1b[?1049hTUI\x1b[?1049lback", "\x1b[?1049hA\x1b[?1049l\x1b[?47hB\x1b[?47l", "\x1b[?1047hA\x1b[?1047l\x1b[?1047hB\x1b[?1047l" }) |in| {
        ts.bytes.clearRetainingCapacity();
        append(&buf, in);
        buf.drain(ts.sink());
        try std.testing.expectEqualStrings(in, ts.bytes.items);
    }
    ts.bytes.clearRetainingCapacity();
    append(&buf, "\x1b[?1049hA\x1b[?1049l\x1b[?1049hB");
    buf.drain(ts.sink());
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?1049l\x1b[?1049hB", ts.bytes.items);
}

test "strings longer than the ring arrive whole through the spill buffer" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, std.heap.pageSize());
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    var osc: std.ArrayListUnmanaged(u8) = .empty;
    defer osc.deinit(gpa);
    try osc.appendSlice(gpa, "\x1b]52;c;");
    try osc.appendNTimes(gpa, 'Q', 5 * std.heap.pageSize());
    try osc.appendSlice(gpa, "\x1b\\after");
    drainAll(&buf, &ts, osc.items);
    try std.testing.expectEqualStrings(osc.items, ts.bytes.items);
    var spilled = false;
    for (ts.runs.items) |r| spilled = spilled or r.flags.spill;
    try std.testing.expect(spilled);
    // Idle spill memory is released.
    try std.testing.expect(buf.open == null);
}

/// A nonblocking source that hands out `data` in odd-sized reads, never
/// crossing a `cuts` offset (reads end exactly there), and counts the reads
/// that landed outside the ring.
const PieceSource = struct {
    data: []const u8,
    cuts: []const usize = &.{},
    ring: []const u8,
    pos: usize = 0,
    step: usize = 0,
    direct: usize = 0,

    pub fn read(self: *PieceSource, dest: []u8) error{ WouldBlock, Unused }!usize {
        if (self.pos >= self.data.len) return error.WouldBlock;
        const sizes = [_]usize{ 1, 7, 4093, 13, 509, 3001, 65 };
        var n = @min(@min(dest.len, self.data.len - self.pos), sizes[self.step % sizes.len]);
        self.step += 1;
        for (self.cuts) |c| if (c > self.pos and c < self.pos + n) {
            n = c - self.pos;
        };
        const d = @intFromPtr(dest.ptr);
        const r = @intFromPtr(self.ring.ptr);
        if (d < r or d >= r + self.ring.len) self.direct += 1;
        @memcpy(dest[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    pub fn wait(self: *PieceSource, event_fd: ?c_int, timeout_ms: c_int) void {
        _ = self;
        _ = event_fd;
        _ = timeout_ms;
    }
};

fn expectSameRuns(a: []const Run, b: []const Run) !void {
    try std.testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try std.testing.expectEqual(x.kind, y.kind);
        try std.testing.expectEqual(x.role, y.role);
        try std.testing.expectEqual(x.flags, y.flags);
        try std.testing.expectEqual(x.len, y.len);
    }
}

test "readSource reads open strings straight into the spill buffer" {
    const gpa = std.testing.allocator;
    var ref = try CircBuffer.create(gpa, std.heap.pageSize());
    defer ref.destroy();
    var buf = try CircBuffer.create(gpa, std.heap.pageSize());
    defer buf.destroy();
    var ts_ref = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = ref.storage };
    defer ts_ref.deinit();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(gpa);
    var cuts: std.ArrayListUnmanaged(usize) = .empty;
    defer cuts.deinit(gpa);
    try input.appendSlice(gpa, "head\r\n\x1b]0;small\x07");
    // ST split between its ESC and its backslash.
    try input.appendSlice(gpa, "\x1b_Gq=2;");
    try input.appendNTimes(gpa, 'Q', 5 * std.heap.pageSize() + 123);
    try cuts.append(gpa, input.items.len + 1);
    try input.appendSlice(gpa, "\x1b\\after one\r\n");
    // BEL-terminated OSC, then an ESC that is not an ST.
    try input.appendSlice(gpa, "\x1b]52;c;");
    try input.appendNTimes(gpa, 'R', 3 * std.heap.pageSize());
    try input.appendSlice(gpa, "\x07after two");
    // Terminator right at the end of a read, and a string with no more data.
    try input.appendSlice(gpa, "\x1bPq");
    try input.appendNTimes(gpa, '~', 2 * std.heap.pageSize());
    try cuts.append(gpa, input.items.len + 2);
    try input.appendSlice(gpa, "\x1b\\tail");

    drainAll(&ref, &ts_ref, input.items);
    var src = PieceSource{ .data = input.items, .cuts = cuts.items, .ring = buf.storage };
    while (src.pos < input.items.len) try buf.readSource(&src, 1_000_000_000, null, ts.sink());
    buf.drain(ts.sink());

    try std.testing.expectEqualStrings(input.items, ts.bytes.items);
    try std.testing.expectEqualStrings(ts_ref.bytes.items, ts.bytes.items);
    try expectSameRuns(ts_ref.runs.items, ts.runs.items);
    // The bulk of the strings went straight to the spill buffer.
    try std.testing.expect(src.direct > 4);
    try std.testing.expect(buf.open == null);
}

test "readSource: spill over the cap is discarded, also when read directly" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 64 * 1024);
    defer buf.destroy();
    buf.max_spill = 1024 * 1024;
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    const big = try gpa.alloc(u8, buf.max_spill + 100_000);
    defer gpa.free(big);
    @memset(big, 'Q');
    @memcpy(big[0..4], "\x1bPq#");
    @memcpy(big[big.len - 6 ..], "\x1b\\done");
    var src = PieceSource{ .data = big, .ring = buf.storage };
    while (src.pos < big.len) try buf.readSource(&src, 1_000_000_000, null, ts.sink());
    buf.drain(ts.sink());
    try std.testing.expectEqualStrings("done", ts.bytes.items);
    try std.testing.expect(buf.open == null);
    try std.testing.expect(buf.spill.capacity <= spill_keep);
}

test "takeSpill hands over a buffer that ends in the run, once" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, std.heap.pageSize());
    defer buf.destroy();
    const Taker = struct {
        taken: ?[]u8 = null,
        off: usize = 0,
        len: usize = 0,
        gpa: std.mem.Allocator,
        fn sink(self: *@This()) Sink {
            return .{ .ctx = self, .feed = feed, .view = view };
        }
        fn feed(ctx: *anyopaque, runs: []const Run, spill: []const u8, owner: *CircBuffer) void {
            _ = spill;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (runs) |r| if (r.flags.spill) {
                self.off = r.off;
                self.len = r.len;
                self.taken = owner.takeSpill(self.gpa, r.off, r.len);
                // Nothing is left to take.
                std.debug.assert(owner.takeSpill(self.gpa, r.off, r.len) == null);
            };
        }
        fn view(ctx: *anyopaque) View {
            _ = ctx;
            return .{ .rows = 4, .alt = false };
        }
    };
    var tk = Taker{ .gpa = gpa };
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(gpa);
    try input.appendSlice(gpa, "\x1b_Gq=2;");
    try input.appendNTimes(gpa, 'Q', 4 * std.heap.pageSize());
    try input.appendSlice(gpa, "\x1b\\");
    var src = PieceSource{ .data = input.items, .ring = buf.storage };
    while (src.pos < input.items.len) try buf.readSource(&src, 1_000_000_000, null, tk.sink());
    buf.drain(tk.sink());
    const taken = tk.taken orelse return error.NotTaken;
    defer gpa.free(taken);
    try std.testing.expectEqualStrings(input.items, taken[tk.off..][0..tk.len]);
    try std.testing.expectEqual(@as(usize, 0), buf.spill.capacity);
}

test "spill over the cap is discarded through its terminator" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 64 * 1024);
    defer buf.destroy();
    buf.max_spill = 4 * 1024 * 1024;
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    const big = try gpa.alloc(u8, buf.max_spill + 1024);
    defer gpa.free(big);
    @memset(big, 'Q');
    @memcpy(big[0..4], "\x1bPq#");
    @memcpy(big[big.len - 6 ..], "\x1b\\done");
    drainAll(&buf, &ts, big);
    try std.testing.expectEqualStrings("done", ts.bytes.items);
    try std.testing.expect(buf.spill.capacity <= spill_keep);
}

test "incomplete CSI and UTF-8 are held until the rest arrives" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, std.heap.pageSize());
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    append(&buf, "x\x1b[3");
    buf.drain(ts.sink());
    try std.testing.expectEqualStrings("x", ts.bytes.items);
    try std.testing.expect(!buf.pending());
    append(&buf, "1my\xc3");
    buf.drain(ts.sink());
    try std.testing.expectEqualStrings("x\x1b[31my", ts.bytes.items);
    append(&buf, "\xa9");
    buf.drain(ts.sink());
    try std.testing.expectEqualStrings("x\x1b[31my\xc3\xa9", ts.bytes.items);
}

test "dead kitty transfers are fed" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, std.heap.pageSize());
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 2, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    // A dead placement still moves the cursor, replaces ids and is freed
    // with its line, so every graphics command reaches the VT.
    const in = "\x1b_Ga=T,i=5,m=1;AAAA\x1b\\\x1b_Ga=q,i=6;AAAA\x1b\\\x1b_Gm=0;AAAA\x1b\\" ++
        "\x1b_Ga=T,i=9;AAAA\x1b\\\x1b_Ga=T;AAAA\x1b\\\r\n\r\n\r\n\x1b_Ga=t,i=9;BBBB\x1b\\";
    append(&buf, in);
    buf.drain(ts.sink());
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, ts.bytes.items, "\x1b_G"));
}

test "dead SGRs before a full reset are dropped; a pen reader keeps them" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, std.heap.pageSize());
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 2, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    append(&buf, "\x1b[1m\x1b[31m\x1b[0m\x1b[32mA\r\nB\r\nC\r\nD");
    buf.drain(ts.sink());
    try std.testing.expect(std.mem.indexOf(u8, ts.bytes.items, "\x1b[1m") == null);
    try std.testing.expect(std.mem.indexOf(u8, ts.bytes.items, "\x1b[31m") == null);
    try std.testing.expect(std.mem.startsWith(u8, ts.bytes.items, "\x1b[0m\x1b[32m"));

    ts.bytes.clearRetainingCapacity();
    append(&buf, "\x1b[1m\x1b[31m\x1b7\x1b[m\x1b[32mA\r\nB\r\nC\r\nD");
    buf.drain(ts.sink());
    try std.testing.expect(std.mem.startsWith(u8, ts.bytes.items, "\x1b[1m\x1b[31m\x1b7\x1b[m\x1b[32m"));

    // The first param decides: `0;1` resets, `1;0` does not.
    try std.testing.expect(resetsPen("\x1b[0;1m"));
    try std.testing.expect(resetsPen("\x1b[m"));
    try std.testing.expect(resetsPen("\x1b[;1m"));
    try std.testing.expect(!resetsPen("\x1b[1;0m"));
    try std.testing.expect(!resetsPen("\x1b[38;0m"));
    try std.testing.expect(!resetsPen("\x1b[0:1m"));
}
