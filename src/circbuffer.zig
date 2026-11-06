//! Mirrored circular buffer for handling input.
//! Owns byte/stream storage and a preparser for run classification and draining.

const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const posix = std.posix;

const Preparse = @import("preparser.zig");
const stEnd = Preparse.stringEnd;

pub const Run = Preparse.Run;
pub const Role = Preparse.Role;
pub const View = Preparse.View;

/// Receives the runs of a drain, in byte order. `stream` backs runs with
/// `Run.Flags.stream` set; `owner` is the buffer they come from, for
/// `takeStream` (valid only during the call). Return the number of runs
/// consumed; with `retain_live` the consumer may stop before a live text/LF.
pub const Sink = struct {
    ctx: *anyopaque,
    feed: *const fn (ctx: *anyopaque, runs: []const Run, stream: []const u8, owner: *CircBuffer) usize,
    view: *const fn (ctx: *anyopaque) View,
};

/// Default stream cap (as kitty's largest image); a longer string is
/// discarded through its terminator.
pub const default_max_stream: usize = 320 * 1024 * 1024;
/// Stream capacity kept between strings; larger buffers are freed.
const stream_keep: usize = 1024 * 1024;

const StreamState = struct {
    kind: Run.Kind,
    /// Where the open string starts in `stream`.
    base: usize,
    /// The last byte appended was ESC: `\` completes ST.
    esc: bool = false,
    discard: bool = false,
    /// `readSource` read the terminator straight into `stream`: the string is
    /// complete and the next drain emits it as a run, before the ring.
    closed: bool = false,
};

