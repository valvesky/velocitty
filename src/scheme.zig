//! Simple TOML config: colors + `[general]` + `[font]`.
//!
//! ```toml
//! [general]
//! pad = 14
//!
//! foreground = "#aaaaaa"
//! background = "#000000"
//! cursor = "#aaaaaa"
//!
//! [normal]
//! black = "#000000"
//! red = "#aa0000"
//! green = "#00aa00"
//! yellow = "#aa5500"
//! blue = "#0000aa"
//! magenta = "#aa00aa"
//! cyan = "#00aaaa"
//! white = "#aaaaaa"
//!
//! [bright]
//! black = "#555555"
//! red = "#ff5555"
//! green = "#55ff55"
//! yellow = "#ffff55"
//! blue = "#5555ff"
//! magenta = "#ff55ff"
//! cyan = "#55ffff"
//! white = "#ffffff"
//!
//! [font]
//! family = "monospace"
//! fallbacks = ["Noto Sans Symbols 2", "Noto Color Emoji"]
//! size = 16
//! ```
//!
//! `[colors]`, `[colors.primary]`, `[colors.cursor]`, `[colors.normal]`, and
//! `[colors.bright]` are accepted, as are `fg` / `bg` and `bright_red`-style
//! keys. Omarchy `colors.toml` (`muted`, `bright_foreground`, root ANSI) is
//! accepted. `refreshrate` / `hz` and `whitelist` are parsed for compatibility
//! but are not applied by the runtime. Cadence follows Hyprland, else 60 Hz.
//! `pad` / `padding` is inner window margin in CSS pixels (default 14).
//! Supported settings use bare table/key names and single-line strings.
//! Unknown keys and tables (including array tables) are skipped without
//! interpreting their values; this is not a full TOML validator.
//!
//! `load` overlays user config then the current Omarchy theme so SIGUSR can
//! re-read colors and font without a restart. Unset family uses fontconfig
//! `monospace` (`omarchy font current`). Size falls back to Alacritty, then
//! 9 pt if the Omarchy theme's colors.toml exists, otherwise 8 pt.

const std = @import("std");
const builtin = @import("builtin");
const Grid = @import("grid.zig");

pub const Scheme = Grid.Scheme;

pub const max_font_family = 128;
pub const max_font_fallbacks = 16;

pub const FontFamily = struct {
    name: [max_font_family]u8 = @splat(0),
    len: u8 = 0,

    pub fn slice(self: *const FontFamily) []const u8 {
        return self.name[0..self.len];
    }
};

pub const Config = struct {
    scheme: Scheme = .{},
    /// Legacy setting, parsed but not applied by the runtime.
    hz: u32 = 30,
    /// Legacy setting, parsed but not applied during line splitting.
    whitelist: bool = false,
    /// Inner window margin in CSS pixels (all sides).
    pad_px: u32 = 14,
    font_family: [max_font_family]u8 = @splat(0),
    font_family_len: u8 = 0,
    /// Ordered installed families, before built-in fallbacks. Empty keeps defaults.
    font_fallbacks: [max_font_fallbacks]FontFamily = @splat(.{}),
    font_fallbacks_len: u8 = 0,
    /// Point size (Alacritty/Foot/Ghostty). 0 = unspecified (caller default).
    font_size: f32 = 0,

    pub fn family(self: *const Config) ?[]const u8 {
        if (self.font_family_len == 0) return null;
        return self.font_family[0..self.font_family_len];
    }

    pub fn fallbackFamilies(self: *const Config) []const FontFamily {
        return self.font_fallbacks[0..self.font_fallbacks_len];
    }
};

pub fn parse(src: []const u8) error{InvalidToml}!Config {
    return parseInto(src, .{});
}

pub fn parseInto(src: []const u8, base: Config) error{InvalidToml}!Config {
    var p = Parser{ .src = stripBom(src) };
    return p.run(base);
}

/// Where and why a parse failed: byte offset into the BOM-stripped source,
/// 1-based line and column.
pub const ParseErrorPos = struct {
    pos: usize = 0,
    line: u32 = 1,
    col: u32 = 1,
};

pub fn parseIntoPos(src: []const u8, base: Config, err: *ParseErrorPos) error{InvalidToml}!Config {
    var p = Parser{ .src = stripBom(src) };
    return p.run(base) catch |e| {
        err.* = errorPos(p.src, p.i);
        return e;
    };
}

fn errorPos(src: []const u8, at: usize) ParseErrorPos {
    const pos = @min(at, src.len);
    var line: u32 = 1;
    var line_start: usize = 0;
    for (src[0..pos], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .pos = pos, .line = line, .col = @intCast(pos - line_start + 1) };
}

// Startup/reload diagnostics. GUI-subsystem Windows builds and macOS apps
// launched from Finder have no visible stderr, so messages are also kept in a
// small bounded buffer that main feeds to the terminal as text.
var diag_store: [2048]u8 = undefined;
var diag_len: usize = 0;
var diag_visible_override: ?bool = null;

fn stderrIsTerminal() bool {
    if (builtin.os.tag == .windows) {
        const h = GetStdHandle(@bitCast(@as(i32, -12)));
        var mode: u32 = 0;
        return h != null and GetConsoleMode(h, &mode) != 0;
    }
    if (!builtin.link_libc) return true;
    return std.c.isatty(2) != 0;
}

extern "kernel32" fn GetStdHandle(id: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetConsoleMode(h: ?*anyopaque, mode: *u32) callconv(.winapi) i32;

/// Reports to stderr and, when stderr is not a terminal, queues the message
/// for display inside the window. Dropped when the buffer is full.
pub fn report(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) std.debug.print("velocitty: " ++ fmt ++ "\n", args);
    if (diag_visible_override orelse stderrIsTerminal()) return;
    var tmp: [512]u8 = undefined;
    // Plain text: the queue is fed through `VtState.feedText`, which prints
    // and runs C0 controls but does not parse escape sequences.
    const msg = std.fmt.bufPrint(&tmp, "velocitty: " ++ fmt ++ "\r\n", args) catch tmp[0..0];
    if (diag_len + msg.len > diag_store.len) return;
    @memcpy(diag_store[diag_len..][0..msg.len], msg);
    diag_len += msg.len;
}

/// Returns queued diagnostics (valid until the next `report`) and clears them.
pub fn takeDiagnostics() []const u8 {
    const out = diag_store[0..diag_len];
    diag_len = 0;
    return out;
}

pub fn parseScheme(src: []const u8) error{InvalidToml}!Scheme {
    return (try parse(src)).scheme;
}

