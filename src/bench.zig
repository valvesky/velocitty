//! Headless benchmarks: PTY → circbuffer scan → VT → render → present copy.
//! Every row reports p50/p95 over individual frames or lookup batches.
//! No window, Peak, or compositor. `zig build bench -- --help`.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const Ring = @import("circbuffer.zig");
const CircBuffer = Ring.CircBuffer;
const Run = Ring.Run;
const VtState = @import("vt.zig").VtState;
const Draw = @import("draw.zig");
const Type = @import("type.zig");
const Select = @import("select.zig");

// Same ring, scrollback and glyph cache as main.zig.
const default_ring_cap = 64 * 1024;
/// `--ring KIB` (power of two); set once in main before any section runs.
var ring_cap: usize = default_ring_cap;
const scrollback = 1000;
const cache_capacity = 2048;
const size_px: f32 = 16;

const font_paths = [_][]const u8{
    "/usr/share/fonts/TTF/IosevkaNerdFontMono-Regular.ttf",
    "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
};
// main.zig fallback_paths (Linux).
const fallback_paths = [_][]const u8{
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/noto/NotoSansSymbols-Regular.ttf",
    "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/gnu-free/FreeSans.otf",
    "/usr/share/fonts/noto/NotoColorEmoji.ttf",
};

const Options = struct {
    quick: bool = false,
    spin: bool = true,
    mib: u32 = 4,
    ring_kib: u32 = default_ring_cap / 1024,
    burst_kib: u32 = 16,
    cols: u16 = 120,
    rows: u16 = 40,
    samples: u32 = 200,
    font: ?[]const u8 = null,
    only: ?[]const u8 = null,
    dump: ?[]const u8 = null,
    image: ?[]const u8 = null,
    help: bool = false,
};

const usage =
    \\Usage: zig build bench -- [options]
    \\  --quick           1 MiB per workload, 40 samples (explicit values still win)
    \\  --mib N           bytes per PTY workload in MiB (1..256; default 4)
    \\  --burst KIB       bytes read per frame (1..48; default 16)
    \\  --ring KIB        ring size, power of two (default 64, as main.zig)
    \\  --grid COLSxROWS  pipeline/render grid (default 120x40)
    \\  --samples N       render frames / glyph batches per row (10..10000; default 200)
    \\  --font PATH       primary font (default: fc-match monospace, like main.zig)
    \\  --only A,B        sections: ascii unicode grapheme csi-short long-escape
    \\                    kitty-image sixel pi drain firehose kitten image glyph render
    \\                    (drain/firehose plus workload names: only those workloads)
    \\  --dump DIR        write each workload (--mib, --only) to DIR/<name>.bin and exit;
    \\                    for timing other terminals with `cat`
    \\  --image PATH      PNG for the image section (default: generated 1920x1080 noise)
    \\  --no-spin         skip the 500 ms spin-up (for perf stat instruction counts)
    \\  --help
    \\
    \\Usage: velocitty-bench +terminal-stream [--data=PATH|-] [--terminal-rows=80]
    \\                       [--terminal-cols=120] [--drop]
    \\  Same interface and work as `ghostty-bench +terminal-stream`: read the
    \\  file (or stdin) in 64 KiB pieces into the ring and drain it into the VT,
    \\  every byte parsed; run once, print nothing (time it with hyperfine or
    \\  `time`). No --data: does nothing. --drop: firehose dropping, as the app.
    \\Pipeline rows: one frame = read one burst from a real PTY (writer thread,
    \\raw slave), drain (scan + feed), renderSel, damaged-rows copy (present).
    \\io is time inside read(2); time blocked in poll(2) is io-wait, excluded.
    \\Logs: bench/<UTC>-<git12>[-dirty].txt and last_bench.
    \\
;

fn parseOptions(args: []const [*:0]const u8) !Options {
    var opt: Options = .{};
    var seen_mib = false;
    var seen_samples = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = arg[0 .. eq orelse arg.len];
        if (std.mem.eql(u8, name, "--no-spin")) {
            if (eq != null) return error.UnexpectedValue;
            opt.spin = false;
            continue;
        }
        if (std.mem.eql(u8, name, "--quick") or std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
            if (eq != null) return error.UnexpectedValue;
            if (name[2] == 'q') opt.quick = true else opt.help = true;
            continue;
        }
        const value: []const u8 = if (eq) |at| arg[at + 1 ..] else blk: {
            i += 1;
            if (i == args.len) return error.MissingValue;
            break :blk std.mem.span(args[i]);
        };
        if (value.len == 0 or std.mem.startsWith(u8, value, "--")) return error.MissingValue;
        if (std.mem.eql(u8, name, "--mib")) {
            opt.mib = try count(value, 1, 256);
            seen_mib = true;
        } else if (std.mem.eql(u8, name, "--ring")) {
            opt.ring_kib = try count(value, 4, 65536);
            if (!std.math.isPowerOfTwo(opt.ring_kib)) return error.InvalidCount;
        } else if (std.mem.eql(u8, name, "--burst")) {
            opt.burst_kib = try count(value, 1, 48);
        } else if (std.mem.eql(u8, name, "--samples")) {
            opt.samples = try count(value, 10, 10000);
            seen_samples = true;
        } else if (std.mem.eql(u8, name, "--grid")) {
            const x = std.mem.indexOfScalar(u8, value, 'x') orelse return error.InvalidGrid;
            opt.cols = @intCast(count(value[0..x], 2, 1000) catch return error.InvalidGrid);
            opt.rows = @intCast(count(value[x + 1 ..], 2, 1000) catch return error.InvalidGrid);
        } else if (std.mem.eql(u8, name, "--font")) {
            opt.font = value;
        } else if (std.mem.eql(u8, name, "--only")) {
            opt.only = value;
        } else if (std.mem.eql(u8, name, "--image")) {
            opt.image = value;
        } else if (std.mem.eql(u8, name, "--dump")) {
            opt.dump = value;
        } else return error.UnknownOption;
    }
    if (opt.quick) {
        if (!seen_mib) opt.mib = 1;
        if (!seen_samples) opt.samples = 40;
    }
    return opt;
}

fn count(value: []const u8, min: u32, max: u32) !u32 {
    for (value) |c| if (c < '0' or c > '9') return error.InvalidCount;
    const n = std.fmt.parseInt(u32, value, 10) catch return error.InvalidCount;
    if (n < min or n > max) return error.InvalidCount;
    return n;
}

fn wanted(opt: Options, section: []const u8) bool {
    const only = opt.only orelse return true;
    var it = std.mem.splitScalar(u8, only, ',');
    while (it.next()) |s| if (std.mem.eql(u8, s, section)) return true;
    return false;
}

const Log = struct {
    buffer: std.Io.Writer.Allocating,
    echo: bool = true,
    fn print(self: *Log, comptime fmt: []const u8, args: anytype) !void {
        if (self.echo) std.debug.print(fmt, args);
        try self.buffer.writer.print(fmt, args);
    }
};

/// Shared setup: fonts and cell metrics.
const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opt: Options,
    ctx: ?*Type.Context,
    cell_w: u32,
    cell_h: u32,
    emoji: bool,
};

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "+terminal-stream")) {
        return terminalStream(argv[2..]);
    }
    const opt = parseOptions(init.args.vector) catch |err| {
        std.debug.print("bench: invalid arguments: {s}\n{s}", .{ @errorName(err), usage });
        return err;
    };
    if (opt.help) {
        std.debug.print("{s}", .{usage});
        return;
    }
    // Same allocator as a release main.zig.
    const gpa = std.heap.c_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();
    if (opt.dump) |dir| return dumpWorkloads(io, gpa, opt, dir);
    ring_cap = @as(usize, opt.ring_kib) * 1024;
    var log: Log = .{ .buffer = .init(gpa) };
    defer log.buffer.deinit();

    const stamp = try utcStamp(io);
    const git = try gitRev(gpa, io);
    defer gpa.free(git.hash);
    try log.print("velocitty benchmark v3\nutc {s}\ngit {s} status={s}\n", .{ stamp.iso, git.hash, git.status });
    try log.print("compiler Zig {s} optimize={s} target={s}-{s}-{s} cpu-target={s}\n", .{
        builtin.zig_version_string, @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), @tagName(builtin.abi), builtin.cpu.model.name,
    });
    try machineInfo(&log, gpa, io);
    try log.print("settings quick={} mib={d} burst={d}KiB grid={d}x{d} samples={d} only={s}\n", .{
        opt.quick, opt.mib, opt.burst_kib, opt.cols, opt.rows, opt.samples, opt.only orelse "all",
    });

    // Fonts: primary + main.zig fallbacks, cache/atlas sized like main.zig.
    var blobs: std.ArrayList(Font) = .empty;
    defer {
        for (blobs.items) |b| {
            gpa.free(b.bytes);
            gpa.free(b.path);
        }
        blobs.deinit(gpa);
    }
    try loadFonts(io, gpa, opt.font, &blobs);
    var ctx_store: Type.Context = try Type.Context.init(gpa, .{ .cache_capacity = cache_capacity });
    defer ctx_store.deinit();
    var env: Env = .{ .gpa = gpa, .io = io, .opt = opt, .ctx = null, .cell_w = 8, .cell_h = 16, .emoji = false };
    if (blobs.items.len != 0) {
        var fallbacks: std.ArrayList(Type.FontId) = .empty;
        defer fallbacks.deinit(gpa);
        for (blobs.items, 0..) |b, i| {
            const id = ctx_store.addFont(b.bytes, .{}) catch {
                try log.print("font {s}: unusable, skipped\n", .{b.path});
                continue;
            };
            if (i != 0) try fallbacks.append(gpa, id);
            if (ctx_store.faces.items[@intFromEnum(id)].font.color != null) env.emoji = true;
            try log.print("font {s} {s} bytes={d}\n", .{ if (i == 0) "primary " else "fallback", b.path, b.bytes.len });
        }
        if (ctx_store.primary != null) {
            try ctx_store.setFallbacks(fallbacks.items);
            const m = try ctx_store.metrics(size_px);
            const h = @ceil(m.ascender - m.descender + m.line_gap);
            const w = @ceil((try ctx_store.glyph('M', size_px)).advance);
            // Bad float-to-int is UB in ReleaseFast.
            if (!std.math.isFinite(w) or !std.math.isFinite(h) or w <= 0 or h <= 0 or w > 256 or h > 256) return error.InvalidFontMetrics;
            env.cell_w = @intFromFloat(w);
            env.cell_h = @intFromFloat(h);
            env.ctx = &ctx_store;
        }
    }
    if (env.ctx == null) try log.print("font NONE: placeholder render, glyph section skipped\n", .{});
    try log.print("size_px={d} cell={d}x{d} glyph-cache={d} atlas=1024x1024 ring={d}\n", .{ size_px, env.cell_w, env.cell_h, cache_capacity, ring_cap });
    try log.print("p50/p95 are nearest-rank over frames (pipeline/render) or 64-lookup batches (glyph).\n", .{});

    if (opt.spin) spinUp();
    // Workload names next to drain/firehose select those sections' workloads.
    const sections_only = opt.only != null and (wanted(opt, "drain") or wanted(opt, "firehose") or wanted(opt, "kitten"));
    for (workloads) |wl| {
        if (!wanted(opt, wl.name) or (sections_only and opt.only.?.len != 0 and !wanted(opt, "pipeline"))) continue;
        const bytes = try generate(gpa, wl, @as(usize, opt.mib) << 20);
        defer gpa.free(bytes);
        try runPipeline(&log, &env, wl, bytes);
    }
    if (wanted(opt, "drain")) {
        try log.print("\ndrain: {d} MiB/workload (4x --mib) from memory into the {d} KiB ring, drained at a quarter free; no PTY or render. fed = input bytes that reached the VT\n", .{ opt.mib * 4, ring_cap / 1024 });
        try log.print("  {s:<12} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8}\n", .{ "workload", "total ms", "scan", "vt", "scan ns/B", "vt ns/B", "fed" });
        var named = false;
        for (workloads) |wl| named = named or (opt.only != null and wanted(opt, wl.name));
        for (workloads) |wl| {
            if (named and !wanted(opt, wl.name)) continue;
            const bytes = try generate(gpa, wl, @as(usize, opt.mib) << 22);
            defer gpa.free(bytes);
            try runDrain(&log, &env, wl, bytes);
        }
    }
    if (wanted(opt, "firehose")) {
        try log.print("\nfirehose: {d} MiB/workload (16x --mib) through a PTY, read like main.zig (readSource {d} Hz, then consume+vt+render once); screen/images = final visible state equals a full parse\n", .{ opt.mib * 16, hz });
        try log.print("  {s:<12} {s:>8} {s:>8} {s:>8} {s:>8} {s:>7} {s:>9} {s:>5} {s:>6}\n", .{ "workload", "wall ms", "drain", "vt", "render", "frames", "MiB/s", "scrn", "images" });
        var named = false;
        for (workloads) |wl| named = named or (opt.only != null and wanted(opt, wl.name));
        for (workloads) |wl| {
            // `--only firehose,ascii` restricts the section to those workloads.
            if (named and !wanted(opt, wl.name)) continue;
            const bytes = try generate(gpa, wl, @as(usize, opt.mib) << 24);
            defer gpa.free(bytes);
            try runFirehose(&log, &env, wl, bytes);
        }
    }
    if (wanted(opt, "kitten")) try kittenSuite(&log, &env);
    if (wanted(opt, "image")) try imageSuite(&log, &env);
    if (env.ctx != null and wanted(opt, "glyph")) try glyphSuite(&log, &env);
    if (wanted(opt, "render")) {
        try renderSuite(&log, &env, opt.cols, opt.rows, opt.samples);
        const big_cols: u16 = @intCast(@max(2, 3840 / env.cell_w));
        const big_rows: u16 = @intCast(@max(2, 2160 / env.cell_h));
        try renderSuite(&log, &env, big_cols, big_rows, @max(10, opt.samples / 5));
    }
    try saveLog(io, &log, stamp.file, git.hash, std.mem.eql(u8, git.status, "dirty"));
}