pub const CircBuffer = struct {
    pub const default_capacity = 1024 * 1024;

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
    /// During pressure consumption, stop before cell work still needed as
    /// lookahead. Normal frame drains and minimum reader progress consume it.
    retain_live: bool = false,
    /// Pressure hysteresis: release at least a quarter-ring before pausing,
    /// not just enough bytes to cross back under the 75% trigger.
    pause_tail: u64 = 0,
    preparser: Preparse.Preparser,
    stream: std.ArrayListUnmanaged(u8) = .empty,
    max_stream: usize = default_max_stream,
    open: ?StreamState = null,
    /// Create circular buffer
    pub fn create(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!CircBuffer {
        assert(capacity > 0);
        assert(std.math.isPowerOfTwo(capacity));

        var preparser = try Preparse.Preparser.init(allocator);
        errdefer preparser.deinit();

        if (mapMirror(capacity)) |storage| {
            return .{
                .allocator = allocator,
                .storage = storage,
                .capacity = capacity,
                .mapped = true,
                .preparser = preparser,
            };
        }

        const storage = try allocator.alloc(u8, capacity * 2);
        return .{
            .allocator = allocator,
            .storage = storage,
            .capacity = capacity,
            .mapped = false,
            .preparser = preparser,
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
        self.preparser.deinit();
        self.stream.deinit(self.allocator);
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
    /// 1. Bytes are never overwritten before they are consumed. Below a
    /// quarter free, `drain(sink, true)` consumes complete spans. Only painting
    /// proven obsolete by `preparser.isSpanObsolete` may be omitted during
    /// consumption. State and graphics stay ordered.
    /// Without a sink reading stops under pressure.
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

    /// Source read contract.
    pub fn readSource(self: *CircBuffer, source: anytype, hz: u32, pump: ?Pump, sink: ?Sink) error{Hangup}!void {
        return self.readSourceImpl(source, hz, pump, sink, false);
    }

    /// Flush the first burst after an idle wait promptly; continuous output
    /// remains frame-paced and still uses pressure draining.
    pub fn readSourceInteractive(self: *CircBuffer, source: anytype, hz: u32, pump: ?Pump, sink: ?Sink) error{Hangup}!void {
        return self.readSourceImpl(source, hz, pump, sink, true);
    }

    fn readSourceImpl(self: *CircBuffer, source: anytype, hz: u32, pump: ?Pump, sink: ?Sink, comptime interactive: bool) error{Hangup}!void {
        const rate: u32 = if (hz == 0) 30 else hz;
        const period_ns: i128 = @divTrunc(1_000_000_000, rate);
        const start_ns = nowNs();
        const mask = self.capacity - 1;
        var idle = false;
        var read_any = false;
        var read_after_idle = false;

        while (true) {

            // NOTE(vasco): Above 75% occupancy, consume complete runs from
            // the oldest roughly quarter-buffer, judging obsolete painting
            // with the newer runs as lookahead. Keep those newer runs queued;
            // an immediate full drain here would defeat the dead-zone trim.
            if (self.capacity - (self.head - self.tail) < self.capacity / 4) {
                const s = sink orelse return;

                self.drain(s, true);
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
                    if (interactive and read_after_idle) return;
                    if (interactive and !read_any) idle = true;
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
                        if ((builtin.os.tag != .macos or p.fd >= 0) and nowNs() - t0 < 200_000) {
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
            if (interactive) read_any = true;
            if (interactive and idle) read_after_idle = true;
            if (direct != null) {
                self.streamRead(n);
                continue;
            }
            self.syncMirror(off, n);
            self.head += n;
        }
    }

    /// Spare capacity of the open string's stream buffer to read into, or null
    /// when reads go to the ring (no open string, one that is already
    /// complete or discarded, or unconsumed bytes in the ring).
    fn directDest(self: *CircBuffer) ?[]u8 {
        const sp = &(self.open orelse return null);
        if (sp.closed or sp.discard or self.head != self.tail) return null;
        const len = self.stream.items.len - sp.base;
        // One read more than fits is enough to know the string is over the cap;
        // never more than the ring holds, so the bytes after the terminator
        // always fit back into it. A read is also no larger than what the
        // string already holds (at least 4 KiB): the bytes after the
        // terminator are copied back, which must stay small next to the
        // string (a short string that merely straddles a drain).
        const room = self.max_stream -| len +| 2;
        const want = @min(@min(room, self.capacity), @max(len, 4096));
        if (self.stream.capacity - self.stream.items.len < want) {
            const grown = @min(@max(self.stream.items.len + want, self.stream.capacity *| 2), self.stream.items.len + room);
            self.stream.ensureTotalCapacityPrecise(self.allocator, grown) catch return null;
        }
        return self.stream.unusedCapacitySlice()[0..want];
    }

    /// `n` bytes were read into the spare capacity of `stream`: keep them up
    /// to the terminator (as `continueStream` does for ring bytes) and return
    /// the rest to the ring.
    fn streamRead(self: *CircBuffer, n: usize) void {
        const sp = &self.open.?;
        const at = self.stream.items.len;
        const new = self.stream.unusedCapacitySlice()[0..n];
        const end: ?usize = if (sp.esc and new[0] == '\\') 1 else stEnd(new, 0);
        const take = end orelse n;
        sp.esc = end == null and new[n - 1] == 0x1B;
        if (at - sp.base + take > self.max_stream) {
            sp.discard = true;
            self.stream.shrinkRetainingCapacity(sp.base);
        } else {
            self.stream.items.len = at + take;
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

    /// Take the stream buffer itself, for the consumer of the run at
    /// `off..off + len` in it (during `Sink.feed`). Only a run that ends the
    /// buffer, longer than half a ring (smaller strings are cheaper to copy
    /// than to keep a buffer for), with no string open behind it. The
    /// caller owns the whole returned allocation, which holds the run at
    /// `off` (free it with the `allocator` given, which must be the one the
    /// ring uses), and no slice into the stream may be used afterwards.
    pub fn takeStream(self: *CircBuffer, allocator: std.mem.Allocator, off: usize, len: usize) ?[]u8 {
        if (self.open != null or len < self.capacity / 2) return null;
        if (off + len != self.stream.items.len) return null;
        if (allocator.ptr != self.allocator.ptr or allocator.vtable != self.allocator.vtable) return null;
        var buf = self.stream.allocatedSlice();
        self.stream = .empty;
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

    /// Pressure drains retain the live suffix as lookahead; normal frame
    /// drains consume it. Metadata is a bounded, reused workset in both cases.
    /// Unprovable input still makes progress rather than filling the ring.
    pub fn drain(self: *CircBuffer, sink: Sink, skipText: bool) void {
        assert(self.tail <= self.head);
        self.retain_live = skipText and !self.exact and self.underPressure();
        self.pause_tail = self.tail + self.capacity / 4;
        defer {
            self.retain_live = false;
            self.pause_tail = 0;
        }
        while (self.pending()) {
            const result = self.scan(sink.view(sink.ctx), skipText);
            const runs = self.preparser.runs.items;
            if (runs.len != 0) {
                const consumed = sink.feed(sink.ctx, runs, self.stream.items, self);
                assert(consumed <= runs.len);
                self.fed = self.fed or consumed != 0;
                if (consumed < runs.len) {
                    assert(self.retain_live);
                    const next = runs[consumed];
                    assert(!next.flags.stream);
                    const start: usize = @intCast(self.tail & (self.capacity - 1));
                    self.tail += (@as(usize, next.off) -% start) & (self.capacity - 1);
                    self.hold_at_head = 0;
                    self.tidyStream();
                    if (consumed == 0) {
                        assert(!self.underPressure());
                        return;
                    }
                    if (!result.retry and !self.underPressure()) return;
                    // Reframe only the retained bytes, against the VT's now
                    // current view. Their storage has not moved or been freed.
                    continue;
                }
            }
            // Do not stream out a future string until every preceding run
            // was consumed. Otherwise a retained live suffix would be fed
            // back as continuation bytes of that later string.
            if (result.stream) |run| self.openStream(self.storage[run.off..][0..run.len], run.kind);
            self.tail = self.head - result.held;
            self.hold_at_head = if (result.held != 0 and !result.retry) self.head else 0;
            self.tidyStream();
            if (!result.retry) return;
        }
    }

    /// Scheduling only: can the consumer stop before this ring-backed span
    /// after releasing a quarter-ring? Unprovable cell work before that point
    /// is consumed normally in the same pass. This hysteresis avoids repeated
    /// lookahead scans on each small PTY read just above the pressure trigger.
    pub fn canPauseBefore(self: *const CircBuffer, run: Run) bool {
        assert(!run.flags.stream);
        const start: usize = @intCast(self.tail & (self.capacity - 1));
        const before = (@as(usize, run.off) -% start) & (self.capacity - 1);
        return self.tail + @as(u64, before) >= self.pause_tail;
    }

    fn underPressure(self: *const CircBuffer) bool {
        return self.capacity - (self.head - self.tail) < self.capacity / 4;
    }

    fn tidyStream(self: *CircBuffer) void {
        if (self.open == null) {
            if (self.stream.capacity > stream_keep) self.stream.clearAndFree(self.allocator) else self.stream.clearRetainingCapacity();
        } else {
            // Strings completed by this drain were fed; only the open one
            // stays, at the start of the buffer, before it grows by reads.
            self.compactStream();
        }
    }

    /// Move the open string to the start of `stream`.
    fn compactStream(self: *CircBuffer) void {
        const st = &(self.open orelse return);
        if (st.base == 0) return;
        const rest = self.stream.items[st.base..];
        @memmove(self.stream.items[0..rest.len], rest);
        self.stream.shrinkRetainingCapacity(rest.len);
        st.base = 0;
    }

    /// Frame input, completing any earlier stream string before ring spans.
    fn scan(self: *CircBuffer, view: View, skipText: bool) Preparse.Result {
        const to_read: u32 = @intCast(self.head - self.tail);
        const start: u32 = @intCast(self.tail & (self.capacity - 1));
        const slice = self.storage[start..][0..to_read];
        const previous: StreamResult = if (self.open != null) self.continueStream(slice) else .{};
        // Continuation bytes are now owned by stream storage (or discarded),
        // even if consumption stops before the first remaining ring span.
        self.tail += previous.consumed;
        return self.preparser.prepare(slice[previous.consumed..], start + previous.consumed, view, self.exact or !skipText, previous.initial);
    }

    const StreamResult = struct {
        consumed: u32 = 0,
        initial: ?Preparse.Initial = null,
    };

    /// Append through the terminator; return consumed bytes and, if complete,
    /// a borrowed stream run for the preparser to classify before ring input.
    fn continueStream(self: *CircBuffer, slice: []const u8) StreamResult {
        const sp = &self.open.?;
        if (sp.closed) {
            // Read directly into `stream`; the terminator is already in.
            return .{ .initial = self.finishStream() };
        }
        const end: ?usize = if (sp.esc and slice.len != 0 and slice[0] == '\\') 1 else stEnd(slice, 0);
        const take = end orelse slice.len;
        sp.esc = end == null and slice.len != 0 and slice[slice.len - 1] == 0x1B;
        self.appendStream(slice[0..take]);
        if (end == null) return .{ .consumed = @intCast(slice.len) };
        return .{ .consumed = @intCast(take), .initial = self.finishStream() };
    }

    /// The open string is complete: its run is the tag, pointing into `stream`.
    fn finishStream(self: *CircBuffer) ?Preparse.Initial {
        const done = self.open.?;
        self.open = null;
        if (done.discard) return null;
        const bytes = self.stream.items[done.base..];
        return .{ .run = .{ .kind = done.kind, .flags = .{ .stream = true }, .off = @intCast(done.base), .len = @intCast(bytes.len) }, .bytes = bytes };
    }

    fn openStream(self: *CircBuffer, bytes: []const u8, kind: Run.Kind) void {
        self.open = .{ .kind = kind, .base = self.stream.items.len };
        self.open.?.esc = bytes[bytes.len - 1] == 0x1B;
        self.appendStream(bytes);
    }

    fn appendStream(self: *CircBuffer, bytes: []const u8) void {
        const sp = &self.open.?;
        if (sp.discard) return;
        if (self.stream.items.len - sp.base + bytes.len > self.max_stream) {
            sp.discard = true;
            self.stream.shrinkRetainingCapacity(sp.base);
            return;
        }
        self.stream.appendSlice(self.allocator, bytes) catch {
            sp.discard = true;
            self.stream.shrinkRetainingCapacity(sp.base);
        };
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
    fn feed(ctx: *anyopaque, runs: []const Run, stream: []const u8, owner: *CircBuffer) usize {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        var obsolete_prefix = false;
        for (runs, 0..) |input, index| {
            var r = input;
            r.flags.ghost = owner.preparser.isSpanObsolete(index, null);
            if (owner.retain_live) {
                if (!r.flags.ghost and (r.kind == .text or r.role == .lf) and
                    (obsolete_prefix or owner.canPauseBefore(r))) return index;
                obsolete_prefix = obsolete_prefix or r.flags.ghost;
            }
            const src = if (r.flags.stream) stream else self.storage;
            if (!(r.flags.ghost and r.kind == .text)) self.bytes.appendSlice(self.gpa, src[r.off..][0..r.len]) catch unreachable;
            self.runs.append(self.gpa, r) catch unreachable;
        }
        return runs.len;
    }
    fn view(ctx: *anyopaque) View {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        return self.view_;
    }
};

/// Test input helper: use the same mirror synchronization as PTY reads.
pub fn append(buf: *CircBuffer, src: []const u8) void {
    const cap = buf.capacity;
    const off: usize = @intCast(buf.head & (cap - 1));
    assert(src.len <= cap - (buf.head - buf.tail));
    @memcpy(buf.storage[off..][0..src.len], src);
    buf.syncMirror(off, src.len);
    buf.head += src.len;
}

test "test input wraps in an allocator-backed ring" {
    const gpa = std.testing.allocator;
    const cap = 16;
    var buf: CircBuffer = .{
        .allocator = gpa,
        .storage = try gpa.alloc(u8, cap * 2),
        .capacity = cap,
        .mapped = false,
        .preparser = try Preparse.Preparser.init(gpa),
    };
    defer buf.destroy();
    const bytes = "0123456789abcdef";
    for (0..cap) |off| {
        for (1..cap + 1) |len| {
            @memset(buf.storage, 0);
            buf.head = off;
            buf.tail = off;
            append(&buf, bytes[0..len]);
            try std.testing.expectEqual(off + len, buf.head);
            try std.testing.expectEqualStrings(bytes[0..len], buf.storage[off..][0..len]);
            for (bytes[0..len], 0..) |byte, i| {
                const at = (off + i) & (cap - 1);
                try std.testing.expectEqual(byte, buf.storage[at]);
                try std.testing.expectEqual(byte, buf.storage[at + cap]);
            }
        }
    }
}

test "framing defers obsolescence to span consumption" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 4096);
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 2, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    const bytes = "a\x1b[31mb\x1b[32mc\x1b[33md\x1b[34me\x1b[35mf\x1b[36mg\x1b[37mh\x1b[0mi\x1b[2JX";
    append(&buf, bytes);
    _ = buf.scan(ts.view_, true);
    for (buf.preparser.runs.items) |run| try std.testing.expect(!run.flags.ghost);
    try std.testing.expect(!buf.preparser.visibility_ready);
    try std.testing.expectEqual(@as(usize, 0), ts.bytes.items.len);
    const sink = ts.sink();
    _ = sink.feed(sink.ctx, buf.preparser.runs.items, buf.stream.items, &buf);
    try std.testing.expect(buf.preparser.visibility_ready);
    try std.testing.expect(std.mem.indexOf(u8, ts.bytes.items, "a") == null);
    try std.testing.expect(std.mem.endsWith(u8, ts.bytes.items, "\x1b[2JX"));
    try std.testing.expectEqual(@as(usize, 9), std.mem.count(u8, ts.bytes.items, "\x1b["));
}

test "held input and open stream strings survive until complete spans can be consumed" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 4096);
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    append(&buf, "A\x1b[3");
    buf.drain(ts.sink(), true);
    try std.testing.expect(!buf.pending());
    append(&buf, "1mB");
    buf.drain(ts.sink(), true);
    try std.testing.expectEqualStrings("A\x1b[31mB", ts.bytes.items);
    append(&buf, "\x1b]0;open");
    buf.drain(ts.sink(), true);
    try std.testing.expect(buf.open != null);
    append(&buf, "\x07END");
    buf.drain(ts.sink(), true);
    try std.testing.expect(buf.open == null);
    try std.testing.expectEqualStrings("A\x1b[31mB\x1b]0;open\x07END", ts.bytes.items);
}

test "exact consumption writes all text and obsolete checks retain visible text" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 4096);
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    const cleared = "a\x1b[31mb\x1b[2JX";
    buf.exact = true;
    append(&buf, cleared);
    buf.drain(ts.sink(), true);
    try std.testing.expectEqualStrings(cleared, ts.bytes.items);
    ts.bytes.clearRetainingCapacity();
    buf.exact = false;
    append(&buf, cleared);
    buf.drain(ts.sink(), false); // Normal frame consumption keeps all writes.
    try std.testing.expectEqualStrings(cleared, ts.bytes.items);
    try std.testing.expect(!buf.preparser.visibility_ready);
    ts.bytes.clearRetainingCapacity();
    const visible = "a\x1b[31mb\x1b[32mc";
    append(&buf, visible);
    buf.drain(ts.sink(), true);
    try std.testing.expectEqualStrings(visible, ts.bytes.items);
}

test "metadata allocation failure never drops runs during pressure consumption" {
    const gpa = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(gpa, .{});
    var buf = try CircBuffer.create(failing.allocator(), 4096);
    defer buf.destroy();
    buf.exact = true;
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    failing.fail_index = failing.alloc_index;
    var input: [4096]u8 = undefined;
    @memset(&input, '\n');
    append(&buf, &input);
    buf.drain(ts.sink(), true);
    try std.testing.expectEqualStrings(&input, ts.bytes.items);
    try std.testing.expectEqual(buf.head, buf.tail);
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
    buf.drain(ts.sink(), true);
    try std.testing.expectEqualStrings("a\r\nb\r\nc\r\nd\r\ne", ts.bytes.items);
    ts.bytes.clearRetainingCapacity();
    ts.runs.clearRetainingCapacity();
    append(&buf, "a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng");
    buf.drain(ts.sink(), true);
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
        if (buf.capacity - (buf.head - buf.tail) < buf.capacity / 4) buf.drain(ts.sink(), true);
    }
    buf.drain(ts.sink(), true);
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
    buf.drain(ts.sink(), true);
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
    buf.drain(ts.sink(), true);
    try std.testing.expectEqualStrings("\n\x1b[H\x1b[2Jnew", ts.bytes.items);

    ts.bytes.clearRetainingCapacity();
    append(&buf, "a\r\nb\r\nc\x1b[3Ad");
    buf.drain(ts.sink(), true);
    try std.testing.expectEqualStrings("a\r\nb\r\nc\x1b[3Ad", ts.bytes.items);

    // ED 3 only clears the scrollback; under DECOM home is the region's top.
    for ([_][]const u8{ "keep\x1b[3J", "keep\x1b[2;3r\x1b[?6h\x1b[H\x1b[J\x1b[?6l" }) |in| {
        ts.bytes.clearRetainingCapacity();
        append(&buf, in);
        buf.drain(ts.sink(), true);
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
        buf.drain(ts.sink(), true);
        try std.testing.expectEqualStrings(in, ts.bytes.items);
    }
    ts.bytes.clearRetainingCapacity();
    append(&buf, "\x1b[?1049hA\x1b[?1049l\x1b[?1049hB");
    buf.drain(ts.sink(), true);
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?1049l\x1b[?1049hB", ts.bytes.items);
}

test "strings longer than the ring arrive whole through the stream buffer" {
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
    var streamed = false;
    for (ts.runs.items) |r| streamed = streamed or r.flags.stream;
    try std.testing.expect(streamed);
    // Idle stream memory is released.
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

test "interactive source flushes the first burst after an idle wait" {
    const Source = struct {
        step: u8 = 0,
        waits: u32 = 0,

        pub fn read(s: *@This(), dest: []u8) error{ WouldBlock, Hangup }!usize {
            if (s.step != 1) return error.WouldBlock;
            s.step = 2;
            @memcpy(dest[0..5], "hello");
            return 5;
        }

        pub fn wait(s: *@This(), _: ?c_int, _: c_int) void {
            s.waits += 1;
            s.step = 1;
        }
    };
    var buffer = try CircBuffer.create(std.testing.allocator, 1024);
    defer buffer.destroy();
    var source: Source = .{};
    try buffer.readSourceInteractive(&source, 1, null, null);
    try std.testing.expectEqual(@as(u32, 1), source.waits);
    try std.testing.expectEqualStrings("hello", buffer.storage[0..5]);
    try std.testing.expect(buffer.pending());
}

test "interactive source keeps already active output frame-paced" {
    const Source = struct {
        step: u8 = 0,
        waits: u32 = 0,
        until: i128,

        pub fn read(s: *@This(), dest: []u8) error{ WouldBlock, Hangup }!usize {
            if (s.step != 0 and s.step != 2) return error.WouldBlock;
            dest[0] = if (s.step == 0) 'a' else 'b';
            s.step += 1;
            return 1;
        }

        pub fn wait(s: *@This(), _: ?c_int, _: c_int) void {
            s.waits += 1;
            if (s.step == 1) {
                s.step = 2;
            } else {
                while (nowNs() < s.until) std.atomic.spinLoopHint();
            }
        }
    };
    var buffer = try CircBuffer.create(std.testing.allocator, 1024);
    defer buffer.destroy();
    var source: Source = .{ .until = nowNs() + 60_000_000 };
    try buffer.readSourceInteractive(&source, 20, null, null);
    try std.testing.expect(source.waits >= 2);
    try std.testing.expectEqualStrings("ab", buffer.storage[0..2]);
}

test "readSource pressure leaves the final input for normal span consumption" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 4096);
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    var input: [8315]u8 = undefined;
    @memset(&input, 'x');
    var src = PieceSource{ .data = &input, .cuts = &.{}, .ring = buf.storage };
    try buf.readSource(&src, 1_000_000_000, null, ts.sink());
    try std.testing.expectEqual(input.len, src.pos);
    try std.testing.expect(!buf.preparser.exact);
    const remaining = buf.head - buf.tail;
    try std.testing.expect(remaining > 0 and remaining <= buf.capacity - buf.capacity / 4);
    try std.testing.expectEqual(@as(u64, input.len), ts.bytes.items.len + remaining);
    buf.drain(ts.sink(), true);
    try std.testing.expectEqualStrings(&input, ts.bytes.items);
    try std.testing.expectEqual(buf.head, buf.tail);
}

test "readSource reads open strings straight into the stream buffer" {
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
    buf.drain(ts.sink(), true);

    try std.testing.expectEqualStrings(input.items, ts.bytes.items);
    try std.testing.expectEqualStrings(ts_ref.bytes.items, ts.bytes.items);
    try expectSameRuns(ts_ref.runs.items, ts.runs.items);
    // The bulk of the strings went straight to the stream buffer.
    try std.testing.expect(src.direct > 4);
    try std.testing.expect(buf.open == null);
}

test "readSource: stream over the cap is discarded, also when read directly" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 64 * 1024);
    defer buf.destroy();
    buf.max_stream = 1024 * 1024;
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    const big = try gpa.alloc(u8, buf.max_stream + 100_000);
    defer gpa.free(big);
    @memset(big, 'Q');
    @memcpy(big[0..4], "\x1bPq#");
    @memcpy(big[big.len - 6 ..], "\x1b\\done");
    var src = PieceSource{ .data = big, .ring = buf.storage };
    while (src.pos < big.len) try buf.readSource(&src, 1_000_000_000, null, ts.sink());
    buf.drain(ts.sink(), true);
    try std.testing.expectEqualStrings("done", ts.bytes.items);
    try std.testing.expect(buf.open == null);
    try std.testing.expect(buf.stream.capacity <= stream_keep);
}