pub fn loadFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?Config {
    var cfg: Config = .{};
    overlayFile(io, gpa, path, &cfg);
    return cfg;
}

/// User config, then Omarchy current theme (theme colors win when present).
pub fn load(io: std.Io, gpa: std.mem.Allocator) Config {
    var cfg: Config = .{};
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var cbufs: ConfigBufs = undefined;
    if (userConfigPath(io, &cbufs)) |path| overlayFile(io, gpa, path, &cfg);
    overlayFile(io, gpa, "config.toml", &cfg);
    if (omarchyThemePath(&buf, "colors.toml")) |path| overlayFile(io, gpa, path, &cfg);
    if (omarchyThemePath(&buf, "alacritty.toml")) |path| overlayFile(io, gpa, path, &cfg);
    fillUnsetFont(io, gpa, &buf, &cfg);
    return cfg;
}

fn fillUnsetFont(io: std.Io, gpa: std.mem.Allocator, buf: []u8, cfg: *Config) void {
    // Omarchy's source of truth is fontconfig `monospace` (`omarchy font current`).
    // Copy size from Alacritty when unset; leave family empty so loadFonts fc-matches
    // monospace (user fonts.conf + ~/.local/share/fonts) instead of a stale terminal config.
    var tmp: Config = .{};
    if (xdgConfigPath(buf, "alacritty/alacritty.toml")) |path| overlayFile(io, gpa, path, &tmp);
    if (cfg.font_size == 0 and tmp.font_size != 0) cfg.font_size = tmp.font_size;
    if (cfg.font_size == 0) cfg.font_size = fontSizeFallback(io, omarchyThemePath(buf, "colors.toml"));
}

/// Point size when none is configured. 8/9 pt is Omarchy's convention and is
/// tiny on Windows and macOS, which get 12 pt.
fn defaultFontSize(os: std.Target.Os.Tag, omarchy_theme: bool) f32 {
    return switch (os) {
        .windows, .macos => 12,
        else => if (omarchy_theme) 9 else 8,
    };
}

fn fontSizeFallback(io: std.Io, theme_colors: ?[]const u8) f32 {
    const path = theme_colors orelse return defaultFontSize(builtin.os.tag, false);
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return defaultFontSize(builtin.os.tag, false);
    return defaultFontSize(builtin.os.tag, st.kind == .file);
}

/// Fingerprint of config/theme/font files. Changes when Omarchy swaps the theme.
pub fn watchStamp(io: std.Io) u64 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var stamp: u64 = 0;
    stamp ^= fileStamp(io, "config.toml");
    var cbufs: ConfigBufs = undefined;
    for (configCandidates(&cbufs)) |cand| {
        if (cand) |path| stamp = mix(stamp, fileStamp(io, path));
    }
    if (omarchyCurrentPath(&buf, "theme.name")) |path| stamp = mix(stamp, fileStamp(io, path));
    if (omarchyThemePath(&buf, "colors.toml")) |path| stamp = mix(stamp, fileStamp(io, path));
    if (omarchyThemePath(&buf, "alacritty.toml")) |path| stamp = mix(stamp, fileStamp(io, path));
    if (fontconfigPath(&buf)) |path| stamp = mix(stamp, fileStamp(io, path));
    if (xdgConfigPath(&buf, "alacritty/alacritty.toml")) |path| stamp = mix(stamp, fileStamp(io, path));
    return stamp;
}

fn mix(a: u64, b: u64) u64 {
    return a *% 0x9e3779b97f4a7c15 ^ b;
}

fn fileStamp(io: std.Io, path: []const u8) u64 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer file.close(io);
    const st = file.stat(io) catch return 0;
    const ns = st.mtime.nanoseconds;
    const mt: u64 = if (ns >= 0) @truncate(@as(u128, @intCast(ns))) else 0;
    return mix(mt, st.size);
}

fn overlayFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8, cfg: *Config) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch return;
    defer gpa.free(bytes);
    var err: ParseErrorPos = .{};
    cfg.* = parseIntoPos(bytes, cfg.*, &err) catch {
        report("invalid config {s} line {d} column {d}", .{ path, err.line, err.col });
        return;
    };
}

fn envSpan(key: [:0]const u8) ?[]const u8 {
    return @import("env.zig").get(key);
}