fn dumpWorkloads(io: std.Io, gpa: std.mem.Allocator, opt: Options, dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir);
    for (workloads) |wl| {
        if (!wanted(opt, wl.name)) continue;
        const bytes = try generate(gpa, wl, @as(usize, opt.mib) << 20);
        defer gpa.free(bytes);
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&name_buf, "{s}/{s}.bin", .{ dir, wl.name });
        try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
        std.debug.print("wrote {s} ({d} bytes)\n", .{ path, bytes.len });
    }
    // kitten-<name>.bin: the `kitten` section's exact byte stream (--mib
    // repetitions), e.g. for `ghostty-bench +terminal-stream --data=FILE`.
    if (opt.only != null and wanted(opt, "kitten")) for (kitten_names) |name| {
        var g: Gen = .{ .gpa = gpa };
        defer g.out.deinit(gpa);
        try kittenData(&g, name);
        var stream: std.ArrayList(u8) = .empty;
        defer stream.deinit(gpa);
        try stream.appendSlice(gpa, "\x1b[?2026h");
        for (0..@max(1, opt.mib)) |_| {
            try stream.appendSlice(gpa, g.out.items);
            try stream.appendSlice(gpa, "\x1b[?2026l\x1b[?2026h");
        }
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&name_buf, "{s}/kitten-{s}.bin", .{ dir, name });
        try cwd.writeFile(io, .{ .sub_path = path, .data = stream.items });
        std.debug.print("wrote {s} ({d} bytes)\n", .{ path, stream.items.len });
    };
}

// ---------------------------------------------------------------- statistics

const Pct = struct { p50: f64, p95: f64, mean: f64, sum: f64 };

/// Nearest-rank percentiles. Sorts `values` in place.
fn percentiles(values: []u64) Pct {
    std.debug.assert(values.len != 0);
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    var sum: f64 = 0;
    for (values) |v| sum += @floatFromInt(v);
    return .{
        .p50 = @floatFromInt(values[rank(values.len, 50)]),
        .p95 = @floatFromInt(values[rank(values.len, 95)]),
        .mean = sum / @as(f64, @floatFromInt(values.len)),
        .sum = sum,
    };
}

fn rank(n: usize, p: usize) usize {
    return @max(1, (n * p + 99) / 100) - 1;
}

/// Busy 500 ms so frequency scaling ramps before the first section is timed.
fn spinUp() void {
    const end = nowNs() + 500 * std.time.ns_per_ms;
    var x: u64 = 1;
    while (nowNs() < end) {
        for (0..10_000) |_| x = x *% 6364136223846793005 +% 1442695040888963407;
        std.mem.doNotOptimizeAway(x);
    }
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------- workloads

const Workload = struct {
    name: []const u8,
    about: []const u8,
    unit: *const fn (*Gen) anyerror!void,
};

const workloads = [_]Workload{
    .{ .name = "ascii", .about = "printable lines 10..120 cols, CRLF", .unit = genAscii },
    .{ .name = "unicode", .about = "single-codepoint non-ASCII: Latin/Greek/Cyrillic/box/CJK/Hangul/emoji", .unit = genUnicode },
    .{ .name = "grapheme", .about = "multi-codepoint clusters: combining, ZWJ, flags, skin tones, VS16, Indic, jamo", .unit = genGrapheme },
    .{ .name = "csi-short", .about = "TUI redraw: CUP/EL/CUF + short SGR around 1..8 chars", .unit = genCsiShort },
    .{ .name = "long-escape", .about = "truecolor+underline SGR, OSC 8 long URLs, OSC 0/7/133, OSC 52 1-3 KiB", .unit = genLongEscape },
    .{ .name = "kitty-image", .about = "kitty APC a=T f=32 64x64 RGBA, 4096-byte base64 chunks, ids 1..16", .unit = genKitty },
    .{ .name = "sixel", .about = "DCS q 64x64, 8-color palette, RLE bands", .unit = genSixel },
    .{ .name = "pi", .about = "alt-screen TUI frames: sync, d=a, 2J, CUP rows, 256x256 PNG (stored deflate) a=T f=100 random i=", .unit = genPi },
};

const Gen = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    rng: u64 = 0x9E3779B97F4A7C15,
    n: u32 = 0,

    fn next(self: *Gen) u64 {
        // splitmix64: deterministic, no seed option.
        self.rng +%= 0x9E3779B97F4A7C15;
        var z = self.rng;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }
    fn below(self: *Gen, n: usize) usize {
        return @intCast(self.next() % n);
    }
    fn pick(self: *Gen, pool: []const []const u8) []const u8 {
        return pool[self.below(pool.len)];
    }
    fn put(self: *Gen, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
    }
    fn fmt(self: *Gen, comptime f: []const u8, args: anytype) !void {
        try self.out.print(self.gpa, f, args);
    }
    fn word(self: *Gen, len: usize) !void {
        const alpha = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./";
        for (0..len) |_| try self.out.append(self.gpa, alpha[self.below(alpha.len)]);
    }
};

fn generate(gpa: std.mem.Allocator, wl: Workload, target: usize) ![]u8 {
    var g: Gen = .{ .gpa = gpa };
    errdefer g.out.deinit(gpa);
    try g.out.ensureTotalCapacity(gpa, target + 64 * 1024);
    while (g.out.items.len < target) : (g.n += 1) try wl.unit(&g);
    return g.out.toOwnedSlice(gpa);
}

fn genAscii(g: *Gen) !void {
    const chars = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 (){}[];:,.<>=+-*/\"'#!?";
    const len = 10 + g.below(111);
    for (0..len) |_| try g.out.append(g.gpa, chars[g.below(chars.len)]);
    try g.put("\r\n");
}

const unicode_pool = [_][]const u8{
    "é", "ñ", "ü", "ß", "ø", "Ω", "λ", "π", "Ж", "я", "ש", "─", "│", "┌", "┘", "█", "░", "→", "✓", "★", "€", "©",
    "汉", "字", "測", "試", "日", "本", "語", "한", "글", "あ", "ア", "😀", "🚀", "🎉", "🔥", "✨",
};

fn genUnicode(g: *Gen) !void {
    const len = 10 + g.below(40);
    for (0..len) |_| {
        if (g.below(6) == 0) try g.put(" ") else try g.put(g.pick(&unicode_pool));
    }
    try g.put("\r\n");
}

const grapheme_pool = [_][]const u8{
    "e\u{301}",        "a\u{308}\u{323}", "n\u{303}",       "o\u{302}\u{301}",
    "Z\u{335}\u{336}\u{337}\u{338}\u{334}\u{33F}",
    "👨\u{200D}👩\u{200D}👧\u{200D}👦", "👩🏻\u{200D}💻", "🏳\u{FE0F}\u{200D}🌈",
    "👍🏽",               "🇵🇹",              "🇯🇵",              "❤\u{FE0F}",
    "1\u{FE0F}\u{20E3}", "क्षि",             "\u{1100}\u{1161}\u{11A8}", "ก\u{E34}\u{E48}",
};

fn genGrapheme(g: *Gen) !void {
    const len = 5 + g.below(25);
    for (0..len) |_| {
        try g.put(g.pick(&grapheme_pool));
        if (g.below(3) == 0) try g.put(" ");
    }
    try g.put("\r\n");
}

fn genCsiShort(g: *Gen) !void {
    const sgr = [_][]const u8{ "\x1b[0m", "\x1b[m", "\x1b[1m", "\x1b[7m", "\x1b[31m", "\x1b[32m", "\x1b[1;34m", "\x1b[39m", "\x1b[4m", "\x1b[22m" };
    const moves = [_][]const u8{ "\x1b[K", "\x1b[2C", "\x1b[A", "\x1b[B", "\x1b[3D", "\x1b[?25l", "\x1b[?25h", "\r\n" };
    try g.fmt("\x1b[{d};{d}H", .{ 1 + g.below(60), 1 + g.below(200) });
    const segs = 3 + g.below(10);
    for (0..segs) |_| {
        try g.put(g.pick(&sgr));
        try g.word(1 + g.below(8));
        if (g.below(3) == 0) try g.put(g.pick(&moves));
    }
}

fn genLongEscape(g: *Gen) !void {
    switch (g.below(10)) {
        0...3 => {
            const c = g.next();
            try g.fmt("\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d};1;3;4:3;58;2;{d};{d};{d}m", .{
                c & 255, (c >> 8) & 255, (c >> 16) & 255, (c >> 24) & 255, (c >> 32) & 255, (c >> 40) & 255, (c >> 48) & 255, (c >> 56) & 255, c & 127,
            });
            try g.word(5 + g.below(20));
            try g.put("\x1b[0m ");
        },
        4...5 => {
            try g.fmt("\x1b]8;id=l{d};https://example.com/", .{g.n});
            try g.word(150 + g.below(150));
            try g.put("\x1b\\");
            try g.word(8 + g.below(16));
            try g.put("\x1b]8;;\x1b\\ ");
        },
        6 => {
            try g.put("\x1b]0;");
            try g.word(60 + g.below(140));
            try g.put("\x07");
        },
        7 => {
            try g.put("\x1b]133;A\x07\x1b]7;file://host/home/user/");
            try g.word(40 + g.below(80));
            try g.put("\x1b\\\x1b]133;B\x07$ ");
            try g.word(10);
            try g.put("\x1b]133;C\x07\r\n\x1b]133;D;0\x07");
        },
        8 => {
            var raw: [3072]u8 = undefined;
            const n = 1024 + g.below(2048);
            for (raw[0..n]) |*b| b.* = @truncate(g.next());
            var enc: [4096]u8 = undefined;
            try g.put("\x1b]52;c;");
            try g.put(std.base64.standard.Encoder.encode(&enc, raw[0..n]));
            try g.put("\x07");
        },
        else => try g.put("\r\n"),
    }
}

