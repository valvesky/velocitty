//! Firehose + parse + VT microbench. `zig build bench`

const std = @import("std");
const CircBuffer = @import("circbuffer.zig").CircBuffer;
const VtState = @import("vt.zig").VtState;

const ring_cap: usize = 64 * 1024;
const firehose_bytes: usize = 256 * 1024 * 1024;
const cols: u16 = 80;
const rows: u16 = 24;
const iters: u32 = 200;
const line_w: usize = 81; // 80 printable + '\n'

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var buf = try CircBuffer.create(gpa, ring_cap);
    defer buf.destroy();

    var term = try VtState.init(gpa, cols, rows, 1000, buf.storage);
    defer term.deinit();

    var chunk: [ring_cap]u8 = undefined;
    fillLines(&chunk);

    std.debug.print(
        "velocitty bench  ring {d} KiB  screen {d}x{d}  mapped={s}  firehose {d} MiB  {d} iters\n",
        .{
            ring_cap / 1024,
            cols,
            rows,
            if (buf.mapped) "yes" else "heap",
            firehose_bytes / (1024 * 1024),
            iters,
        },
    );

    var t0 = nowNs();
    var off: usize = 0;
    while (off < firehose_bytes) {
        ingest(&buf, &chunk);
        off += chunk.len;
    }
    const firehose_ns = nowNs() - t0;
    const retained = retainedBytes(&buf);
    report("firehose into ring", firehose_ns, firehose_bytes);
    std.debug.print("  retained {d} B  (cap {d}; truncated={s})\n\n", .{
        retained,
        ring_cap,
        if (retained <= ring_cap) "yes" else "NO",
    });

    rewindPending(&buf);
    t0 = nowNs();
    var i: u32 = 0;
    while (i < iters) : (i += 1) {
        rewindPending(&buf);
        _ = buf.consumeAndGetRuns(rows);
    }
    reportIters("lines+runs last 24 (DESIGN)", nowNs() - t0, iters, ring_cap);

    rewindPending(&buf);
    t0 = nowNs();
    i = 0;
    while (i < iters) : (i += 1) {
        rewindPending(&buf);
        _ = buf.consumeAndGetRuns(std.math.maxInt(usize));
    }
    reportIters("lines+runs all ring (main)", nowNs() - t0, iters, ring_cap);

    rewindPending(&buf);
    t0 = nowNs();
    i = 0;
    while (i < iters) : (i += 1) {
        rewindPending(&buf);
        term.reset();
        const runs = buf.consumeAndGetRuns(rows);
        if (runs.len != 0) term.feedRuns(runs);
    }
    reportIters("pipeline last 24", nowNs() - t0, iters, ring_cap);

    rewindPending(&buf);
    t0 = nowNs();
    i = 0;
    while (i < iters) : (i += 1) {
        rewindPending(&buf);
        term.reset();
        const runs = buf.consumeAndGetRuns(std.math.maxInt(usize));
        if (runs.len != 0) term.feedRuns(runs);
    }
    reportIters("pipeline all ring", nowNs() - t0, iters, ring_cap);
}

fn fillLines(dest: []u8) void {
    var i: usize = 0;
    while (i < dest.len) {
        const n = @min(line_w, dest.len - i);
        @memset(dest[i .. i + n], 'x');
        dest[i + n - 1] = '\n';
        i += n;
    }
}

fn ingest(buf: *CircBuffer, src: []const u8) void {
    const cap = buf.capacity;
    const mask = cap - 1;
    var rest = src;
    while (rest.len != 0) {
        const off: usize = @intCast(buf.head & mask);
        const dest = buf.storage[off..][0..cap];
        const n = @min(dest.len, rest.len);
        @memcpy(dest[0..n], rest[0..n]);
        if (!buf.mapped and n != 0) {
            const a = buf.storage;
            const first = @min(n, cap - off);
            if (first != 0) @memcpy(a[off + cap ..][0..first], a[off..][0..first]);
            const extra = n - first;
            if (extra != 0) @memcpy(a[0..extra], a[cap..][0..extra]);
        }
        buf.head += n;
        rest = rest[n..];
    }
}

fn rewindPending(buf: *CircBuffer) void {
    buf.tail = if (buf.head > buf.capacity) buf.head - buf.capacity else 0;
}

fn retainedBytes(buf: *const CircBuffer) u64 {
    const live = buf.head - buf.tail;
    return if (live > buf.capacity) buf.capacity else live;
}

fn nowNs() i128 {
    return @intCast(std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds);
}

fn report(name: []const u8, ns: i128, bytes: usize) void {
    const sec = @as(f64, @floatFromInt(ns)) / 1e9;
    const gib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
    const rate = if (sec > 0) gib / sec else 0;
    std.debug.print("{s:<36} {d:>8.2} ms  {d:>7.2} GiB/s\n", .{ name, sec * 1000.0, rate });
}

fn reportIters(name: []const u8, ns: i128, n: u32, bytes_per: usize) void {
    const sec = @as(f64, @floatFromInt(ns)) / 1e9;
    const total = bytes_per * n;
    const gib = @as(f64, @floatFromInt(total)) / (1024.0 * 1024.0 * 1024.0);
    const rate = if (sec > 0) gib / sec else 0;
    const us = if (n == 0) 0 else sec * 1e6 / @as(f64, @floatFromInt(n));
    std.debug.print("{s:<36} {d:>8.2} ms  {d:>7.1} us/iter  {d:>7.2} GiB/s\n", .{
        name,
        sec * 1000.0,
        us,
        rate,
    });
}