fn xdgConfigPath(buf: []u8, rel: []const u8) ?[]u8 {
    if (envSpan("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ xdg, rel }) catch null;
    }
    if (envSpan("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.config/{s}", .{ home, rel }) catch null;
    }
    return null;
}

const config_rel = "velocitty/config.toml";
const max_candidates = 4;
const ConfigBufs = [max_candidates][std.fs.max_path_bytes]u8;

/// Config file candidates in priority order: $XDG_CONFIG_HOME, the platform
/// native location, then ~/.config (Windows: %USERPROFILE%, then %HOME%).
/// Linux keeps its single XDG-or-~/.config location.
fn configCandidates(bufs: *ConfigBufs) [max_candidates]?[]const u8 {
    var out: [max_candidates]?[]const u8 = @splat(null);
    switch (builtin.os.tag) {
        .windows => {
            if (envSpan("XDG_CONFIG_HOME")) |xdg| out[0] = std.fmt.bufPrint(&bufs[0], "{s}/" ++ config_rel, .{xdg}) catch null;
            if (envSpan("APPDATA")) |dir| {
                out[1] = std.fmt.bufPrint(&bufs[1], "{s}/" ++ config_rel, .{dir}) catch null;
            } else if (envSpan("USERPROFILE")) |dir| {
                out[1] = std.fmt.bufPrint(&bufs[1], "{s}/AppData/Roaming/" ++ config_rel, .{dir}) catch null;
            }
            if (envSpan("USERPROFILE")) |dir| out[2] = std.fmt.bufPrint(&bufs[2], "{s}/.config/" ++ config_rel, .{dir}) catch null;
            if (envSpan("HOME")) |dir| out[3] = std.fmt.bufPrint(&bufs[3], "{s}/.config/" ++ config_rel, .{dir}) catch null;
        },
        .macos => {
            if (envSpan("XDG_CONFIG_HOME")) |xdg| out[0] = std.fmt.bufPrint(&bufs[0], "{s}/" ++ config_rel, .{xdg}) catch null;
            if (envSpan("HOME")) |dir| {
                out[1] = std.fmt.bufPrint(&bufs[1], "{s}/Library/Application Support/" ++ config_rel, .{dir}) catch null;
                out[2] = std.fmt.bufPrint(&bufs[2], "{s}/.config/" ++ config_rel, .{dir}) catch null;
            }
        },
        else => out[0] = xdgConfigPath(&bufs[0], config_rel),
    }
    return out;
}

/// First candidate for which `exists` is true; with none present, the first
/// candidate (the location a new file is expected at).
fn pickConfigPath(cands: []const ?[]const u8, ctx: anytype, comptime exists: fn (@TypeOf(ctx), []const u8) bool) ?[]const u8 {
    var first: ?[]const u8 = null;
    for (cands) |cand| {
        const path = cand orelse continue;
        if (first == null) first = path;
        if (exists(ctx, path)) return path;
    }
    return first;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

fn userConfigPath(io: std.Io, bufs: *ConfigBufs) ?[]const u8 {
    const cands = configCandidates(bufs);
    return pickConfigPath(&cands, io, fileExists);
}

fn omarchyCurrentPath(buf: []u8, name: []const u8) ?[]u8 {
    if (builtin.os.tag != .linux) return null;
    if (envSpan("XDG_STATE_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/omarchy/current/{s}", .{ xdg, name }) catch null;
    }
    if (envSpan("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.local/state/omarchy/current/{s}", .{ home, name }) catch null;
    }
    return null;
}

fn omarchyThemePath(buf: []u8, name: []const u8) ?[]u8 {
    if (builtin.os.tag != .linux) return null;
    if (envSpan("XDG_STATE_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/omarchy/current/theme/{s}", .{ xdg, name }) catch null;
    }
    if (envSpan("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.local/state/omarchy/current/theme/{s}", .{ home, name }) catch null;
    }
    return null;
}

fn fontconfigPath(buf: []u8) ?[]u8 {
    if (envSpan("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/fontconfig/fonts.conf", .{xdg}) catch null;
    }
    if (envSpan("HOME")) |home| {
        return std.fmt.bufPrint(buf, "{s}/.config/fontconfig/fonts.conf", .{home}) catch null;
    }
    return null;
}

const Parser = struct {
    src: []const u8,
    i: usize = 0,
    table: []const u8 = "",
    string_buf: [512]u8 = undefined,

    fn run(self: *Parser, base: Config) error{InvalidToml}!Config {
        var config = base;
        while (true) {
            self.skipSpaceComments();
            if (self.i >= self.src.len) break;
            if (self.src[self.i] == '[') {
                try self.parseTable();
            } else {
                try self.parseKeyValue(&config);
            }
        }
        return config;
    }

    fn parseTable(self: *Parser) error{InvalidToml}!void {
        self.i += 1;
        const array = self.i < self.src.len and self.src[self.i] == '[';
        if (array) self.i += 1;
        self.skipSpaces();
        const name = try self.parseKey();
        if (self.i >= self.src.len or self.src[self.i] != ']') return error.InvalidToml;
        self.i += 1;
        if (array) {
            if (self.i >= self.src.len or self.src[self.i] != ']') return error.InvalidToml;
            self.i += 1;
        }
        // Array tables are unrelated settings, even if named [[font]].
        self.table = if (array) "\x00" else name;
        try self.expectEol();
    }

    fn parseKeyValue(self: *Parser, config: *Config) error{InvalidToml}!void {
        const key = try self.parseKey();
        self.skipSpaces();
        if (self.i >= self.src.len or self.src[self.i] != '=') return error.InvalidToml;
        self.i += 1;
        self.skipSpaces();
        const general = isGeneral(self.table);
        const font_table = isFontTable(self.table);
        const settings = general or font_table or self.table.len == 0;
        if (general and isHzKey(key)) {
            const hz = try self.parseInteger();
            if (hz == 0) return error.InvalidToml;
            config.hz = hz;
        } else if (general and isWhitelistKey(key)) {
            config.whitelist = try self.parseBool();
        } else if (general and isPadKey(key)) {
            config.pad_px = try self.parseInteger();
        } else if (settings and isFontSizeKey(key)) {
            const size = try self.parseNumber();
            if (size <= 0) return error.InvalidToml;
            config.font_size = size;
        } else if (settings and isFontFamilyKey(key)) {
            const value = try self.parseString();
            try setFamily(config, value);
        } else if (font_table and std.mem.eql(u8, key, "fallbacks")) {
            try self.parseFontFallbacks(config);
        } else if (font_table and std.mem.eql(u8, key, "normal") and self.i < self.src.len and self.src[self.i] == '{') {
            try self.parseFontInline(config);
        } else if (isColorKey(self.table, key) and self.i < self.src.len and (self.src[self.i] == '"' or self.src[self.i] == '\'')) {
            const value = try self.parseString();
            if (parseColor(value)) |color| {
                const table = if (isGeneral(self.table)) "" else self.table;
                apply(&config.scheme, table, key, color);
            } else |_| {}
        } else {
            try self.skipValue();
        }
        try self.expectEol();
    }

    fn parseKey(self: *Parser) error{InvalidToml}![]const u8 {
        const start = self.i;
        while (true) {
            if (self.i < self.src.len and (self.src[self.i] == '"' or self.src[self.i] == '\'')) {
                try self.skipString(false);
            } else {
                _ = try self.parseBare();
            }
            self.skipSpaces();
            if (self.i >= self.src.len or self.src[self.i] != '.') break;
            self.i += 1;
            self.skipSpaces();
        }
        return std.mem.trim(u8, self.src[start..self.i], " \t");
    }

    fn parseFontFallbacks(self: *Parser, config: *Config) error{InvalidToml}!void {
        if (self.i >= self.src.len or self.src[self.i] != '[') return error.InvalidToml;
        self.i += 1;
        config.font_fallbacks_len = 0;
        self.skipSpaceComments();
        while (true) {
            if (self.i >= self.src.len) return error.InvalidToml;
            if (self.src[self.i] == ']') {
                self.i += 1;
                return;
            }
            const value = try self.parseString();
            if (std.mem.trim(u8, value, " \t").len == 0 or value.len > max_font_family or
                std.mem.indexOfScalar(u8, value, 0) != null or
                config.font_fallbacks_len == max_font_fallbacks) return error.InvalidToml;
            const entry = &config.font_fallbacks[config.font_fallbacks_len];
            @memcpy(entry.name[0..value.len], value);
            entry.len = @intCast(value.len);
            config.font_fallbacks_len += 1;
            self.skipSpaceComments();
            if (self.i >= self.src.len) return error.InvalidToml;
            if (self.src[self.i] == ']') {
                self.i += 1;
                return;
            }
            if (self.src[self.i] != ',') return error.InvalidToml;
            self.i += 1;
            self.skipSpaceComments();
        }
    }

    fn parseFontInline(self: *Parser, config: *Config) error{InvalidToml}!void {
        if (self.i >= self.src.len or self.src[self.i] != '{') return error.InvalidToml;
        self.i += 1;
        while (true) {
            self.skipSpaces();
            if (self.i >= self.src.len) return error.InvalidToml;
            if (self.src[self.i] == '}') {
                self.i += 1;
                return;
            }
            if (self.src[self.i] == ',') {
                self.i += 1;
                continue;
            }
            const key = try self.parseKey();
            if (self.i >= self.src.len or self.src[self.i] != '=') return error.InvalidToml;
            self.i += 1;
            self.skipSpaces();
            if (isFontFamilyKey(key) and (self.i < self.src.len and (self.src[self.i] == '"' or self.src[self.i] == '\''))) {
                const value = try self.parseString();
                if (config.font_family_len == 0) try setFamily(config, value);
            } else if (isFontSizeKey(key)) {
                const size = try self.parseNumber();
                if (size > 0 and config.font_size == 0) config.font_size = size;
            } else {
                try self.skipValue();
            }
        }
    }

    fn parseBare(self: *Parser) error{InvalidToml}![]const u8 {
        const start = self.i;
        if (self.i >= self.src.len or !isBare(self.src[self.i])) return error.InvalidToml;
        while (self.i < self.src.len and isBare(self.src[self.i])) self.i += 1;
        return self.src[start..self.i];
    }

    fn parseString(self: *Parser) error{InvalidToml}![]const u8 {
        const start = self.i;
        try self.skipString(false);
        const raw = self.src[start + 1 .. self.i - 1];
        if (self.src[start] == '\'' or std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;

        var n: usize = 0;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '\\') {
                try self.appendString(&n, raw[i .. i + 1]);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= raw.len) return error.InvalidToml;
            const escaped: u8 = switch (raw[i]) {
                'b' => 0x08,
                't' => '\t',
                'n' => '\n',
                'f' => 0x0c,
                'r' => '\r',
                '"' => '"',
                '\\' => '\\',
                'u', 'U' => {
                    const digits: usize = if (raw[i] == 'u') 4 else 8;
                    i += 1;
                    if (raw.len - i < digits) return error.InvalidToml;
                    var cp: u32 = 0;
                    for (raw[i..][0..digits]) |c| cp = (cp << 4) | try hexNibble(c);
                    if (cp > 0x10ffff) return error.InvalidToml;
                    var utf8: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(cp), &utf8) catch return error.InvalidToml;
                    try self.appendString(&n, utf8[0..len]);
                    i += digits;
                    continue;
                },
                else => return error.InvalidToml,
            };
            try self.appendString(&n, &.{escaped});
            i += 1;
        }
        return self.string_buf[0..n];
    }

    fn appendString(self: *Parser, n: *usize, bytes: []const u8) error{InvalidToml}!void {
        if (bytes.len > self.string_buf.len - n.*) return error.InvalidToml;
        @memcpy(self.string_buf[n.*..][0..bytes.len], bytes);
        n.* += bytes.len;
    }

    fn skipString(self: *Parser, allow_multiline: bool) error{InvalidToml}!void {
        if (self.i >= self.src.len) return error.InvalidToml;
        const quote = self.src[self.i];
        if (quote != '"' and quote != '\'') return error.InvalidToml;
        self.i += 1;
        const multiline = self.i + 1 < self.src.len and self.src[self.i] == quote and self.src[self.i + 1] == quote;
        if (multiline) {
            if (!allow_multiline) return error.InvalidToml;
            self.i += 2;
        }
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == quote) {
                if (!multiline) {
                    self.i += 1;
                    return;
                }
                const start = self.i;
                while (self.i < self.src.len and self.src[self.i] == quote) self.i += 1;
                if (self.i - start >= 3) return;
                continue;
            }
            if (c == '\\' and quote == '"') {
                self.i += 1;
                if (self.i >= self.src.len) return error.InvalidToml;
                if (!multiline and (self.src[self.i] == '\n' or self.src[self.i] == '\r')) return error.InvalidToml;
            } else if (!multiline and (c == '\n' or c == '\r')) {
                return error.InvalidToml;
            }
            self.i += 1;
        }
        return error.InvalidToml;
    }

    fn parseInteger(self: *Parser) error{InvalidToml}!u32 {
        const value = try self.scalar();
        const digits = if (value[0] == '+') value[1..] else value;
        if (digits.len == 0) return error.InvalidToml;
        for (digits, 0..) |c, i| {
            if (std.ascii.isDigit(c)) continue;
            if (c != '_' or i == 0 or i + 1 == digits.len or
                !std.ascii.isDigit(digits[i - 1]) or !std.ascii.isDigit(digits[i + 1])) return error.InvalidToml;
        }
        return std.fmt.parseInt(u32, digits, 10) catch return error.InvalidToml;
    }

    fn parseNumber(self: *Parser) error{InvalidToml}!f32 {
        const value = try self.scalar();
        const n = std.fmt.parseFloat(f32, value) catch return error.InvalidToml;
        if (!std.math.isFinite(n)) return error.InvalidToml;
        return n;
    }

    fn scalar(self: *Parser) error{InvalidToml}![]const u8 {
        const start = self.i;
        while (self.i < self.src.len) : (self.i += 1) {
            switch (self.src[self.i]) {
                ' ', '\t', '\r', '\n', '#', ',', ']', '}' => break,
                else => {},
            }
        }
        if (self.i == start) return error.InvalidToml;
        return self.src[start..self.i];
    }

    fn parseBool(self: *Parser) error{InvalidToml}!bool {
        const ident = try self.parseBare();
        if (std.mem.eql(u8, ident, "true")) return true;
        if (std.mem.eql(u8, ident, "false")) return false;
        return error.InvalidToml;
    }

    fn skipValue(self: *Parser) error{InvalidToml}!void {
        if (self.i >= self.src.len) return error.InvalidToml;
        const c = self.src[self.i];
        if (c == '"' or c == '\'') {
            try self.skipString(true);
            return;
        }
        if (c == '{' or c == '[') {
            try self.skipBracketed();
            return;
        }
        const start = self.i;
        while (self.i < self.src.len) : (self.i += 1) {
            switch (self.src[self.i]) {
                '\r', '\n', '#', ',', ']', '}' => break,
                else => {},
            }
        }
        if (std.mem.trim(u8, self.src[start..self.i], " \t").len == 0) return error.InvalidToml;
    }

    fn skipBracketed(self: *Parser) error{InvalidToml}!void {
        var closes: [64]u8 = undefined;
        closes[0] = if (self.src[self.i] == '{') '}' else ']';
        self.i += 1;
        var depth: usize = 1;
        while (self.i < self.src.len and depth > 0) {
            const c = self.src[self.i];
            if (c == '"' or c == '\'') {
                try self.skipString(true);
                continue;
            } else if (c == '#') {
                while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
                continue;
            } else if (c == '{' or c == '[') {
                if (depth == closes.len) return error.InvalidToml;
                closes[depth] = if (c == '{') '}' else ']';
                depth += 1;
            } else if (c == '}' or c == ']') {
                if (c != closes[depth - 1]) return error.InvalidToml;
                depth -= 1;
            }
            self.i += 1;
        }
        if (depth != 0) return error.InvalidToml;
    }

    fn expectEol(self: *Parser) error{InvalidToml}!void {
        self.skipSpaces();
        if (self.i < self.src.len and self.src[self.i] == '#') {
            while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
        }
        if (self.i >= self.src.len) return;
        const c = self.src[self.i];
        if (c == '\n') {
            self.i += 1;
            return;
        }
        if (c == '\r') {
            self.i += 1;
            if (self.i < self.src.len and self.src[self.i] == '\n') self.i += 1;
            return;
        }
        return error.InvalidToml;
    }

    fn skipSpaceComments(self: *Parser) void {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.i += 1;
                continue;
            }
            if (c == '#') {
                while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
                continue;
            }
            break;
        }
    }

    fn skipSpaces(self: *Parser) void {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == ' ' or c == '\t') {
                self.i += 1;
                continue;
            }
            break;
        }
    }
};