fn genKitty(g: *Gen) !void {
    const side = 64;
    const id = 1 + g.n % 16;
    var rgba: [side * side * 4]u8 = undefined;
    for (0..side) |y| for (0..side) |x| {
        const p = (y * side + x) * 4;
        rgba[p..][0..4].* = .{ @intCast(x * 4), @intCast(y * 4), @truncate(id * 16), 255 };
    };
    var enc: [std.base64.standard.Encoder.calcSize(rgba.len)]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&enc, &rgba);
    var off: usize = 0;
    while (off < b64.len) {
        const end = @min(off + 4096, b64.len);
        const more: u8 = if (end < b64.len) 1 else 0;
        if (off == 0) {
            try g.fmt("\x1b_Ga=T,f=32,s={d},v={d},i={d},q=2,m={d};", .{ side, side, id, more });
        } else try g.fmt("\x1b_Gm={d};", .{more});
        try g.put(b64[off..end]);
        try g.put("\x1b\\");
        off = end;
    }
    try g.put("\r\n");
    for (0..4) |_| try genAscii(g);
}

fn genSixel(g: *Gen) !void {
    const side = 64;
    const seed = g.n % 8;
    try g.fmt("\x1bPq\"1;1;{d};{d}", .{ side, side });
    for (0..8) |c| try g.fmt("#{d};2;{d};{d};{d}", .{ c, (c * 37) % 101, (c * 53) % 101, (c * 71) % 101 });
    var band: usize = 0;
    while (band < side) : (band += 6) {
        for (0..8) |c| {
            try g.fmt("#{d}", .{c});
            var x: usize = 0;
            while (x < side) {
                const bits = sixelBits(band, x, c, seed);
                var run: usize = 1;
                while (x + run < side and sixelBits(band, x + run, c, seed) == bits) run += 1;
                const ch: u8 = '?' + @as(u8, bits);
                if (run > 3) try g.fmt("!{d}{c}", .{ run, ch }) else for (0..run) |_| try g.out.append(g.gpa, ch);
                x += run;
            }
            try g.put(if (c == 7) "-" else "$");
        }
    }
    try g.put("\x1b\\\r\n");
    for (0..4) |_| try genAscii(g);
}

/// One pi-style frame (pi 1.4 tui.ts full redraw): delete placements, clear,
/// then every row as CUP + EL + text, one row carrying a fresh chunked PNG.
fn genPi(g: *Gen) !void {
    const side = 256;
    if (g.n == 0) try g.put("\x1b[?1049h");
    try g.put("\x1b[?2026h\x1b_Ga=d,d=a,q=2\x1b\\\x1b[2J");
    const rows = 40;
    const img_row = 4 + g.n % 20;
    for (0..rows) |row| {
        try g.fmt("\x1b[{d};1H\x1b[2K", .{row + 1});
        if (row == img_row) {
            const png = try pngNoise(g, side, side);
            defer g.gpa.free(png);
            const enc = try g.gpa.alloc(u8, std.base64.standard.Encoder.calcSize(png.len));
            defer g.gpa.free(enc);
            const b64 = std.base64.standard.Encoder.encode(enc, png);
            const id: u32 = @truncate(g.next() | 1);
            var off: usize = 0;
            while (off < b64.len) {
                const end = @min(off + 4096, b64.len);
                const more: u8 = if (end < b64.len) 1 else 0;
                if (off == 0) {
                    try g.fmt("\x1b_Ga=T,f=100,q=2,C=1,c=30,r=15,i={d},m={d};", .{ id, more });
                } else try g.fmt("\x1b_Gm={d};", .{more});
                try g.put(b64[off..end]);
                try g.put("\x1b\\");
                off = end;
            }
        } else {
            try g.fmt("\x1b[38;5;{d}m frame {d} row {d} \x1b[0m", .{ (g.n + row) % 256, g.n, row });
        }
    }
    try g.put("\x1b[?25l\x1b[?2026l");
}

/// RGBA noise PNG with stored (uncompressed) deflate blocks, so the payload
/// size is predictable: ~side*side*4 bytes.
fn pngNoise(g: *Gen, w: u32, h: u32) ![]u8 {
    const gpa = g.gpa;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (0..h) |_| {
        try raw.append(gpa, 0);
        for (0..w) |_| {
            const v = g.next();
            try raw.appendSlice(gpa, &.{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16), 255 });
        }
    }
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var off: usize = 0;
    while (off < raw.items.len) {
        const n = @min(65535, raw.items.len - off);
        const final: u8 = @intFromBool(off + n == raw.items.len);
        const len: u16 = @intCast(n);
        try z.appendSlice(gpa, &.{ final, @truncate(len), @truncate(len >> 8), @truncate(~len), @truncate(~len >> 8) });
        try z.appendSlice(gpa, raw.items[off..][0..n]);
        off += n;
    }
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, std.hash.Adler32.hash(raw.items), .big);
    try z.appendSlice(gpa, &be);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try pngChunk(gpa, &out, "IHDR", &ihdr);
    try pngChunk(gpa, &out, "IDAT", z.items);
    try pngChunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn pngChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tag: *const [4]u8, data: []const u8) !void {
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, @intCast(data.len), .big);
    try out.appendSlice(gpa, &be);
    try out.appendSlice(gpa, tag);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(tag);
    crc.update(data);
    std.mem.writeInt(u32, &be, crc.final(), .big);
    try out.appendSlice(gpa, &be);
}

fn sixelBits(band: usize, x: usize, color: usize, seed: usize) u6 {
    var bits: u6 = 0;
    for (0..6) |dy| {
        const y = band + dy;
        if ((x / 8 + y / 8 + seed) % 8 == color) bits |= @as(u6, 1) << @intCast(dy);
    }
    return bits;
}

// ---------------------------------------------------------------- PTY pipeline

const Pty = struct {
    master: linux.fd_t,
    slave: linux.fd_t,

    /// /dev/ptmx + TIOCGPTPEER; slave raw (no ONLCR, no echo) so bytes arrive verbatim.
    fn open() !Pty {
        const m = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (linux.errno(m) != .SUCCESS) return error.PtyOpen;
        const master: linux.fd_t = @intCast(m);
        errdefer _ = linux.close(master);
        var unlock: c_int = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) return error.PtyOpen;
        const flags: linux.O = .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true };
        const s = linux.ioctl(master, linux.T.IOCGPTPEER, @as(u32, @bitCast(flags)));
        if (linux.errno(s) != .SUCCESS) return error.PtyOpen;
        const slave: linux.fd_t = @intCast(s);
        errdefer _ = linux.close(slave);
        // Raw syscalls: std.posix.tcsetattr trips a safety check in
        // ReleaseSafe builds of this harness.
        var t: linux.termios = undefined;
        if (linux.errno(linux.tcgetattr(slave, &t)) != .SUCCESS) return error.PtyOpen;
        t.iflag = .{};
        t.oflag = .{};
        t.lflag = .{};
        t.cflag.CSIZE = .CS8;
        t.cflag.PARENB = false;
        if (linux.errno(linux.tcsetattr(slave, .NOW, &t)) != .SUCCESS) return error.PtyOpen;
        return .{ .master = master, .slave = slave };
    }
};

fn writerMain(fd: linux.fd_t, bytes: []const u8, failed: *bool) void {
    var rest = bytes;
    while (rest.len != 0) {
        const rc = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(rc)) {
            .SUCCESS => rest = rest[rc..],
            .INTR, .AGAIN => {},
            else => {
                failed.* = true;
                return;
            },
        }
    }
}

const Stage = enum { io, scan, vt, render, present };
const stage_count = std.enums.values(Stage).len;

const Pipeline = struct {
    ring: CircBuffer,
    term: VtState,
    frame: Draw.Frame,
    present: []u32,

    fn init(env: *const Env, cols: u16, rows: u16) !Pipeline {
        var ring = try CircBuffer.create(env.gpa, ring_cap);
        errdefer ring.destroy();
        var term = try VtState.init(env.gpa, cols, rows, scrollback, ring.storage);
        errdefer term.deinit();
        var frame = try Draw.Frame.init(env.gpa, @as(u32, cols) * env.cell_w, @as(u32, rows) * env.cell_h);
        errdefer frame.deinit();
        const present = try env.gpa.alloc(u32, frame.pixels.len);
        @memset(present, 0);
        return .{ .ring = ring, .term = term, .frame = frame, .present = present };
    }

    fn deinit(self: *Pipeline, gpa: std.mem.Allocator) void {
        gpa.free(self.present);
        self.frame.deinit();
        self.term.deinit();
        self.ring.destroy();
    }

    /// main.zig Presenter: copy only the damaged rows to the window buffer.
    fn presentDamage(self: *Pipeline) void {
        if (!self.frame.damaged()) return;
        const y0: usize = if (self.frame.dirty_full) 0 else self.frame.dirty_y;
        const h: usize = if (self.frame.dirty_full) self.frame.height else self.frame.dirty_h;
        const w = self.frame.width;
        @memcpy(self.present[y0 * w ..][0 .. h * w], self.frame.pixels[y0 * w ..][0 .. h * w]);
        std.mem.doNotOptimizeAway(self.present);
    }

    /// What main.zig hands to the window between frames; not timed.
    fn drainHost(self: *Pipeline) void {
        const t = &self.term;
        t.reply.clearRetainingCapacity();
        t.title_dirty = false;
        t.app_id_dirty = false;
        t.pointer_dirty = false;
        t.notify_pending = false;
        t.clip_kind = 0;
        t.clip.clearRetainingCapacity();
    }
};