test "takeStream hands over a buffer that ends in the run, once" {
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
        fn feed(ctx: *anyopaque, runs: []const Run, stream: []const u8, owner: *CircBuffer) usize {
            _ = stream;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (runs) |r| if (r.flags.stream) {
                self.off = r.off;
                self.len = r.len;
                self.taken = owner.takeStream(self.gpa, r.off, r.len);
                // Nothing is left to take.
                std.debug.assert(owner.takeStream(self.gpa, r.off, r.len) == null);
            };
            return runs.len;
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
    buf.drain(tk.sink(), true);
    const taken = tk.taken orelse return error.NotTaken;
    defer gpa.free(taken);
    try std.testing.expectEqualStrings(input.items, taken[tk.off..][0..tk.len]);
    try std.testing.expectEqual(@as(usize, 0), buf.stream.capacity);
}

test "stream over the cap is discarded through its terminator" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 64 * 1024);
    defer buf.destroy();
    buf.max_stream = 4 * 1024 * 1024;
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    const big = try gpa.alloc(u8, buf.max_stream + 1024);
    defer gpa.free(big);
    @memset(big, 'Q');
    @memcpy(big[0..4], "\x1bPq#");
    @memcpy(big[big.len - 6 ..], "\x1b\\done");
    drainAll(&buf, &ts, big);
    try std.testing.expectEqualStrings("done", ts.bytes.items);
    try std.testing.expect(buf.stream.capacity <= stream_keep);
}