fn stripBom(src: []const u8) []const u8 {
    if (src.len >= 3 and src[0] == 0xef and src[1] == 0xbb and src[2] == 0xbf) return src[3..];
    return src;
}

fn isBare(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => true,
        else => false,
    };
}

fn isGeneral(table: []const u8) bool {
    return std.mem.eql(u8, table, "general");
}

fn isFontTable(table: []const u8) bool {
    return std.mem.eql(u8, table, "font") or std.mem.eql(u8, table, "fonts");
}

fn isHzKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "refreshrate") or std.mem.eql(u8, key, "hz");
}

fn isWhitelistKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "whitelist");
}

fn isPadKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "pad") or
        std.mem.eql(u8, key, "padding") or
        std.mem.eql(u8, key, "padding.x") or
        std.mem.eql(u8, key, "padding.y");
}

fn isFontFamilyKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "family") or
        std.mem.eql(u8, key, "font") or
        std.mem.eql(u8, key, "font_family") or
        std.mem.eql(u8, key, "font-family");
}

fn isFontSizeKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "size") or
        std.mem.eql(u8, key, "font_size") or
        std.mem.eql(u8, key, "font-size");
}

fn setFamily(config: *Config, value: []const u8) error{InvalidToml}!void {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidToml;
    const n = @min(value.len, max_font_family);
    @memcpy(config.font_family[0..n], value[0..n]);
    config.font_family_len = @intCast(n);
}