fn runPipeline(log: *Log, env: *Env, wl: Workload, bytes: []const u8) !void {
    const gpa = env.gpa;
    const opt = env.opt;
    const burst: usize = @as(usize, opt.burst_kib) * 1024;
    const frames = (bytes.len + burst - 1) / burst;
    const warm = @min(16, frames / 10);
    var p = try Pipeline.init(env, opt.cols, opt.rows);
    defer p.deinit(gpa);
    if (env.ctx) |c| c.clearAtlas();
    const misses0 = if (env.ctx) |c| c.stats.misses else 0;

    var stage_ns: [stage_count][]u64 = undefined;
    for (&stage_ns) |*s| s.* = try gpa.alloc(u64, frames);
    defer for (stage_ns) |s| gpa.free(s);
    const total_ns = try gpa.alloc(u64, frames);
    defer gpa.free(total_ns);
    var wait_ns: u64 = 0;
    var reads: u64 = 0;
    var runs: u64 = 0;

    const pty = try Pty.open();
    var write_failed = false;
    const writer = try std.Thread.spawn(.{}, writerMain, .{ pty.slave, bytes, &write_failed });
    // Closing the master first unblocks a writer stuck on a full PTY.
    defer {
        _ = linux.close(pty.master);
        writer.join();
        _ = linux.close(pty.slave);
    }

    const mask = p.ring.capacity - 1;
    var fed: usize = 0;
    for (0..frames) |f| {
        const want = @min(burst, bytes.len - fed);
        if (p.ring.head - p.ring.tail + want > p.ring.capacity) return error.RingOverrun;
        var io_ns: u64 = 0;
        var got: usize = 0;
        while (got < want) {
            const off: usize = @intCast(p.ring.head & mask);
            const t0 = nowNs();
            const rc = linux.read(pty.master, p.ring.storage[off..].ptr, want - got);
            const t1 = nowNs();
            io_ns += t1 - t0;
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.PtyEof;
                    if (!p.ring.mapped) mirror(&p.ring, off, rc);
                    p.ring.head += rc;
                    got += rc;
                    reads += 1;
                },
                .AGAIN => {
                    var pfd = [1]linux.pollfd{.{ .fd = pty.master, .events = linux.POLL.IN, .revents = 0 }};
                    const rc_poll = linux.poll(&pfd, 1, 5000);
                    wait_ns += nowNs() - t1;
                    if (rc_poll == 0 or write_failed) return error.PtyStalled;
                },
                .INTR => {},
                else => return error.PtyRead,
            }
        }
        fed += want;
        var timed = TimedSink{ .term = &p.term };
        const t0 = nowNs();
        p.ring.drain(timed.sink());
        const t2 = nowNs();
        // scan = drain minus the time spent feeding the VT.
        const t1 = t2 - timed.ns;
        runs += timed.runs;
        p.drainHost();
        const t3 = nowNs();
        p.term.prepareImages();
        p.frame.renderSel(&p.term, env.cell_w, env.cell_h, env.ctx, size_px, .{});
        p.term.clearDirty();
        const t4 = nowNs();
        p.presentDamage();
        const t5 = nowNs();
        const ns = [stage_count]u64{ io_ns, t1 - t0, t2 - t1, t4 - t3, t5 - t4 };
        total_ns[f] = 0;
        for (ns, 0..) |v, i| {
            stage_ns[i][f] = v;
            total_ns[f] += v;
        }
    }
    if (p.ring.head != p.ring.tail) return error.PipelineHeldBytes;

    const kept = frames - warm;
    try log.print("\npipeline {s}: {s}\n", .{ wl.name, wl.about });
    try log.print("  bytes={d} frames={d} (+{d} warm discarded) burst={d} B grid={d}x{d} reads/frame={d:.1} runs/frame={d:.0}\n", .{
        bytes.len - @min(bytes.len, warm * burst), kept, warm, burst, opt.cols, opt.rows,
        @as(f64, @floatFromInt(reads)) / @as(f64, @floatFromInt(frames)), @as(f64, @floatFromInt(runs)) / @as(f64, @floatFromInt(frames)),
    });
    try log.print("  {s:<8} {s:>10} {s:>10} {s:>10} {s:>7}\n", .{ "stage", "p50 us", "p95 us", "mean us", "share" });
    const total = percentiles(total_ns[warm..]);
    var share: [stage_count]f64 = undefined;
    for (std.enums.values(Stage), 0..) |stage, i| {
        const s = percentiles(stage_ns[i][warm..]);
        share[i] = s.sum / total.sum * 100;
        try log.print("  {s:<8} {d:>10.1} {d:>10.1} {d:>10.1} {d:>6.1}%\n", .{ @tagName(stage), s.p50 / 1000, s.p95 / 1000, s.mean / 1000, share[i] });
    }
    const kept_bytes: f64 = @floatFromInt(bytes.len - @min(bytes.len, warm * burst));
    try log.print("  {s:<8} {d:>10.1} {d:>10.1} {d:>10.1}  {d:.1} MiB/s\n", .{ "frame", total.p50 / 1000, total.p95 / 1000, total.mean / 1000, kept_bytes / (total.sum / 1e9) / (1024 * 1024) });
    try log.print("  split: io {d:.1}% | parse {d:.1}% (scan {d:.1} + vt {d:.1}) | render {d:.1}% (draw {d:.1} + copy {d:.1})\n", .{
        share[0], share[1] + share[2], share[1], share[2], share[3] + share[4], share[3], share[4],
    });
    const misses = if (env.ctx) |c| c.stats.misses - misses0 else 0;
    try log.print("  io-wait {d:.1} us/frame (excluded) glyph-misses={d} images={d} placements={d} checksum={x}\n", .{
        @as(f64, @floatFromInt(wait_ns)) / @as(f64, @floatFromInt(frames)) / 1000, misses, p.term.kitty.images.items.len, p.term.kitty.placements.items.len,
        hashTerm(&p.term) ^ hashBytes(std.mem.sliceAsBytes(p.frame.pixels)),
    });
}

/// Forwards a drain to the VT and records how long the VT took.
const TimedSink = struct {
    term: *VtState,
    ns: u64 = 0,
    runs: u64 = 0,
    /// Bytes covered by the fed runs.
    bytes: u64 = 0,
    /// From the drain's view() call to the end of its feed: the whole drain.
    drain_ns: u64 = 0,
    t_view: u64 = 0,

    fn sink(self: *TimedSink) Ring.Sink {
        return .{ .ctx = self, .feed = feed, .view = view };
    }
    fn feed(ctx: *anyopaque, runs: []const Run, spill: []const u8, owner: *CircBuffer) void {
        const self: *TimedSink = @ptrCast(@alignCast(ctx));
        const t0 = nowNs();
        self.term.feedOwned(runs, spill, owner);
        const t1 = nowNs();
        self.ns += t1 - t0;
        self.drain_ns += t1 - self.t_view;
        self.runs += runs.len;
        for (runs) |run| self.bytes += run.len;
    }
    fn view(ctx: *anyopaque) Ring.View {
        const self: *TimedSink = @ptrCast(@alignCast(ctx));
        self.t_view = nowNs();
        const s = self.term.sink();
        return s.view(s.ctx);
    }
};

// ---------------------------------------------------------------- drain

/// CPU-only drain cost: fill the ring the way readSource does (all free
/// space, drain at a quarter free) from memory. No PTY, no render.
fn runDrain(log: *Log, env: *Env, wl: Workload, bytes: []const u8) !void {
    const gpa = env.gpa;
    var ring = try CircBuffer.create(gpa, ring_cap);
    defer ring.destroy();
    var term = try VtState.init(gpa, env.opt.cols, env.opt.rows, scrollback, ring.storage);
    defer term.deinit();
    var timed = TimedSink{ .term = &term };
    var copy_ns: u64 = 0;
    const t_start = nowNs();
    var off: usize = 0;
    while (off < bytes.len) {
        const c0 = nowNs();
        const free: usize = @intCast(ring.capacity - (ring.head - ring.tail));
        const n = @min(free, bytes.len - off);
        const at: usize = @intCast(ring.head & (ring.capacity - 1));
        @memcpy(ring.storage[at..][0..n], bytes[off..][0..n]);
        if (!ring.mapped) mirror(&ring, at, n);
        ring.head += n;
        off += n;
        copy_ns += nowNs() - c0;
        if (ring.capacity - (ring.head - ring.tail) < ring.capacity / 4) ring.drain(timed.sink());
    }
    ring.drain(timed.sink());
    const total = nowNs() - t_start - copy_ns;
    const scan = total -| timed.ns;
    const nb: f64 = @floatFromInt(bytes.len);
    try log.print("  {s:<12} {d:>8.1} {d:>8.1} {d:>8.1} {d:>8.2} {d:>8.2} {d:>7.2}%\n", .{
        wl.name,
        @as(f64, @floatFromInt(total)) / 1e6,
        @as(f64, @floatFromInt(scan)) / 1e6,
        @as(f64, @floatFromInt(timed.ns)) / 1e6,
        @as(f64, @floatFromInt(scan)) / nb,
        @as(f64, @floatFromInt(timed.ns)) / nb,
        @as(f64, @floatFromInt(timed.bytes)) / nb * 100,
    });
}

// ---------------------------------------------------------------- +terminal-stream

const StreamOptions = struct {
    data: ?[:0]const u8 = null,
    rows: u16 = 80,
    cols: u16 = 120,
    drop: bool = false,
};

fn parseStreamOptions(args: []const [*:0]const u8) !StreamOptions {
    var opt: StreamOptions = .{};
    for (args) |raw| {
        const arg = std.mem.span(raw);
        if (std.mem.eql(u8, arg, "--drop")) {
            opt.drop = true;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.UnknownOption;
        const name = arg[0..eq];
        const value = arg[eq + 1 .. :0];
        if (std.mem.eql(u8, name, "--data")) {
            opt.data = value;
        } else if (std.mem.eql(u8, name, "--terminal-rows")) {
            opt.rows = @intCast(try count(value, 1, 1000));
        } else if (std.mem.eql(u8, name, "--terminal-cols")) {
            opt.cols = @intCast(try count(value, 1, 1000));
        } else return error.UnknownOption;
    }
    return opt;
}

/// `ghostty-bench +terminal-stream` counterpart: input to terminal state
/// through the same ring + drain + VT path as main.zig, nothing else.
fn terminalStream(args: []const [*:0]const u8) !void {
    const opt = parseStreamOptions(args) catch |err| {
        std.debug.print("bench: invalid arguments: {s}\n{s}", .{ @errorName(err), usage });
        return err;
    };
    const path = opt.data orelse return;
    const fd: linux.fd_t = if (std.mem.eql(u8, path, "-")) 0 else blk: {
        const rc = linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) {
            std.debug.print("bench: cannot open {s}\n", .{path});
            return error.OpenFailed;
        }
        break :blk @intCast(rc);
    };
    defer if (fd != 0) {
        _ = linux.close(fd);
    };
    const gpa = std.heap.c_allocator;
    var ring = try CircBuffer.create(gpa, default_ring_cap);
    defer ring.destroy();
    ring.exact = !opt.drop;
    var term = try VtState.init(gpa, opt.cols, opt.rows, scrollback, ring.storage);
    defer term.deinit();
    var stream = StreamSink{ .term = &term };
    const sink = stream.sink();
    // `readSource` like main.zig: ring reads, and straight into the spill
    // buffer while a string is open.
    while (true) {
        ring.readSource(StreamSource{ .fd = fd }, 1_000_000_000, null, sink) catch break;
    }
    ring.drain(sink);
    std.mem.doNotOptimizeAway(term.cursor());
}

/// Blocking file/pipe reads of at most 64 KiB, like Ghostty's IO thread and
/// this ring; end of input is a zero read (readSource's Hangup).
const StreamSource = struct {
    fd: linux.fd_t,

    pub fn read(self: StreamSource, dest: []u8) error{ ReadFailed, WouldBlock }!usize {
        while (true) {
            const rc = linux.read(self.fd, dest.ptr, @min(dest.len, 64 * 1024));
            switch (linux.errno(rc)) {
                .SUCCESS => return rc,
                .INTR => continue,
                else => return error.ReadFailed,
            }
        }
    }

    pub fn wait(self: StreamSource, event_fd: ?c_int, timeout_ms: c_int) void {
        _ = self;
        _ = event_fd;
        _ = timeout_ms;
    }
};

/// The VT as a sink that drops its replies after every drain.
const StreamSink = struct {
    term: *VtState,

    fn sink(self: *StreamSink) Ring.Sink {
        return .{ .ctx = self, .feed = feed, .view = view };
    }
    fn feed(ctx: *anyopaque, runs: []const Run, spill: []const u8, owner: *CircBuffer) void {
        const self: *StreamSink = @ptrCast(@alignCast(ctx));
        self.term.feedOwned(runs, spill, owner);
        self.term.reply.clearRetainingCapacity();
    }
    fn view(ctx: *anyopaque) Ring.View {
        const self: *StreamSink = @ptrCast(@alignCast(ctx));
        const s = self.term.sink();
        return s.view(s.ctx);
    }
};