test "incomplete CSI and UTF-8 are held until the rest arrives" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, std.heap.pageSize());
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    append(&buf, "x\x1b[3");
    buf.drain(ts.sink(), true);
    try std.testing.expectEqualStrings("x", ts.bytes.items);
    try std.testing.expect(!buf.pending());
    append(&buf, "1my\xc3");
    buf.drain(ts.sink(), true);
    try std.testing.expectEqualStrings("x\x1b[31my", ts.bytes.items);
    append(&buf, "\xa9");
    buf.drain(ts.sink(), true);
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
    buf.drain(ts.sink(), true);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, ts.bytes.items, "\x1b_G"));
}

test "text pruning always applies SGRs in order including before resets and pen readers" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, std.heap.pageSize());
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 2, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    append(&buf, "\x1b[1m\x1b[31m\x1b[0m\x1b[32mA\r\nB\r\nC\r\nD");
    buf.drain(ts.sink(), true);
    try std.testing.expect(std.mem.startsWith(u8, ts.bytes.items, "\x1b[1m\x1b[31m\x1b[0m\x1b[32m"));

    ts.bytes.clearRetainingCapacity();
    append(&buf, "\x1b[1m\x1b[31m\x1b7\x1b[m\x1b[32mA\r\nB\r\nC\r\nD");
    buf.drain(ts.sink(), true);
    try std.testing.expect(std.mem.startsWith(u8, ts.bytes.items, "\x1b[1m\x1b[31m\x1b7\x1b[m\x1b[32m"));
}