fn parseColor(s: []const u8) error{InvalidToml}!Grid.Color {
    var t = s;
    if (t.len > 0 and t[0] == '#') t = t[1..];
    if (t.len == 3) {
        const r = try hexNibble(t[0]);
        const g = try hexNibble(t[1]);
        const b = try hexNibble(t[2]);
        return .{ .r = r * 17, .g = g * 17, .b = b * 17 };
    }
    if (t.len == 6 or t.len == 8) {
        return .{
            .r = try hexByte(t[0..2]),
            .g = try hexByte(t[2..4]),
            .b = try hexByte(t[4..6]),
            .a = if (t.len == 8) try hexByte(t[6..8]) else 255,
        };
    }
    return error.InvalidToml;
}

fn hexByte(s: []const u8) error{InvalidToml}!u8 {
    return (try hexNibble(s[0])) * 16 + (try hexNibble(s[1]));
}

fn hexNibble(c: u8) error{InvalidToml}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidToml,
    };
}

const ansi_names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };

fn ansiIndex(key: []const u8) ?u8 {
    for (ansi_names, 0..) |n, i| {
        if (std.mem.eql(u8, n, key)) return @intCast(i);
    }
    return null;
}

fn isMetaTable(table: []const u8) bool {
    return table.len == 0 or
        std.mem.eql(u8, table, "colors") or
        std.mem.eql(u8, table, "colors.primary") or
        std.mem.eql(u8, table, "primary") or
        std.mem.eql(u8, table, "colors.cursor") or
        std.mem.eql(u8, table, "cursor");
}

fn isColorKey(table: []const u8, key: []const u8) bool {
    if (std.mem.eql(u8, table, "normal") or std.mem.eql(u8, table, "colors.normal") or
        std.mem.eql(u8, table, "bright") or std.mem.eql(u8, table, "colors.bright")) return ansiIndex(key) != null;
    if (!isGeneral(table) and !isMetaTable(table)) return false;
    for ([_][]const u8{ "foreground", "fg", "background", "bg", "cursor", "muted", "bright_foreground", "bright-foreground" }) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    if (ansiIndex(key) != null) return true;
    if (std.mem.startsWith(u8, key, "bright_") or std.mem.startsWith(u8, key, "bright-")) {
        return ansiIndex(key["bright_".len..]) != null;
    }
    return false;
}