/// A nonblocking in-memory source: `read` copies at most 64 KiB (like a
/// PTY) and counts the time spent copying, which timed rows subtract.
const MemSource = struct {
    data: []const u8,
    pos: usize = 0,
    copy_ns: u64 = 0,

    pub fn read(self: *MemSource, dest: []u8) error{ WouldBlock, Unused }!usize {
        if (self.pos >= self.data.len) return error.WouldBlock;
        const c0 = nowNs();
        const n = @min(@min(dest.len, 64 * 1024), self.data.len - self.pos);
        @memcpy(dest[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        self.copy_ns += nowNs() - c0;
        return n;
    }

    pub fn wait(self: *MemSource, event_fd: ?c_int, timeout_ms: c_int) void {
        _ = self;
        _ = event_fd;
        _ = timeout_ms;
    }
};

// ---------------------------------------------------------------- kitten

// The six `kitten __benchmark__` payloads (kitty tools/cmd/benchmark),
// parsed headless with every byte fed (`exact`), as in the Ghostty
// comparison. Throughput is bytes / time to drain them all.
const kitten_ascii = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ  `~!@#$%^&*()_+-=[]{}\\|;:'\",<.>/?";
const kitten_ctrl = "\n\t";
const kitten_cjk = "旦海司有幼雞讀松鼻種比門真目怪少：扒裝虎怕您跑綠蝶黃，位香法士錯乙音造活羽詞坡村目園尺封鳥朋；法松夕點我冬停雪因科對只貓息加黃住蝶，明鴨乾春呢風乙時昔孝助？小紅女父故去。飯躲裝個哥害共買去隻把氣年，己你校跟飛百拉！快石牙飽知唱想土人吹象毛吉每浪四又連見、欠耍外豆雞秋鼻。住步帶。打六申幾麼：或皮又荷隻乙犬孝習秋還何氣；幾裏活打能花是入海乙山節會。種第共後陽沒喜姐三拍弟海肖，行知走亮包，他字幾，的木卜流旦乙左杯根毛。您皮買身苦八手牛目地止哥彩第合麻讀午。原朋河乾種果「才波久住這香松」兄主衣快他玉坐要羽和亭但小山吉也吃耳怕，也爪斗斥可害朋許波怎祖葉卜。行花兩耍許車丟學「示想百吃門高事」不耳見室九星枝買裝，枝十新央發旁品丁青給，科房火；事出出孝肉古：北裝愛升幸百東鼻到從會故北「可休笑物勿三游細斗」娘蛋占犬。我羊波雨跳風。牛大燈兆新七馬，叫這牙後戶耳、荷北吃穿停植身玩間告或西丟再呢，他禾七愛干寺服石安：他次唱息它坐屋父見這衣發現來，苗會開條弓世者吃英定豆哭；跳風掃叫美神。寸再了耍休壯植己，燈錯和，蝶幾欠雞定和愛，司紅後弓第樹會金拉快喝夕見往，半瓜日邊出讀雞苦歌許開；發火院爸乙；四帶亮錯鳥洋個讀。";
const kitten_misc = "‘’“”‹›«»‚„ 😀😛😇😈😉😍😎😮👍👎 —–§¶†‡©®™ →⇒•·°±−×÷¼½½¾…µ¢£€¿¡¨´¸ˆ˜ ÀÁÂÃÄÅÆÇÈÉÊË ÌÍÎÏÐÑÒÓÔÕÖØ ŒŠÙÚÛÜÝŸÞßàá âãäåæçèéêëìíîïðñòóôõöøœš ùúûüýÿþªºαΩ∞ ū̀n̂o᷵H̨a̠b̡͓̐c̡͓̐X̡͓̐";

fn kittenRandom(g: *Gen, n: usize, alphabet: []const u8) !void {
    for (0..n) |_| try g.out.append(g.gpa, alphabet[g.below(alphabet.len)]);
}

fn kittenData(g: *Gen, name: []const u8) !void {
    const all = kitten_ascii ++ kitten_ctrl;
    if (std.mem.eql(u8, name, "ascii")) {
        try kittenRandom(g, 1024 * 2048 + 13, all);
    } else if (std.mem.eql(u8, name, "unicode")) {
        for (0..1024) |_| try g.put(kitten_cjk ++ kitten_misc ++ kitten_ctrl);
    } else if (std.mem.eql(u8, name, "unique_unicode")) {
        var buf: [4]u8 = undefined;
        for (0..256 * 1024) |q| {
            try g.out.append(g.gpa, 'a');
            var v = q;
            for (0..3) |_| {
                const n = std.unicode.utf8Encode(@intCast(0x300 + v % 0x70), &buf) catch unreachable;
                try g.put(buf[0..n]);
                v /= 0x70;
            }
        }
    } else if (std.mem.eql(u8, name, "csi")) {
        const start = g.out.items.len;
        while (g.out.items.len - start < 1024 * 1024 + 17) {
            const q = g.below(100);
            if (q < 10) {
                try kittenRandom(g, g.below(72) + 1, all);
            } else try g.put(if (q < 30) "\x1b[m\x1b[?1h\x1b[H" else if (q < 40) "\x1b[1;2;3;4:3;31m" else if (q < 50) "\x1b[38:5:24;48:2:125:136:147m" else if (q < 60) "\x1b[58;5;44;2m" else if (q < 80) "\x1b[m\x1b[10A\x1b[3E\x1b[2K" else "\x1b[39m\x1b[10`a\x1b[100b\x1b[?1l");
        }
        try g.put("\x1b[m");
    } else if (std.mem.eql(u8, name, "long_escape_codes")) {
        const s0 = g.out.items.len;
        try kittenRandom(g, 8024, kitten_ascii);
        const body = try g.gpa.dupe(u8, g.out.items[s0..]);
        defer g.gpa.free(body);
        g.out.shrinkRetainingCapacity(s0);
        for (0..1024) |_| {
            try g.put("\x1b]6;");
            try g.put(body);
            try g.put("\x07");
        }
    } else if (std.mem.eql(u8, name, "images")) {
        // 1024x1024 RGBA zeros, raw base64 in 128 KiB chunks, then d=I.
        const raw = try g.gpa.alloc(u8, 4 * 1024 * 1024);
        defer g.gpa.free(raw);
        @memset(raw, 0);
        const enc = std.base64.standard_no_pad.Encoder;
        const b64 = try g.gpa.alloc(u8, enc.calcSize(raw.len));
        defer g.gpa.free(b64);
        _ = enc.encode(b64, raw);
        var off: usize = 0;
        while (off < b64.len) {
            const end = @min(off + 128 * 1024, b64.len);
            const more: u8 = @intFromBool(end < b64.len);
            if (off == 0) {
                try g.fmt("\x1b_Gq=2,m={d},s=1024,v=1024,i=12345;", .{more});
            } else try g.fmt("\x1b_Gq=2,m={d};", .{more});
            try g.put(b64[off..end]);
            try g.put("\x1b\\");
            off = end;
        }
        try g.put("\x1b_Ga=d,q=2,d=I,i=12345\x1b\\");
    } else if (std.mem.eql(u8, name, "single_image")) {
        // 3840x2160 RGBA zeros as ONE APC string (no m=1 chunks, ~44 MB of
        // base64, far larger than the ring), transmitted only, then d=I.
        const raw = try g.gpa.alloc(u8, 4 * 3840 * 2160);
        defer g.gpa.free(raw);
        @memset(raw, 0);
        const enc = std.base64.standard.Encoder;
        const b64 = try g.gpa.alloc(u8, enc.calcSize(raw.len));
        defer g.gpa.free(b64);
        _ = enc.encode(b64, raw);
        try g.put("\x1b_Gq=2,f=32,s=3840,v=2160,i=12346;");
        try g.put(b64);
        try g.put("\x1b\\");
        try g.put("\x1b_Ga=d,q=2,d=I,i=12346\x1b\\");
    } else unreachable;
}

const kitten_names = [_][]const u8{ "ascii", "unicode", "unique_unicode", "csi", "images", "long_escape_codes", "single_image" };

fn kittenSuite(log: *Log, env: *Env) !void {
    const gpa = env.gpa;
    const reps: usize = @max(1, env.opt.mib);
    try log.print("\nkitten: kitty `kitten __benchmark__` payloads x{d} (--mib), headless 120x80, exact (every byte parsed), synchronized output on; MB = 2^20 bytes\n", .{reps});
    try log.print("  {s:<18} {s:>9} {s:>9} {s:>10}\n", .{ "benchmark", "MiB", "ms", "MB/s" });
    var named = false;
    for (kitten_names) |name| named = named or (env.opt.only != null and wanted(env.opt, name));
    for (kitten_names) |name| {
        if (named and !wanted(env.opt, name)) continue;
        var g: Gen = .{ .gpa = gpa };
        defer g.out.deinit(gpa);
        try kittenData(&g, name);
        const unit = try gpa.dupe(u8, g.out.items);
        defer gpa.free(unit);
        var ring = try CircBuffer.create(gpa, ring_cap);
        defer ring.destroy();
        ring.exact = true;
        var term = try VtState.init(gpa, 120, 80, scrollback, ring.storage);
        defer term.deinit();
        const sink = term.sink();
        var copy_ns: u64 = 0;
        var total: usize = 0;
        const t0 = nowNs();
        for (0..reps) |rep| {
            const pieces = [_][]const u8{ if (rep == 0) "\x1b[?2026h" else "", unit, "\x1b[?2026l\x1b[?2026h" };
            for (pieces) |piece| {
                // readSource like main.zig: ring reads, then straight into the
                // spill buffer while a string is open. The copy stands in for
                // read(2) and is not timed.
                var src = MemSource{ .data = piece };
                while (src.pos < piece.len) ring.readSource(&src, 1_000_000_000, null, sink) catch unreachable;
                copy_ns += src.copy_ns;
                total += piece.len;
            }
            term.reply.clearRetainingCapacity();
        }
        ring.drain(sink);
        const ns = nowNs() - t0 - copy_ns;
        const mib = @as(f64, @floatFromInt(total)) / (1024 * 1024);
        try log.print("  {s:<18} {d:>9.1} {d:>9.1} {d:>10.1}\n", .{ name, mib, @as(f64, @floatFromInt(ns)) / 1e6, mib / (@as(f64, @floatFromInt(ns)) / 1e9) });
    }
}

// ---------------------------------------------------------------- image

/// One large PNG sent like pi (a=T,f=100, 4096-byte base64 chunks, scaled
/// to the grid): transfer (drain + vt), decode on first draw, first frame,
/// steady frames with the image on screen, and a frame after scrolling.
fn imageSuite(log: *Log, env: *Env) !void {
    const gpa = env.gpa;
    const opt = env.opt;
    const png = if (opt.image) |path| try loadFile(env.io, gpa, path) else blk: {
        var g: Gen = .{ .gpa = gpa };
        defer g.out.deinit(gpa);
        break :blk try pngNoise(&g, 1920, 1080);
    };
    defer gpa.free(png);
    const enc = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(png.len));
    defer gpa.free(enc);
    const b64 = std.base64.standard.Encoder.encode(enc, png);
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    var off: usize = 0;
    while (off < b64.len) {
        const end = @min(off + 4096, b64.len);
        const more: u8 = @intFromBool(end < b64.len);
        if (off == 0) {
            try stream.print(gpa, "\x1b[H\x1b_Ga=T,f=100,q=2,C=1,c={d},r={d},i=77,m={d};", .{ opt.cols, opt.rows - 1, more });
        } else try stream.print(gpa, "\x1b_Gm={d};", .{more});
        try stream.appendSlice(gpa, b64[off..end]);
        try stream.appendSlice(gpa, "\x1b\\");
        off = end;
    }

    var p = try Pipeline.init(env, opt.cols, opt.rows);
    defer p.deinit(gpa);
    const t0 = nowNs();
    off = 0;
    while (off < stream.items.len) {
        const free: usize = @intCast(p.ring.capacity - (p.ring.head - p.ring.tail));
        const n = @min(free, stream.items.len - off);
        const at: usize = @intCast(p.ring.head & (p.ring.capacity - 1));
        @memcpy(p.ring.storage[at..][0..n], stream.items[off..][0..n]);
        if (!p.ring.mapped) mirror(&p.ring, at, n);
        p.ring.head += n;
        off += n;
        if (p.ring.capacity - (p.ring.head - p.ring.tail) < p.ring.capacity / 4) p.ring.drain(p.term.sink());
    }
    p.ring.drain(p.term.sink());
    const t1 = nowNs();
    p.term.prepareImages();
    const t2 = nowNs();
    p.frame.renderSel(&p.term, env.cell_w, env.cell_h, env.ctx, size_px, .{});
    p.term.clearDirty();
    const t3 = nowNs();
    const img = p.term.kitty.find(77) orelse return error.ImageDropped;
    const steady = try gpa.alloc(u64, 20);
    defer gpa.free(steady);
    for (steady) |*v| {
        // A one-cell change, as a cursor blink or a typed key would make.
        p.term.printCodepoint('x');
        const a = nowNs();
        p.term.prepareImages();
        p.frame.renderSel(&p.term, env.cell_w, env.cell_h, env.ctx, size_px, .{});
        p.term.clearDirty();
        v.* = nowNs() - a;
    }
    const st = percentiles(steady);
    const mib = @as(f64, @floatFromInt(png.len)) / (1024 * 1024);
    try log.print("\nimage: {d}x{d} PNG {d:.1} MiB ({d:.1} MiB base64) as pi sends it, scaled to {d}x{d} cells ({d}x{d} px)\n", .{
        img.width, img.height, mib, @as(f64, @floatFromInt(b64.len)) / (1024 * 1024), opt.cols, opt.rows - 1, p.frame.width, p.frame.height,
    });
    try log.print("  transfer (drain+vt) {d:.2} ms  {d:.0} MiB/s\n", .{ @as(f64, @floatFromInt(t1 - t0)) / 1e6, @as(f64, @floatFromInt(stream.items.len)) / (1024 * 1024) / (@as(f64, @floatFromInt(t1 - t0)) / 1e9) });
    try log.print("  decode (first draw) {d:.2} ms\n", .{@as(f64, @floatFromInt(t2 - t1)) / 1e6});
    try log.print("  first frame         {d:.2} ms\n", .{@as(f64, @floatFromInt(t3 - t2)) / 1e6});
    try log.print("  steady frame        p50 {d:.2} ms  p95 {d:.2} ms (one cell changes)\n", .{ st.p50 / 1e6, st.p95 / 1e6 });
}