test "the scanner's CSI parse is what the VT applies" {
    var buf = try CircBuffer.create(std.testing.allocator, 4096);
    defer buf.destroy();
    // Bytes a CSI cannot hold make the VT ignore it: not a clear.
    append(&buf, "\x1b[2\x01Jx\x1b[2J\x1b[38:2:1:2:3;1m\x1b[1;2");
    const result = buf.scan(.{ .rows = 4, .alt = false }, true);
    try std.testing.expectEqual(@as(u32, 5), result.held);
    const runs = buf.preparser.runs.items;
    try std.testing.expectEqual(@as(usize, 4), runs.len);
    try std.testing.expectEqual(Role.ordered, runs[0].role);
    try std.testing.expectEqual(Role.barrier, runs[2].role);
    try std.testing.expectEqual(Role.sgr, runs[3].role);
    try std.testing.expectEqual(@as(usize, 3), buf.preparser.csis.items.len);
    try std.testing.expectEqual(@as(u8, 0), buf.preparser.csiAt(0).final);
    try std.testing.expectEqual(@as(u8, 'J'), buf.preparser.csiAt(1).final);
    try std.testing.expectEqual(@as(u32, 2), buf.preparser.csiAt(1).value(0));
    const sgr = buf.preparser.csiAt(2);
    try std.testing.expectEqual(@as(usize, 2), sgr.params.len);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1, 2, 3 }, sgr.subsOf(sgr.params[0]));
    try std.testing.expectEqual(@as(u32, 1), sgr.value(1));
}