fn apply(scheme: *Scheme, table: []const u8, key: []const u8, color: Grid.Color) void {
    const kind: enum { meta, normal, bright, skip } = blk: {
        if (isMetaTable(table)) break :blk .meta;
        if (std.mem.eql(u8, table, "normal") or std.mem.eql(u8, table, "colors.normal")) break :blk .normal;
        if (std.mem.eql(u8, table, "bright") or std.mem.eql(u8, table, "colors.bright")) break :blk .bright;
        break :blk .skip;
    };
    switch (kind) {
        .skip => {},
        .normal => if (ansiIndex(key)) |i| {
            scheme.palette[i] = color;
        },
        .bright => if (ansiIndex(key)) |i| {
            scheme.palette[8 + i] = color;
        },
        .meta => {
            if (std.mem.eql(u8, key, "foreground") or std.mem.eql(u8, key, "fg")) {
                scheme.fg = color;
                scheme.palette[7] = color;
            } else if (std.mem.eql(u8, key, "background") or std.mem.eql(u8, key, "bg")) {
                scheme.bg = color;
                scheme.palette[0] = color;
            } else if (std.mem.eql(u8, key, "cursor")) {
                scheme.cursor = color;
            } else if (std.mem.eql(u8, key, "muted")) {
                scheme.palette[8] = color;
            } else if (std.mem.eql(u8, key, "bright_foreground") or std.mem.eql(u8, key, "bright-foreground")) {
                scheme.palette[15] = color;
                scheme.cursor = color;
            } else if (ansiIndex(key)) |i| {
                scheme.palette[i] = color;
            } else if (std.mem.startsWith(u8, key, "bright_")) {
                if (ansiIndex(key["bright_".len..])) |i| scheme.palette[8 + i] = color;
            } else if (std.mem.startsWith(u8, key, "bright-")) {
                if (ansiIndex(key["bright-".len..])) |i| scheme.palette[8 + i] = color;
            }
        },
    }
}

test "empty is default" {
    const cfg = try parse("");
    try std.testing.expectEqual(Grid.Color.default_fg, cfg.scheme.fg);
    try std.testing.expectEqual(Grid.Color.default_bg, cfg.scheme.bg);
    try std.testing.expectEqual(Grid.vga_palette[1].r, cfg.scheme.palette[1].r);
    try std.testing.expectEqual(@as(u32, 30), cfg.hz);
    try std.testing.expectEqual(false, cfg.whitelist);
    try std.testing.expectEqual(@as(u8, 0), cfg.font_family_len);
}

test "integer settings retain precision and reject overflow" {
    const cfg = try parse("[general]\npad = 16_777_217\nhz = +4_294_967_295\n");
    try std.testing.expectEqual(@as(u32, 16_777_217), cfg.pad_px);
    try std.testing.expectEqual(std.math.maxInt(u32), cfg.hz);
    for ([_][]const u8{ "4294967296", "4294967295.0", "9999999999999999999999999999999999999999999999999", "-1", "1.5", "1__0", "_10", "10_" }) |value| {
        for ([_][]const u8{ "pad", "hz" }) |key| {
            const src = try std.fmt.allocPrint(std.testing.allocator, "[general]\n{s} = {s}\n", .{ key, value });
            defer std.testing.allocator.free(src);
            try std.testing.expectError(error.InvalidToml, parse(src));
        }
    }
    try std.testing.expectError(error.InvalidToml, parse("[font]\nsize = 1e1000\n"));
}

test "unrelated TOML values and array tables preserve supported settings" {
    const cfg = try parse(
        \\foreground = "#123456"
        \\scientific = 1e2
        \\negative = -1.5
        \\separated = 1_000
        \\timestamp = 1979-05-27 07:32:00Z
        \\escaped = "a \"quote\" and \u0041"
        \\multiline = """
        \\not a [table] # still a string
        \\"""
        \\items = [
        \\  # ] } are inside a comment
        \\  { nested = [1e2, ']', { literal = '''multi
        \\line ] }''' }] },
        \\]
        \\[font]
        \\unknown = { family = "Wrong Family" }
        \\size = 1_0.5e0
        \\[[keyboard.bindings]]
        \\key = "Return"
        \\chars = "\u001B[13;2u"
        \\["unrelated".settings]
        \\"quoted.key" = "\u0041"
        \\[general]
        \\pad = 3
        \\
    );
    try std.testing.expectEqual(@as(u8, 0x12), cfg.scheme.fg.r);
    try std.testing.expectEqual(@as(f32, 10.5), cfg.font_size);
    try std.testing.expectEqual(@as(u32, 3), cfg.pad_px);
    try std.testing.expect(cfg.family() == null);
    const array_cfg = try parse("[[font]]\nsize = 99\nfamily = 'Wrong Family'\n");
    try std.testing.expectEqual(@as(f32, 0), array_cfg.font_size);
    try std.testing.expect(array_cfg.family() == null);
    // A malformed unrelated value must still reject the overlay atomically.
    try std.testing.expectError(error.InvalidToml, parse("[font]\nsize = 12\nunknown = [1, {a = 2]\n"));
    try std.testing.expectError(error.InvalidToml, parse("unknown = \"unterminated\n"));
}

test "font strings decode basic escapes and preserve literal backslashes" {
    const cfg = try parse(
        \\[font]
        \\family = "Example \"Mono\""
        \\fallbacks = ["Noto Sans Symbols \u0032", "\U0001f600", 'literal\t']
        \\
    );
    try std.testing.expectEqualStrings("Example \"Mono\"", cfg.family().?);
    const names = cfg.fallbackFamilies();
    try std.testing.expectEqualStrings("Noto Sans Symbols 2", names[0].slice());
    try std.testing.expectEqualStrings("😀", names[1].slice());
    try std.testing.expectEqualStrings("literal\\t", names[2].slice());
    for ([_][]const u8{ "\\uD800", "\\U00110000", "\\u123", "\\q", "\\u0000" }) |value| {
        const src = try std.fmt.allocPrint(std.testing.allocator, "[font]\nfamily = \"{s}\"\n", .{value});
        defer std.testing.allocator.free(src);
        try std.testing.expectError(error.InvalidToml, parse(src));
    }
}

test "font size fallback requires an actual Omarchy theme file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/colors.toml", .{path_buf[0..dir_len]});
    defer std.testing.allocator.free(path);
    try std.testing.expectEqual(@as(f32, 8), fontSizeFallback(io, null));
    try std.testing.expectEqual(@as(f32, 8), fontSizeFallback(io, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "colors.toml", .data = "foreground = '#ffffff'\n" });
    try std.testing.expectEqual(@as(f32, 9), fontSizeFallback(io, path));
    try std.testing.expectEqual(@as(f32, 8), fontSizeFallback(io, path_buf[0..dir_len]));
}

test "alacritty tables" {
    const cfg = try parse(
        \\# comment
        \\[colors]
        \\foreground = "#fefefe"
        \\background = "#010203"
        \\cursor = "#aabbcc"
        \\
        \\[colors.normal]
        \\red = "#ff0000"
        \\black = "#111111"
        \\
        \\[colors.bright]
        \\white = "#f0f0f0"
        \\
    );
    const s = cfg.scheme;
    try std.testing.expectEqual(@as(u8, 0xfe), s.fg.r);
    try std.testing.expectEqual(@as(u8, 0x01), s.bg.r);
    try std.testing.expectEqual(@as(u8, 0x02), s.bg.g);
    try std.testing.expectEqual(@as(u8, 0x03), s.bg.b);
    try std.testing.expectEqual(@as(u8, 0xaa), s.cursor.r);
    try std.testing.expectEqual(@as(u8, 0xff), s.palette[1].r);
    try std.testing.expectEqual(@as(u8, 0x11), s.palette[0].r);
    try std.testing.expectEqual(@as(u8, 0xf0), s.palette[15].r);
}