// ---------------------------------------------------------------- firehose

/// What main.zig does under sustained output: `readSource` greedily until
/// EAGAIN + 1/hz (or EOF), then consume, feed and render once. The final
/// visible screen and image placements are compared with a reference that
/// parses every byte.
fn runFirehose(log: *Log, env: *Env, wl: Workload, bytes: []const u8) !void {
    const gpa = env.gpa;
    const opt = env.opt;
    const want = try referenceState(env, bytes);

    var p = try Pipeline.init(env, opt.cols, opt.rows);
    defer p.deinit(gpa);
    const pty = try Pty.open();
    var write_failed = false;
    const writer = try std.Thread.spawn(.{}, writerMain, .{ pty.slave, bytes, &write_failed });
    // The slave stays open until the end: Linux may drop unread master data
    // on slave hangup. The reader stops once every byte has arrived.
    defer {
        _ = linux.close(pty.master);
        writer.join();
        _ = linux.close(pty.slave);
    }

    var frames: u64 = 0;
    var render_ns: u64 = 0;
    var timed = TimedSink{ .term = &p.term };
    const t_start = nowNs();
    var last_head: u64 = 0;
    var last_progress = t_start;
    var done = false;
    while (!done) {
        p.ring.readSource(FirehoseSource{ .fd = pty.master }, hz, null, timed.sink()) catch return error.PtyRead;
        if (write_failed) return error.PtyWrite;
        done = p.ring.head >= bytes.len;
        if (p.ring.head != last_head) {
            last_head = p.ring.head;
            last_progress = nowNs();
        } else if (!done and nowNs() - last_progress > 3 * std.time.ns_per_s) {
            std.debug.print("firehose stalled: head={d} tail={d} len={d} hold={d} open={} write_failed={}\n", .{ p.ring.head, p.ring.tail, bytes.len, p.ring.hold_at_head, p.ring.open != null, write_failed });
            return error.PtyStalled;
        }
        p.ring.drain(timed.sink());
        p.drainHost();
        const t1 = nowNs();
        p.term.prepareImages();
        p.frame.renderSel(&p.term, env.cell_w, env.cell_h, env.ctx, size_px, .{});
        p.term.clearDirty();
        p.presentDamage();
        const t2 = nowNs();
        render_ns += t2 - t1;
        frames += 1;
    }
    const wall = nowNs() - t_start;
    if (write_failed) return error.PtyWrite;
    const got = visibleState(&p.term);
    const mib = @as(f64, @floatFromInt(bytes.len)) / (1024 * 1024);
    try log.print("  {s:<12} {d:>8.1} {d:>8.1} {d:>8.1} {d:>8.1} {d:>7} {d:>9.1} {s:>5} {s:>6}\n", .{
        wl.name, @as(f64, @floatFromInt(wall)) / 1e6, @as(f64, @floatFromInt(timed.drain_ns)) / 1e6, @as(f64, @floatFromInt(timed.ns)) / 1e6, @as(f64, @floatFromInt(render_ns)) / 1e6,
        frames, mib / (@as(f64, @floatFromInt(wall)) / 1e9), if (got.screen == want.screen) "yes" else "NO", if (got.images == want.images) "yes" else "NO",
    });
}

const hz = 60;

const FirehoseSource = struct {
    fd: linux.fd_t,
    pub fn read(self: FirehoseSource, dest: []u8) !usize {
        return posix.read(self.fd, dest);
    }
    pub fn wait(self: FirehoseSource, event_fd: ?c_int, timeout_ms: c_int) void {
        _ = event_fd;
        var pfd = [1]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&pfd, 1, timeout_ms);
    }
};

const Visible = struct { screen: u64, images: u64 };

/// Visible cells + cursor, and visible placements by position and size
/// (ids are not compared: sixel ids depend on how many were decoded).
fn visibleState(term: *const VtState) Visible {
    var h: u64 = 0;
    const base = term.imageBase();
    const which: u1 = if (term.altScreen()) 1 else 0;
    for (term.kitty.placements.items) |pl| {
        if (pl.screen != which) continue;
        const row = pl.row - base;
        const span: i64 = @max(1, pl.rows);
        if (row + span <= 0 or row >= term.rows) continue;
        const img = term.kitty.find(pl.image_id) orelse continue;
        var key = [_]u64{ @bitCast(row), @bitCast(@as(i64, pl.col)), pl.columns, pl.rows, img.width, img.height };
        h = (h *% 0x100000001b3) ^ hashBytes(std.mem.sliceAsBytes(&key));
    }
    return .{ .screen = hashTerm(term) ^ (@as(u64, which) << 63), .images = h };
}

fn referenceState(env: *const Env, bytes: []const u8) !Visible {
    const cap = std.math.ceilPowerOfTwo(usize, bytes.len + 1) catch return error.TooLarge;
    var ring = try CircBuffer.create(env.gpa, cap);
    defer ring.destroy();
    var term = try VtState.init(env.gpa, env.opt.cols, env.opt.rows, scrollback, ring.storage);
    defer term.deinit();
    @memcpy(ring.storage[0..bytes.len], bytes);
    if (!ring.mapped) mirror(&ring, 0, bytes.len);
    ring.head = bytes.len;
    ring.exact = true;
    ring.drain(term.sink());
    return visibleState(&term);
}

// Same as CircBuffer.syncMirror for the unmapped fallback.
fn mirror(ring: *CircBuffer, off: usize, n: usize) void {
    const cap = ring.capacity;
    const a = ring.storage;
    const first = @min(n, cap - off);
    @memcpy(a[off + cap ..][0..first], a[off..][0..first]);
    const rest = n - first;
    @memcpy(a[0..rest], a[cap..][0..rest]);
}

// ---------------------------------------------------------------- glyph cache

const batch = 64;

fn glyphSuite(log: *Log, env: *Env) !void {
    const ctx = env.ctx.?;
    const gpa = env.gpa;
    const samples = env.opt.samples;
    try log.print("\nglyph cache: ns/lookup over {d}-lookup batches, {d} batches/row; LRU capacity {d}\n", .{ batch, samples, cache_capacity });

    // Distinct drawable glyphs: Latin-ext/Greek/Cyrillic/box/arrows, then CJK.
    var small: std.ArrayList(u21) = .empty;
    defer small.deinit(gpa);
    var cjk: std.ArrayList(u21) = .empty;
    defer cjk.deinit(gpa);
    try collect(ctx, gpa, &small, &.{ .{ 0x100, 0x250 }, .{ 0x370, 0x400 }, .{ 0x400, 0x500 }, .{ 0x2190, 0x2200 }, .{ 0x2500, 0x2580 } }, 1024);
    try collect(ctx, gpa, &cjk, &.{.{ 0x4E00, 0x9FFF }}, 8192);
    var emoji: std.ArrayList(u21) = .empty;
    defer emoji.deinit(gpa);
    if (env.emoji) try collect(ctx, gpa, &emoji, &.{ .{ 0x1F600, 0x1F650 }, .{ 0x1F680, 0x1F6C6 }, .{ 0x1F300, 0x1F3F0 } }, 256);
    try log.print("  pools: small={d} cjk={d} color-emoji={d} (distinct drawable glyphs)\n", .{ small.items.len, cjk.items.len, emoji.items.len });
    try log.print("  {s:<38} {s:>9} {s:>9} {s:>9} {s:>7} {s:>7}\n", .{ "case", "p50 ns", "p95 ns", "mean ns", "hit%", "resets" });

    var ascii: [95]u21 = undefined;
    for (&ascii, 0..) |*c, i| c.* = @intCast(32 + i);
    try glyphRow(log, env, "glyph() ASCII table", &ascii, .hit_glyph);
    if (small.items.len >= batch) {
        const hot = small.items[0..@min(256, small.items.len)];
        try glyphRow(log, env, "glyph() hit, 256 non-ASCII", hot, .hit_glyph);
        try glyphRow(log, env, "peekGlyph() hit (render path)", hot, .hit_peek);
        try glyphRow(log, env, "miss: raster+pack Latin/Greek/box", small.items, .miss);
    }
    if (cjk.items.len >= 256) {
        // Fallback-font glyphs: resolve() walks cmaps before the cache key exists.
        try glyphRow(log, env, "glyph() hit, 256 CJK (fallback face)", cjk.items[0..256], .hit_glyph);
        try glyphRow(log, env, "peekGlyph() hit, 256 CJK", cjk.items[0..256], .hit_peek);
        try glyphRow(log, env, "miss: raster+pack CJK", cjk.items, .miss);
    }
    if (emoji.items.len >= batch) {
        try glyphRow(log, env, "miss: color emoji (CBDT decode+scale)", emoji.items, .miss);
        try glyphRow(log, env, "glyph() hit, color emoji", emoji.items[0..batch], .hit_glyph);
    }

    // Working-set sweep around the LRU capacity, uniform random access.
    if (cjk.items.len >= 2 * cache_capacity) {
        const sets = [_]u32{ cache_capacity / 2, cache_capacity * 9 / 10, cache_capacity * 11 / 10, cache_capacity * 2 };
        for (sets) |ws| {
            var name_buf: [64]u8 = undefined;
            try glyphRow(log, env, try std.fmt.bufPrint(&name_buf, "uniform working set {d}", .{ws}), cjk.items[0..ws], .uniform);
        }
        try retention(log, env, cjk.items);
    } else try log.print("  working-set sweep SKIPPED: needs {d} CJK glyphs (Noto Sans CJK)\n", .{2 * cache_capacity});
    ctx.clearAtlas();
}