test "pressure retains live lookahead across reads instead of painting each suffix" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 4096);
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    var input: [3900]u8 = undefined;
    for (0..650) |i| @memcpy(input[i * 6 ..][0..6], "line\r\n");
    append(&buf, &input);
    buf.drain(ts.sink(), true);
    try std.testing.expect(buf.pending());
    try std.testing.expect(!buf.retain_live);
    try std.testing.expect(buf.head - buf.tail > 0 and buf.head - buf.tail <= 48);
    const at: usize = @intCast(buf.tail & (buf.capacity - 1));
    const saved = try gpa.dupe(u8, buf.storage[at..][0..@intCast(buf.head - buf.tail)]);
    defer gpa.free(saved);
    for (0..650) |i| @memcpy(input[i * 6 ..][0..6], "next\r\n");
    append(&buf, &input);
    try std.testing.expectEqualStrings(saved, buf.storage[at..][0..saved.len]);
    buf.drain(ts.sink(), true);
    for (ts.runs.items) |run| {
        if (run.kind == .text) try std.testing.expect(run.flags.ghost);
    }
    try std.testing.expect(buf.head - buf.tail > 0 and buf.head - buf.tail <= 48);
    buf.drain(ts.sink(), false);
    try std.testing.expectEqual(buf.head, buf.tail);
    try std.testing.expect(std.mem.endsWith(u8, ts.bytes.items, "next\r\n"));
}