test "alacritty primary cursor" {
    const s = try parseScheme(
        \\[colors.primary]
        \\background = "#010203"
        \\foreground = "#fefefe"
        \\
        \\[colors.cursor]
        \\text = "#010203"
        \\cursor = "#aabbcc"
        \\
        \\[colors.normal]
        \\black = "#111111"
        \\white = "#eeeeee"
        \\
    );
    try std.testing.expectEqual(@as(u8, 0xfe), s.fg.r);
    try std.testing.expectEqual(@as(u8, 0x01), s.bg.r);
    try std.testing.expectEqual(@as(u8, 0xaa), s.cursor.r);
    try std.testing.expectEqual(@as(u8, 0x11), s.palette[0].r);
    try std.testing.expectEqual(@as(u8, 0xee), s.palette[7].r);
}

test "omarchy colors.toml" {
    const cfg = try parse(
        \\mode = "dark"
        \\accent = "#89b4fa"
        \\muted = "#585b70"
        \\background = "#1e1e2e"
        \\foreground = "#cdd6f4"
        \\bright_foreground = "#ffffff"
        \\red = "#f38ba8"
        \\bright_red = "#f38ba8"
        \\
    );
    const s = cfg.scheme;
    try std.testing.expectEqual(@as(u8, 0x1e), s.bg.r);
    try std.testing.expectEqual(@as(u8, 0xcd), s.fg.r);
    try std.testing.expectEqual(@as(u8, 0xff), s.cursor.r);
    try std.testing.expectEqual(@as(u8, 0x1e), s.palette[0].r);
    try std.testing.expectEqual(@as(u8, 0xcd), s.palette[7].r);
    try std.testing.expectEqual(@as(u8, 0x58), s.palette[8].r);
    try std.testing.expectEqual(@as(u8, 0xff), s.palette[15].r);
    try std.testing.expectEqual(@as(u8, 0xf3), s.palette[1].r);
    try std.testing.expectEqual(@as(u8, 0xf3), s.palette[9].r);
}

test "font table" {
    const cfg = try parse(
        \\[font]
        \\family = "Terminess Nerd Font Mono"
        \\size = 8.5
        \\
    );
    try std.testing.expectEqualStrings("Terminess Nerd Font Mono", cfg.family().?);
    try std.testing.expectEqual(@as(f32, 8.5), cfg.font_size);
}

test "font fallbacks preserve order and own their names" {
    var src = ("[font]\n" ++
        "family = 'Primary'\n" ++
        "fallbacks = [\n" ++
        "  'Symbols', # first choice\n" ++
        "  \"Emoji\",\n" ++
        "]\n").*;
    const cfg = try parse(&src);
    @memset(&src, 0);
    try std.testing.expectEqualStrings("Primary", cfg.family().?);
    const names = cfg.fallbackFamilies();
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("Symbols", names[0].slice());
    try std.testing.expectEqualStrings("Emoji", names[1].slice());
}

test "font fallback overlays replace or clear only when specified" {
    const base = try parse("[font]\nfallbacks = ['First', 'Second']\n");
    const kept = try parseInto("[font]\nsize = 12\n", base);
    try std.testing.expectEqualStrings("Second", kept.fallbackFamilies()[1].slice());
    const replaced = try parseInto("[fonts]\nfallbacks = ['Other']\n", kept);
    try std.testing.expectEqual(@as(usize, 1), replaced.fallbackFamilies().len);
    try std.testing.expectEqualStrings("Other", replaced.fallbackFamilies()[0].slice());
    const cleared = try parseInto("[font]\nfallbacks = []\n", replaced);
    try std.testing.expectEqual(@as(usize, 0), cleared.fallbackFamilies().len);
    const unrelated = try parseInto("[other]\nfallbacks = ['Ignored']\n", base);
    try std.testing.expectEqual(@as(usize, 2), unrelated.fallbackFamilies().len);
}

test "font fallback arrays reject invalid entries and delimiters" {
    for ([_][]const u8{
        "'not an array'", "[1]",                "['']",        "['   ']",     "['nul\x00name']",
        "[['Nested']]",   "['First' 'Second']", "['First',,]", "[, 'First']", "['First'",
    }) |value| {
        const src = try std.fmt.allocPrint(std.testing.allocator, "[font]\nfallbacks = {s}\n", .{value});
        defer std.testing.allocator.free(src);
        try std.testing.expectError(error.InvalidToml, parse(src));
    }
}

test "font fallback limits are checked without truncation" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "[font]\nfallbacks = [");
    for (0..max_font_fallbacks) |_| {
        try src.append(std.testing.allocator, '\'');
        try src.appendNTimes(std.testing.allocator, 'a', max_font_family);
        try src.appendSlice(std.testing.allocator, "',");
    }
    try src.append(std.testing.allocator, ']');
    const cfg = try parse(src.items);
    try std.testing.expectEqual(@as(usize, max_font_fallbacks), cfg.fallbackFamilies().len);
    try std.testing.expectEqual(@as(usize, max_font_family), cfg.fallbackFamilies()[0].slice().len);
    src.items.len -= 1;
    try src.appendSlice(std.testing.allocator, "'Extra']");
    try std.testing.expectError(error.InvalidToml, parse(src.items));
    src.clearRetainingCapacity();
    try src.appendSlice(std.testing.allocator, "[font]\nfallbacks = ['");
    try src.appendNTimes(std.testing.allocator, 'a', max_font_family + 1);
    try src.appendSlice(std.testing.allocator, "']");
    try std.testing.expectError(error.InvalidToml, parse(src.items));
}

test "alacritty font inline" {
    const cfg = try parse(
        \\general.import = [ "~/.local/state/omarchy/current/theme/alacritty.toml" ]
        \\
        \\[font]
        \\normal = { family = "Terminess Nerd Font Mono", style = "Regular" }
        \\bold = { family = "Other", style = "Bold" }
        \\size = 8
        \\
        \\[window]
        \\padding.x = 14
        \\decorations = "None"
        \\
        \\[keyboard]
        \\bindings = [
        \\{ key = "Return", chars = "\u001B[13;2u" }
        \\]
        \\
    );
    try std.testing.expectEqualStrings("Terminess Nerd Font Mono", cfg.family().?);
    try std.testing.expectEqual(@as(f32, 8), cfg.font_size);
}