/// Does a hot set survive a stream of new glyphs (scrolling CJK text)?
/// A true LRU keeps all 64 hot glyphs (each is touched every 4 lookups);
/// a cache whose hits do not refresh recency evicts them every `capacity` inserts.
fn retention(log: *Log, env: *Env, pool: []const u21) !void {
    const ctx = env.ctx.?;
    const hot = pool[0..64];
    const cold = pool[64..];
    // 1.25x capacity: enough to cycle the LRU, small enough that the atlas
    // does not fill (a full atlas resets every cache and hides eviction policy).
    const stream = cache_capacity + cache_capacity / 4;
    ctx.clearAtlas();
    for (hot) |cp| _ = try ctx.glyph(cp, size_px);
    var hot_lookups: u64 = 0;
    var hot_misses: u64 = 0;
    var resets: u32 = 0;
    var shelf = ctx.atlas.shelf_y;
    for (0..stream) |i| {
        _ = try ctx.glyph(cold[i % cold.len], size_px);
        if (ctx.atlas.shelf_y < shelf) resets += 1;
        shelf = ctx.atlas.shelf_y;
        if (i % 3 != 2) continue;
        const before = ctx.stats.misses;
        _ = try ctx.glyph(hot[hot_lookups % hot.len], size_px);
        hot_misses += ctx.stats.misses - before;
        hot_lookups += 1;
    }
    try log.print("  hot-64 retention, {d} new glyphs, 3 new : 1 hot -> hot hit {d:.1}% ({d} hot misses, {d} atlas resets; LRU ideal 100%)\n", .{
        stream, 100 * (1 - @as(f64, @floatFromInt(hot_misses)) / @as(f64, @floatFromInt(hot_lookups))), hot_misses, resets,
    });
}

fn collect(ctx: *Type.Context, gpa: std.mem.Allocator, out: *std.ArrayList(u21), ranges: []const [2]u21, max: usize) !void {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    ctx.clearAtlas();
    for (ranges) |r| {
        var cp = r[0];
        while (cp < r[1] and out.items.len < max) : (cp += 1) {
            const g = ctx.glyph(cp, size_px) catch continue;
            if (g.glyph_id == 0 or g.width == 0) continue;
            const key = (@as(u64, @intFromEnum(g.font_id)) << 32) | g.glyph_id;
            if ((try seen.getOrPut(gpa, key)).found_existing) continue;
            try out.append(gpa, cp);
        }
    }
    ctx.clearAtlas();
}

const GlyphCase = enum { hit_glyph, hit_peek, miss, uniform };