test "pressure without an obsolete prefix makes progress" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 4096);
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    var input: [4096]u8 = undefined;
    @memset(&input, 'x');
    append(&buf, &input);
    buf.drain(ts.sink(), true);
    try std.testing.expectEqual(buf.head, buf.tail);
    try std.testing.expectEqualStrings(&input, ts.bytes.items);
    try std.testing.expect(!buf.retain_live);
}

test "a future open string stays behind retained live text" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 4096);
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    var input: [3600]u8 = undefined;
    for (0..600) |i| @memcpy(input[i * 6 ..][0..6], "line\r\n");
    append(&buf, &input);
    append(&buf, "visible\x1b]0;unfinished");
    buf.drain(ts.sink(), true);
    try std.testing.expect(buf.pending());
    try std.testing.expect(buf.open == null);
    buf.drain(ts.sink(), false);
    try std.testing.expect(buf.open != null);
    try std.testing.expectEqual(buf.head, buf.tail);
    append(&buf, "\x07after");
    buf.drain(ts.sink(), false);
    try std.testing.expect(buf.open == null);
    try std.testing.expect(std.mem.endsWith(u8, ts.bytes.items, "visible\x1b]0;unfinished\x07after"));
}

test "stream completion across the mirror survives partial pressure consumption" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 4096);
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    buf.head = 4090;
    buf.tail = 4090;
    append(&buf, "\x1b]0;");
    buf.drain(ts.sink(), false);
    try std.testing.expect(buf.open != null);
    append(&buf, "payload\x07");
    var input: [3600]u8 = undefined;
    for (0..600) |i| @memcpy(input[i * 6 ..][0..6], "line\r\n");
    append(&buf, &input);
    buf.drain(ts.sink(), true);
    try std.testing.expect(buf.open == null);
    try std.testing.expect(buf.tail <= buf.head);
    try std.testing.expect(buf.head - buf.tail > 0 and buf.head - buf.tail <= 48);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ts.bytes.items, "\x1b]0;payload\x07"));
    buf.drain(ts.sink(), false);
    try std.testing.expectEqual(buf.head, buf.tail);
}