test "short hex and aliases" {
    const s = try parseScheme(
        \\fg = '#abc'
        \\bg = "#123"
        \\bright_red = "#f00"
        \\
        \\[normal]
        \\green = "#0f0"
        \\
    );
    try std.testing.expectEqual(@as(u8, 0xaa), s.fg.r);
    try std.testing.expectEqual(@as(u8, 0xbb), s.fg.g);
    try std.testing.expectEqual(@as(u8, 0xcc), s.fg.b);
    try std.testing.expectEqual(@as(u8, 0x11), s.bg.r);
    try std.testing.expectEqual(@as(u8, 0xff), s.palette[9].r);
    try std.testing.expectEqual(@as(u8, 0x00), s.palette[2].r);
    try std.testing.expectEqual(@as(u8, 0xff), s.palette[2].g);
}

test "general refreshrate" {
    const cfg = try parse(
        \\[general]
        \\refreshrate = 144
        \\foreground = "#ffffff"
        \\
    );
    try std.testing.expectEqual(@as(u32, 144), cfg.hz);
    try std.testing.expectEqual(@as(u8, 0xff), cfg.scheme.fg.r);

    const alias = try parse(
        \\[general]
        \\hz = 30
        \\
    );
    try std.testing.expectEqual(@as(u32, 30), alias.hz);
    try std.testing.expectEqual(false, alias.whitelist);

    const wl = try parse(
        \\[general]
        \\whitelist = true
        \\
    );
    try std.testing.expect(wl.whitelist);

    const wl_off = try parse(
        \\[general]
        \\whitelist = false
        \\
    );
    try std.testing.expectEqual(false, wl_off.whitelist);

    const pad = try parse(
        \\[general]
        \\pad = 8
        \\
    );
    try std.testing.expectEqual(@as(u32, 8), pad.pad_px);

    const padding = try parse(
        \\[general]
        \\padding = 0
        \\
    );
    try std.testing.expectEqual(@as(u32, 0), padding.pad_px);
}

test "overlay keeps unset fields" {
    const base = try parse(
        \\[general]
        \\hz = 120
        \\[font]
        \\family = "Iosevka"
        \\size = 14
        \\
    );
    const cfg = try parseInto(
        \\foreground = "#ffffff"
        \\
    , base);
    try std.testing.expectEqual(@as(u32, 120), cfg.hz);
    try std.testing.expectEqualStrings("Iosevka", cfg.family().?);
    try std.testing.expectEqual(@as(f32, 14), cfg.font_size);
    try std.testing.expectEqual(@as(u8, 0xff), cfg.scheme.fg.r);
}

test "invalid" {
    try std.testing.expectError(error.InvalidToml, parse("[]\n"));
    try std.testing.expectError(error.InvalidToml, parse("[general]\nrefreshrate = 0\n"));
    try std.testing.expectError(error.InvalidToml, parse("[general]\nrefreshrate = \"60\"\n"));
    try std.testing.expectError(error.InvalidToml, parse("[general]\nwhitelist = 1\n"));
    try std.testing.expectError(error.InvalidToml, parse("[general]\nwhitelist = \"true\"\n"));
    const ignored = try parse("foreground = \"#gg0000\"\nmode = \"dark\"\nforeground = 1\n");
    try std.testing.expectEqual(Grid.Color.default_fg, ignored.scheme.fg);
}

test "parse error position reports line and column" {
    var err: ParseErrorPos = .{};
    try std.testing.expectError(error.InvalidToml, parseIntoPos("[font]\nsize = 12\n\nbad line here\n", .{}, &err));
    try std.testing.expectEqual(@as(u32, 4), err.line);
    try std.testing.expect(err.col >= 1);
    try std.testing.expect(err.pos >= 16);
    _ = try parseIntoPos("[font]\nsize = 12\n", .{}, &err);
}

test "error position helper" {
    const e = errorPos("ab\ncd", 4);
    try std.testing.expectEqual(@as(u32, 2), e.line);
    try std.testing.expectEqual(@as(u32, 2), e.col);
    try std.testing.expectEqual(@as(u32, 1), errorPos("x", 99).line);
}

test "default font size per OS" {
    try std.testing.expectEqual(@as(f32, 12), defaultFontSize(.windows, false));
    try std.testing.expectEqual(@as(f32, 12), defaultFontSize(.macos, true));
    try std.testing.expectEqual(@as(f32, 8), defaultFontSize(.linux, false));
    try std.testing.expectEqual(@as(f32, 9), defaultFontSize(.linux, true));
}

test "config path selection order" {
    const Fake = struct {
        present: []const []const u8,
        fn has(self: @This(), path: []const u8) bool {
            for (self.present) |p| if (std.mem.eql(u8, p, path)) return true;
            return false;
        }
    };
    const cands = [_]?[]const u8{ "xdg", null, "native", "home" };
    try std.testing.expectEqualStrings("xdg", pickConfigPath(&cands, Fake{ .present = &.{ "xdg", "native", "home" } }, Fake.has).?);
    try std.testing.expectEqualStrings("native", pickConfigPath(&cands, Fake{ .present = &.{ "native", "home" } }, Fake.has).?);
    try std.testing.expectEqualStrings("home", pickConfigPath(&cands, Fake{ .present = &.{"home"} }, Fake.has).?);
    try std.testing.expectEqualStrings("xdg", pickConfigPath(&cands, Fake{ .present = &.{} }, Fake.has).?);
    const none = [_]?[]const u8{ null, null };
    try std.testing.expect(pickConfigPath(&none, Fake{ .present = &.{} }, Fake.has) == null);
}

test "diagnostics queue is bounded and drained" {
    diag_visible_override = false;
    defer diag_visible_override = null;
    _ = takeDiagnostics();
    report("invalid config {s} line {d}", .{ "x.toml", 3 });
    const got = takeDiagnostics();
    try std.testing.expect(std.mem.indexOf(u8, got, "x.toml line 3") != null);
    try std.testing.expectEqual(@as(usize, 0), takeDiagnostics().len);
    for (0..100) |_| report("filler filler filler filler filler filler", .{});
    try std.testing.expect(takeDiagnostics().len <= diag_store.len);
}