fn glyphRow(log: *Log, env: *Env, name: []const u8, pool: []const u21, case: GlyphCase) !void {
    const ctx = env.ctx.?;
    const samples = env.opt.samples;
    const ns = try env.gpa.alloc(u64, samples);
    defer env.gpa.free(ns);
    var rng: Gen = .{ .gpa = env.gpa };
    var cursor: usize = 0;
    var lookups: u64 = 0;
    var misses: u64 = 0;
    var resets: u32 = 0;
    var acc: u64 = 0;
    ctx.clearAtlas();
    // Prefill so hits measure a warm cache; sweeps start from a full working set.
    if (case != .miss) for (pool) |cp| {
        _ = try ctx.glyph(cp, size_px);
    };
    var codes: [batch]u21 = undefined;
    var warm: u32 = 3;
    var s: u32 = 0;
    while (s < samples) {
        for (&codes, 0..) |*c, i| c.* = switch (case) {
            .hit_glyph, .hit_peek, .miss => pool[(cursor + i) % pool.len],
            .uniform => pool[rng.below(pool.len)],
        };
        if (case == .miss) {
            // Fresh atlas per batch; ASCII re-warm is outside the timer.
            ctx.clearAtlas();
            cursor = (cursor + batch) % pool.len;
        } else if (case != .uniform) cursor = (cursor + batch) % pool.len;
        const before = ctx.stats.misses;
        const shelf = ctx.atlas.shelf_y;
        const t0 = nowNs();
        for (codes) |cp| {
            const g = if (case == .hit_peek) ctx.peekGlyph(cp, size_px) orelse return error.CacheNotWarm else try ctx.glyph(cp, size_px);
            acc +%= g.glyph_id;
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(acc);
        if (ctx.atlas.shelf_y < shelf) resets += 1;
        if (warm > 0) {
            warm -= 1;
            continue;
        }
        ns[s] = t1 - t0;
        lookups += batch;
        misses += ctx.stats.misses - before;
        s += 1;
    }
    const p = percentiles(ns);
    const hit = 100 * (1 - @as(f64, @floatFromInt(misses)) / @as(f64, @floatFromInt(lookups)));
    try log.print("  {s:<38} {d:>9.1} {d:>9.1} {d:>9.1} {d:>6.1}% {d:>7}\n", .{ name, p.p50 / batch, p.p95 / batch, p.mean / batch, hit, resets });
}

// ---------------------------------------------------------------- render

const RenderCase = enum { full, skip, single, line, cursor, selection, scroll, resize };

fn renderSuite(log: *Log, env: *Env, cols: u16, rows: u16, samples: u32) !void {
    var p = try Pipeline.init(env, cols, rows);
    defer p.deinit(env.gpa);
    try log.print("\nrender {d}x{d} ({d}x{d} px), {d} frames/row; mutation untimed except resize\n", .{ cols, rows, p.frame.width, p.frame.height, samples });
    try log.print("  {s:<24} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{ "case", "p50 us", "p95 us", "mean us", "rows/frame" });
    const ns = try env.gpa.alloc(u64, samples);
    defer env.gpa.free(ns);
    for (std.enums.values(RenderCase)) |case| {
        try p.term.resize(cols, rows);
        try p.frame.resize(@as(u32, cols) * env.cell_w, @as(u32, rows) * env.cell_h);
        fillScreen(&p.term);
        p.term.flags.cursor_visible = case == .cursor;
        p.frame.invalidate();
        p.frame.render(&p.term, env.cell_w, env.cell_h, env.ctx, size_px);
        p.term.clearDirty();
        var sel: Select.State = .{};
        var damage: u64 = 0;
        for (0..samples + 2) |i| {
            const cp: u21 = if (i % 2 == 0) '#' else '@';
            const row = rows / 2;
            switch (case) {
                .full => {
                    p.frame.invalidate();
                    p.term.markDirtyAll();
                },
                .skip => {},
                .single, .line => {
                    p.term.grid().cursor = .{ .row = row, .col = 0 };
                    p.term.grid().wrap_pending = false;
                    const n: u16 = if (case == .single) 1 else cols;
                    for (0..n) |_| p.term.printCodepoint(cp);
                },
                .cursor => {
                    p.term.grid().cursor = .{ .row = row, .col = @intCast(i % cols) };
                    p.term.grid().wrap_pending = false;
                },
                .selection => {
                    sel.begin(0, row);
                    sel.extend(@intCast(1 + i % (cols - 1)), row + 1);
                },
                .scroll => {
                    p.term.grid().cursor = .{ .row = rows - 1, .col = 0 };
                    p.term.grid().wrap_pending = false;
                    p.term.index();
                    p.term.printCodepoint(cp);
                },
                .resize => {},
            }
            const t0 = nowNs();
            if (case == .resize) {
                const c = cols + @as(u16, @intCast(1 - i % 2));
                try p.term.resize(c, rows);
                try p.frame.resize(@as(u32, c) * env.cell_w, @as(u32, rows) * env.cell_h);
            }
            p.frame.renderSel(&p.term, env.cell_w, env.cell_h, env.ctx, size_px, sel);
            const t1 = nowNs();
            std.mem.doNotOptimizeAway(p.frame.pixels);
            if ((case == .skip) == p.frame.damaged()) return error.UnexpectedDamage;
            p.term.clearDirty();
            if (i < 2) continue; // warm
            ns[i - 2] = t1 - t0;
            damage += if (p.frame.dirty_full) p.frame.height else p.frame.dirty_h;
        }
        const s = percentiles(ns);
        try log.print("  {s:<24} {d:>10.1} {d:>10.1} {d:>10.1} {d:>10.0}\n", .{ @tagName(case), s.p50 / 1000, s.p95 / 1000, s.mean / 1000, @as(f64, @floatFromInt(damage)) / @as(f64, @floatFromInt(samples)) });
    }
    try p.term.resize(cols, rows);
    try p.frame.resize(@as(u32, cols) * env.cell_w, @as(u32, rows) * env.cell_h);
    for (0..samples) |i| {
        const t0 = nowNs();
        @memcpy(p.present, p.frame.pixels);
        std.mem.doNotOptimizeAway(p.present);
        ns[i] = nowNs() - t0;
    }
    const s = percentiles(ns);
    try log.print("  {s:<24} {d:>10.1} {d:>10.1} {d:>10.1}  {d:.0} MiB/s\n", .{ "present copy", s.p50 / 1000, s.p95 / 1000, s.mean / 1000, @as(f64, @floatFromInt(p.present.len * 4)) / (s.p50 / 1e9) / (1024 * 1024) });
}

fn fillScreen(term: *VtState) void {
    term.reset();
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789  ";
    var r: u16 = 0;
    while (r < term.rows) : (r += 1) {
        term.grid().cursor = .{ .row = r, .col = 0 };
        term.grid().wrap_pending = false;
        var c: u16 = 0;
        while (c < term.cols) : (c += 1) term.printCodepoint(alphabet[(@as(usize, r) * 7 + c) % alphabet.len]);
    }
    term.grid().cursor = .{};
    term.grid().wrap_pending = false;
}

// ---------------------------------------------------------------- environment

fn hashBytes(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

fn hashTerm(term: *const VtState) u64 {
    var h: u64 = 0;
    var r: u16 = 0;
    while (r < term.rows) : (r += 1) {
        // Resolved styles: ids depend on interning order.
        var row: [2 * 1024]u128 = undefined;
        const cells = term.rowCells(r);
        const n = @min(cells.len, row.len / 2);
        for (cells[0..n], 0..) |c, i| {
            row[2 * i] = c.codepoint;
            row[2 * i + 1] = term.styleOf(c).key();
        }
        h = (h *% 0x100000001b3) ^ hashBytes(std.mem.sliceAsBytes(row[0 .. 2 * n]));
    }
    const c = term.cursor();
    return h ^ (@as(u64, c.row) << 32) ^ c.col;
}

const Font = struct { path: []u8, bytes: []u8 };

fn loadFonts(io: std.Io, gpa: std.mem.Allocator, override: ?[]const u8, out: *std.ArrayList(Font)) !void {
    if (override) |path| {
        const bytes = loadFile(io, gpa, path) catch |err| {
            std.debug.print("bench: font {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        try out.append(gpa, .{ .path = try gpa.dupe(u8, path), .bytes = bytes });
    } else if (fcMatch(io, gpa, "monospace")) |path| {
        if (loadFile(io, gpa, path)) |bytes| {
            try out.append(gpa, .{ .path = path, .bytes = bytes });
        } else |_| gpa.free(path);
    }
    if (out.items.len == 0) for (font_paths) |path| {
        const bytes = loadFile(io, gpa, path) catch continue;
        try out.append(gpa, .{ .path = try gpa.dupe(u8, path), .bytes = bytes });
        break;
    };
    if (out.items.len == 0) return;
    for (fallback_paths) |path| {
        if (std.mem.eql(u8, path, out.items[0].path)) continue;
        const bytes = loadFile(io, gpa, path) catch continue;
        try out.append(gpa, .{ .path = try gpa.dupe(u8, path), .bytes = bytes });
    }
}

fn fcMatch(io: std.Io, gpa: std.mem.Allocator, pattern: []const u8) ?[]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "fc-match", "-f", "%{file}", pattern },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const path = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (path.len == 0 or path[0] != '/') return null;
    return gpa.dupe(u8, path) catch null;
}

fn loadFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const len = try file.length(io);
    if (len > 64 * 1024 * 1024) return error.FileTooLarge;
    const bytes = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.ShortRead;
    return bytes;
}

fn readSmall(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    // procfs/sysfs report length zero; use a bounded positional read.
    const n = file.readPositionalAll(io, buf, 0) catch return null;
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

fn machineInfo(log: *Log, gpa: std.mem.Allocator, io: std.Io) !void {
    const data = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(data);
    const cpu = readSmall(io, "/proc/cpuinfo", data) orelse "";
    var model: []const u8 = "unknown";
    var lines = std.mem.splitScalar(u8, cpu, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "model name") or std.mem.startsWith(u8, line, "Hardware")) {
        model = std.mem.trim(u8, line[(std.mem.indexOfScalar(u8, line, ':') orelse 0) + 1 ..], " \t");
        break;
    };
    try log.print("host cpu {s} threads={d}\n", .{ model, std.Thread.getCpuCount() catch 0 });
    // Power state moves results by 1.5x+ on laptops; record it with every log.
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    var b3: [64]u8 = undefined;
    var ac: []const u8 = "unknown";
    for ([_][]const u8{ "/sys/class/power_supply/AC/online", "/sys/class/power_supply/ACAD/online", "/sys/class/power_supply/AC0/online", "/sys/class/power_supply/ADP1/online" }) |path| {
        if (readSmall(io, path, &b1)) |v| {
            ac = if (std.mem.eql(u8, v, "1")) "ac" else "battery";
            break;
        }
    }
    try log.print("power {s} governor={s} profile={s}\n", .{
        ac,
        readSmall(io, "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", &b2) orelse "unknown",
        readSmall(io, "/sys/firmware/acpi/platform_profile", &b3) orelse "unknown",
    });
}

const Stamp = struct { iso: [20]u8, file: [18]u8 };
fn stampForSeconds(secs: u64) !Stamp {
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    var stamp: Stamp = undefined;
    const iso = try std.fmt.bufPrint(&stamp.iso, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), @as(u8, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
    const file = try std.fmt.bufPrint(&stamp.file, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        yd.year, md.month.numeric(), @as(u8, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
    if (iso.len != stamp.iso.len or file.len != stamp.file.len) return error.InvalidStamp;
    return stamp;
}
fn utcStamp(io: std.Io) !Stamp {
    const ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    return stampForSeconds(if (ns <= 0) 0 else @intCast(@divTrunc(ns, 1_000_000_000)));
}

const Git = struct { hash: []u8, status: []const u8 };
fn gitRev(gpa: std.mem.Allocator, io: std.Io) !Git {
    const result = std.process.run(gpa, io, .{ .argv = &.{ "git", "rev-parse", "--short=12", "HEAD" }, .stdout_limit = .limited(64), .stderr_limit = .limited(256) }) catch return .{ .hash = try gpa.dupe(u8, "unknown"), .status = "unknown" };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const text = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!success or text.len == 0) return .{ .hash = try gpa.dupe(u8, "unknown"), .status = "unknown" };
    for (text) |c| if (!std.ascii.isHex(c)) return error.InvalidGitHash;
    const hash = try gpa.dupe(u8, text);
    errdefer gpa.free(hash);
    const status = std.process.run(gpa, io, .{ .argv = &.{ "git", "status", "--porcelain" }, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(256) }) catch return .{ .hash = hash, .status = "unknown" };
    defer gpa.free(status.stdout);
    defer gpa.free(status.stderr);
    return .{ .hash = hash, .status = switch (status.term) {
        .exited => |code| if (code != 0) "unknown" else if (std.mem.trim(u8, status.stdout, " \t\r\n").len == 0) "clean" else "dirty",
        else => "unknown",
    } };
}

fn saveLog(io: std.Io, log: *Log, stamp: [18]u8, hash: []const u8, dirty: bool) !void {
    const cwd = std.Io.Dir.cwd();
    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "bench/{s}-{s}{s}.txt", .{ stamp, hash, if (dirty) "-dirty" else "" });
    cwd.createDirPath(io, "bench") catch |err| {
        std.debug.print("bench: create bench/: {s}\n", .{@errorName(err)});
        return err;
    };
    const data = log.buffer.writer.buffered();
    cwd.writeFile(io, .{ .sub_path = name, .data = data }) catch |err| {
        std.debug.print("bench: save {s}: {s}\n", .{ name, @errorName(err) });
        return err;
    };
    cwd.writeFile(io, .{ .sub_path = "last_bench", .data = data }) catch |err| {
        std.debug.print("bench: save last_bench (stamped log saved): {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("saved {s} and last_bench\n", .{name});
}

// ---------------------------------------------------------------- tests

test "benchmark UTC filename is 18 bytes, including leap day and midnight" {
    const epoch = try stampForSeconds(0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", &epoch.iso);
    try std.testing.expectEqualStrings("1970-01-01T000000Z", &epoch.file);
    const leap = try stampForSeconds(1709251199);
    try std.testing.expectEqualStrings("2024-02-29T235959Z", &leap.file);
    const next = try stampForSeconds(1709251200);
    try std.testing.expectEqualStrings("2024-03-01T000000Z", &next.file);
}

test "benchmark options validate and quick defaults respect explicit values" {
    const opt = try parseOptions(&.{ "bench", "--samples=50", "--quick", "--grid", "80x24", "--only=ascii,glyph", "--burst=4" });
    try std.testing.expectEqual(@as(u32, 50), opt.samples);
    try std.testing.expectEqual(@as(u32, 1), opt.mib);
    try std.testing.expectEqual(@as(u16, 80), opt.cols);
    try std.testing.expectEqual(@as(u16, 24), opt.rows);
    try std.testing.expectEqual(@as(u32, 4), opt.burst_kib);
    try std.testing.expect(wanted(opt, "glyph") and !wanted(opt, "sixel"));
    try std.testing.expectError(error.InvalidCount, parseOptions(&.{ "bench", "--samples=5" }));
    try std.testing.expectError(error.InvalidCount, parseOptions(&.{ "bench", "--burst=64" }));
    try std.testing.expectError(error.InvalidGrid, parseOptions(&.{ "bench", "--grid=80" }));
    try std.testing.expectError(error.UnknownOption, parseOptions(&.{ "bench", "--typo=1" }));
    try std.testing.expectError(error.MissingValue, parseOptions(&.{ "bench", "--font" }));
    try std.testing.expectError(error.UnexpectedValue, parseOptions(&.{ "bench", "--help=1" }));
}

test "benchmark percentiles are nearest-rank" {
    var v = [_]u64{ 5, 1, 4, 2, 3, 6, 7, 8, 9, 10 };
    const p = percentiles(&v);
    try std.testing.expectEqual(@as(f64, 5), p.p50);
    try std.testing.expectEqual(@as(f64, 10), p.p95);
    try std.testing.expectEqual(@as(f64, 5.5), p.mean);
    var one = [_]u64{7};
    try std.testing.expectEqual(@as(f64, 7), percentiles(&one).p95);
}

test "benchmark workloads parse completely and images reach the store" {
    const gpa = std.testing.allocator;
    for (workloads) |wl| {
        const bytes = try generate(gpa, wl, 128 * 1024);
        defer gpa.free(bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0x1b) != null);
        var ring = try CircBuffer.create(gpa, ring_cap);
        defer ring.destroy();
        var term = try VtState.init(gpa, 80, 24, scrollback, ring.storage);
        defer term.deinit();
        // Feed in 4093-byte cuts so sequences split across reads, as over a PTY.
        var off: usize = 0;
        while (off < bytes.len) {
            const n = @min(4093, bytes.len - off);
            const at: usize = @intCast(ring.head & (ring.capacity - 1));
            @memcpy(ring.storage[at..][0..n], bytes[off..][0..n]);
            if (!ring.mapped) mirror(&ring, at, n);
            ring.head += n;
            off += n;
            ring.drain(term.sink());
        }
        try std.testing.expectEqual(ring.head, ring.tail);
        if (std.mem.eql(u8, wl.name, "kitty-image") or std.mem.eql(u8, wl.name, "sixel")) {
            try std.testing.expect(term.kitty.images.items.len != 0);
        }
    }
}

test "benchmark PTY pipeline delivers every byte" {
    const gpa = std.testing.allocator;
    const bytes = try generate(gpa, workloads[0], 256 * 1024);
    defer gpa.free(bytes);
    var env: Env = .{ .gpa = gpa, .io = std.Io.Threaded.global_single_threaded.io(), .opt = .{ .cols = 40, .rows = 10 }, .ctx = null, .cell_w = 8, .cell_h = 16, .emoji = false };
    var log: Log = .{ .buffer = .init(gpa), .echo = false };
    defer log.buffer.deinit();
    try runPipeline(&log, &env, workloads[0], bytes);
    try std.testing.expect(std.mem.indexOf(u8, log.buffer.writer.buffered(), "pipeline ascii") != null);
}

test "firehose drain keeps the final screen and images exact" {
    const gpa = std.testing.allocator;
    for (workloads) |wl| {
        const bytes = try generate(gpa, wl, 1 << 20);
        defer gpa.free(bytes);
        const env: Env = .{ .gpa = gpa, .io = std.Io.Threaded.global_single_threaded.io(), .opt = .{}, .ctx = null, .cell_w = 8, .cell_h = 16, .emoji = false };
        var ring = try CircBuffer.create(gpa, ring_cap);
        defer ring.destroy();
        var term = try VtState.init(gpa, env.opt.cols, env.opt.rows, scrollback, ring.storage);
        defer term.deinit();
        // Fill the ring the way readSource does: drain at a quarter free.
        var off: usize = 0;
        while (off < bytes.len) {
            const free = ring.capacity - (ring.head - ring.tail);
            const n = @min(@min(4093, bytes.len - off), free);
            const at: usize = @intCast(ring.head & (ring.capacity - 1));
            @memcpy(ring.storage[at..][0..n], bytes[off..][0..n]);
            if (!ring.mapped) mirror(&ring, at, n);
            ring.head += n;
            off += n;
            if (ring.capacity - (ring.head - ring.tail) < ring.capacity / 4) ring.drain(term.sink());
        }
        ring.drain(term.sink());
        const want = try referenceState(&env, bytes);
        const got = visibleState(&term);
        std.testing.expectEqual(want, got) catch |err| {
            std.debug.print("workload {s}: screen {} images {}\n", .{ wl.name, want.screen == got.screen, want.images == got.images });
            return err;
        };
    }
}