test "unprovable pressure has quarter-ring hysteresis rather than one-read rescans" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 4096);
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    var input: [3200]u8 = undefined;
    for (0..800) |i| @memcpy(input[i * 4 ..][0..4], "\x1b[mX");
    append(&buf, &input);
    buf.drain(ts.sink(), true);
    try std.testing.expect(buf.tail >= buf.capacity / 4);
    try std.testing.expect(buf.pending());
    append(&buf, "Y");
    try std.testing.expect(!buf.underPressure());
    buf.drain(ts.sink(), false);
    try std.testing.expectEqualStrings(&input, ts.bytes.items[0..input.len]);
    try std.testing.expectEqual(@as(u8, 'Y'), ts.bytes.items[input.len]);
}

test "dense obsolete lines keep lookahead across metadata windows before the progress floor" {
    const gpa = std.testing.allocator;
    var buf = try CircBuffer.create(gpa, 64 * 1024);
    defer buf.destroy();
    var ts = TestSink{ .gpa = gpa, .view_ = .{ .rows = 4, .alt = false }, .storage = buf.storage };
    defer ts.deinit();
    var input: [60000]u8 = undefined;
    for (0..30000) |i| @memcpy(input[i * 2 ..][0..2], "X\n");
    append(&buf, &input);
    buf.drain(ts.sink(), true);
    for (ts.runs.items) |run| {
        if (run.kind == .text) try std.testing.expect(run.flags.ghost);
    }
    try std.testing.expect(buf.head - buf.tail > 0 and buf.head - buf.tail <= 16);
    buf.drain(ts.sink(), false);
    try std.testing.expectEqual(buf.head, buf.tail);
}
