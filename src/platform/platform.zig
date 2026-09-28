//! platform.zig
//!
//! Window, clipboard, and PTY go through Peak (`godstack/Peak`). Peak picks
//! Wayland, then X11. This file maps Peak events onto the terminal's Event.

const std = @import("std");
const builtin = @import("builtin");
const peak = @import("peak.zig");

pub const Dimensions = struct {
    cols: u16,
    rows: u16,
    px_w: u16 = 0,
    px_h: u16 = 0,
};

pub const Event = union(enum) {
    pub const KeyMod = packed struct {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        super: bool = false,
    };

    pub const KeyEvent = struct {
        key: KeyCode,
        mods: KeyMod,
        /// Unicode (unshifted when possible) for kitty / modifyOtherKeys.
        cp: u21 = 0,
    };

    pub const MouseWheel = struct {
        up: bool,
        x: i32,
        y: i32,
        mods: KeyMod,
        steps: u8 = 1,
    };

    pub const Mouse = struct {
        button: u8 = 0,
        x: i32 = 0,
        y: i32 = 0,
        mods: KeyMod = .{},
        time: u32 = 0,
    };

    pub const Clipboard = enum { clipboard, primary };

    pub const KeyCode = enum {
        a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z,
        num_0, num_1, num_2, num_3, num_4, num_5, num_6, num_7, num_8, num_9,
        enter, escape, backspace, tab, space,
        arrow_up, arrow_down, arrow_left, arrow_right,
        page_up, page_down, home, end, insert, delete,
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
        unknown,
    };

    key_press: KeyEvent,
    key_release: KeyEvent,
    mouse_wheel: MouseWheel,
    mouse_down: Mouse,
    mouse_up: Mouse,
    mouse_move: Mouse,
    paste_request: Clipboard,
    copy_request,
    paste: []const u8,
    text_input: [64]u8, // UTF-8 from the keyboard, after compose / dead keys
    resize: Dimensions,
    /// Window contents were lost (Expose) or need a full present.
    redraw,
    focus_gained,
    focus_lost,
    quit,
};

pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    stride: u32,

    pub fn clear(self: *Framebuffer, color: u32) void {
        @memset(self.pixels, color);
    }
};

/// Simple window interface to be implement by the platform.
pub const Window = struct {
    impl: Backend,

    const Backend = switch (builtin.os.tag) {
        .linux => PeakWindow,
        else => @compileError("Unsupported operating system for platform layer"),
    };

    pub fn open(allocator: std.mem.Allocator, title: [*:0]const u8, class: [*:0]const u8, width: u32, height: u32) !Window {
        var win: Window = undefined;
        try win.impl.open(allocator, title, class, width, height);
        return win;
    }

    pub fn close(self: *Window) void {
        self.impl.close();
    }

    pub fn present(self: *Window) void {
        self.impl.present();
    }

    pub fn pollEvent(self: *Window, ev: *Event) bool {
        return self.impl.pollEvent(ev);
    }

    pub fn eventsPending(self: *Window) bool {
        return self.impl.eventsPending();
    }

    pub fn setAllMotion(self: *Window, on: bool) void {
        self.impl.setAllMotion(on);
    }

    /// Display connection fd. Poll with the PTY; do not read it.
    pub fn eventFd(self: *Window) std.posix.fd_t {
        return self.impl.eventFd();
    }

    pub fn requestPaste(self: *Window) void {
        self.impl.requestPasteFrom(.clipboard);
    }

    pub fn requestPasteFrom(self: *Window, src: Event.Clipboard) void {
        self.impl.requestPasteFrom(src);
    }

    pub fn setClipboard(self: *Window, text: []const u8) void {
        self.impl.setClipboard(text);
    }

    pub fn setPrimary(self: *Window, text: []const u8) void {
        self.impl.setPrimary(text);
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        self.impl.setTitle(title);
    }

    pub fn setClass(self: *Window, class: [:0]const u8) void {
        self.impl.setClass(class);
    }

    pub fn setOpacity(self: *Window, alpha: u8) void {
        self.impl.setOpacity(alpha);
    }

    pub fn setPointer(self: *Window, shape: u8) void {
        self.impl.setPointer(shape);
    }

    pub fn framebuffer(self: *Window) *Framebuffer {
        return &self.impl.framebuffer;
    }
};

/// CSS 96. Font pixels use the desktop scale, not X11 mm-DPI.
pub fn screenDpi() f32 {
    return 96;
}

/// Child process to run in the PTY. Empty `argv` means `$SHELL` (or `/bin/sh`).
pub const Spawn = struct {
    argv: []const [*:0]const u8 = &.{},
    cwd: ?[*:0]const u8 = null,
};

/// Pseudo-terminal interface implemented by the platform backends.
pub const Pty = struct {
    impl: PtyImpl,

    const PtyImpl = switch (builtin.os.tag) {
        .linux => PeakPty,
        else => @compileError("Unsupported operating system for PTY platform layer"),
    };

    pub fn open(dims: Dimensions, spawn: Spawn) !Pty {
        var pty: Pty = undefined;
        try pty.impl.open(dims, spawn);
        return pty;
    }

    pub fn close(self: *Pty) void {
        self.impl.close();
    }

    pub fn write(self: *Pty, bytes: []const u8) void {
        self.impl.write(bytes);
    }

    pub fn read(self: *Pty, buf: []u8) error{Hangup}![]u8 {
        return self.impl.read(buf);
    }

    pub fn setWinsize(self: *Pty, dims: Dimensions) void {
        self.impl.setWinsize(dims);
    }

    pub fn fd(self: *const Pty) std.posix.fd_t {
        return self.impl.fd();
    }
};

const PeakWindow = struct {
    win: peak.Window = undefined,
    framebuffer: Framebuffer = .{ .pixels = &.{}, .width = 0, .height = 0, .stride = 0 },
    paste: []u8 = &.{},
    gpa: std.mem.Allocator = std.heap.page_allocator,

    pub fn open(self: *PeakWindow, allocator: std.mem.Allocator, title: [*:0]const u8, class: [*:0]const u8, width: u32, height: u32) !void {
        if (!peak.init()) return error.CannotOpenDisplay;
        const win = peak.windowOpen(std.mem.span(title), width, height, .{});
        if (!win.live()) {
            peak.quit();
            return error.CannotOpenDisplay;
        }
        self.* = .{
            .win = win,
            .gpa = allocator,
        };
        self.syncFb();
        if (class[0] != 0) self.setClass(std.mem.span(class));
    }

    pub fn close(self: *PeakWindow) void {
        if (self.paste.len != 0) self.gpa.free(self.paste);
        self.paste = &.{};
        self.win.close();
        peak.quit();
    }

    pub fn present(self: *PeakWindow) void {
        self.win.present();
    }

    pub fn eventFd(self: *PeakWindow) std.posix.fd_t {
        return self.win.fd();
    }

    pub fn eventsPending(self: *PeakWindow) bool {
        return self.win.pending() != 0;
    }

    /// Peak delivers motion whenever the pointer is in the window.
    pub fn setAllMotion(self: *PeakWindow, on: bool) void {
        _ = self;
        _ = on;
    }

    pub fn setTitle(self: *PeakWindow, title: [:0]const u8) void {
        self.win.setTitle(title);
    }

    pub fn setClass(self: *PeakWindow, class: [:0]const u8) void {
        self.win.setClass(class);
    }

    pub fn setOpacity(self: *PeakWindow, alpha: u8) void {
        self.win.setOpacity(alpha);
    }

    /// Peak cursor shapes: 0 default, 1 text, 2 hand, 3 wait, 4 crosshair, 5 not-allowed, 6 help.
    pub fn setPointer(self: *PeakWindow, shape: u8) void {
        self.win.setCursorShape(shape);
    }

    pub fn setClipboard(self: *PeakWindow, text: []const u8) void {
        _ = peak.clipSet(&self.win, .clipboard, text);
    }

    pub fn setPrimary(self: *PeakWindow, text: []const u8) void {
        _ = peak.clipSet(&self.win, .primary, text);
    }

    pub fn requestPasteFrom(self: *PeakWindow, src: Event.Clipboard) void {
        _ = peak.clipRequest(&self.win, switch (src) {
            .clipboard => .clipboard,
            .primary => .primary,
        });
    }

    pub fn pollEvent(self: *PeakWindow, ev: *Event) bool {
        while (self.win.epoll()) |raw| {
            switch (raw) {
                .none, .last, .pointer_connected, .pointer_disconnected, .drop => continue,
                .window_close => {
                    ev.* = .quit;
                    return true;
                },
                .window_resize => {
                    self.syncFb();
                    ev.* = .{ .resize = .{
                        .cols = @intCast(@max(1, self.framebuffer.width / 8)),
                        .rows = @intCast(@max(1, self.framebuffer.height / 16)),
                        .px_w = @intCast(@min(self.framebuffer.width, std.math.maxInt(u16))),
                        .px_h = @intCast(@min(self.framebuffer.height, std.math.maxInt(u16))),
                    } };
                    return true;
                },
                .expose => {
                    ev.* = .redraw;
                    return true;
                },
                .focus => |on| {
                    ev.* = if (on) .focus_gained else .focus_lost;
                    return true;
                },
                .key_down => |k| {
                    if (isPaste(k)) {
                        ev.* = .{ .paste_request = .clipboard };
                        return true;
                    }
                    if (isCopy(k)) {
                        ev.* = .copy_request;
                        return true;
                    }
                    if (k.key == .tab and k.mod.shift) {
                        ev.* = .{ .key_press = .{ .key = .tab, .mods = modsOf(k.mod), .cp = 9 } };
                        return true;
                    }
                    if (specialKey(k.key)) |key| {
                        ev.* = .{ .key_press = .{ .key = key, .mods = modsOf(k.mod), .cp = cpOf(k.key) } };
                        return true;
                    }
                    if (k.mod.ctrl or k.mod.alt or k.mod.super) {
                        if (letterKey(k.key)) |key| {
                            ev.* = .{ .key_press = .{ .key = key, .mods = modsOf(k.mod), .cp = cpOf(k.key) } };
                            return true;
                        }
                        continue;
                    }
                    // Printable keys arrive as PEAK_EVENT_TEXT. Swallow the key.
                    continue;
                },
                .key_up => |k| {
                    if (specialKey(k.key)) |key| {
                        ev.* = .{ .key_release = .{ .key = key, .mods = modsOf(k.mod) } };
                        return true;
                    }
                },
                .text => {
                    var text: [64]u8 = @splat(0);
                    const n = peak.textTake(&self.win, &text) orelse continue;
                    if (n < text.len) text[n] = 0;
                    ev.* = .{ .text_input = text };
                    return true;
                },
                .clip => {
                    const n = peak.clipTake(&self.win, self.ensurePaste(1 << 20)) orelse continue;
                    ev.* = .{ .paste = self.paste[0..n] };
                    return true;
                },
                .pointer => |p| {
                    const x: i32 = @intFromFloat(p.x);
                    const y: i32 = @intFromFloat(p.y);
                    const m = modsOf(p.mod);
                    switch (p.kind) {
                        .wheel_up, .wheel_down => {
                            if (p.state != .pressed) continue;
                            ev.* = .{ .mouse_wheel = .{
                                .up = p.kind == .wheel_up,
                                .x = x,
                                .y = y,
                                .mods = m,
                            } };
                            return true;
                        },
                        .left, .right, .middle, .touch => {
                            const button: u8 = switch (p.kind) {
                                .right => 3,
                                .middle => 2,
                                .touch => 1,
                                else => 1,
                            };
                            const mouse = Event.Mouse{
                                .button = button,
                                .x = x,
                                .y = y,
                                .mods = m,
                                .time = nowMs(),
                            };
                            switch (p.state) {
                                .pressed => ev.* = .{ .mouse_down = mouse },
                                .released => ev.* = .{ .mouse_up = mouse },
                                .moved => {
                                    var move = mouse;
                                    move.button = 0;
                                    ev.* = .{ .mouse_move = move };
                                },
                            }
                            return true;
                        },
                    }
                },
            }
        }
        return false;
    }

    fn syncFb(self: *PeakWindow) void {
        const px = self.win.backbuffer();
        self.framebuffer = .{
            .pixels = px,
            .width = self.win.width,
            .height = self.win.height,
            .stride = self.win.width,
        };
    }

    fn ensurePaste(self: *PeakWindow, n: usize) []u8 {
        if (self.paste.len >= n) return self.paste;
        if (self.paste.len != 0) self.gpa.free(self.paste);
        self.paste = self.gpa.alloc(u8, n) catch return &.{};
        return self.paste;
    }
};

const PeakPty = struct {
    proc: peak.Proc = .{ .fd = peak.handle_invalid, .pid = 0 },

    pub fn open(self: *PeakPty, dims: Dimensions, spawn: Spawn) !void {
        var argv_buf: [65]?[*:0]const u8 = undefined;
        const file: [*:0]const u8 = if (spawn.argv.len == 0) blk: {
            const shell = shellPath();
            argv_buf[0] = shell;
            argv_buf[1] = null;
            break :blk shell;
        } else blk: {
            if (spawn.argv.len >= argv_buf.len) return error.OpenPty;
            for (spawn.argv, 0..) |arg, i| argv_buf[i] = arg;
            argv_buf[spawn.argv.len] = null;
            break :blk spawn.argv[0];
        };

        var cwd_buf: [4096]u8 = undefined;
        const back: ?[*:0]u8 = if (spawn.cwd != null) getcwd(&cwd_buf, cwd_buf.len) else null;
        if (spawn.cwd) |dir| {
            if (chdir(dir) != 0) return error.OpenPty;
        }
        defer if (back) |dir| {
            _ = chdir(dir);
        };

        pushChildEnv();
        defer popChildEnv();

        self.proc = peak.ptySpawn(std.mem.span(file), @ptrCast(&argv_buf), dims.cols, dims.rows, dims.px_w, dims.px_h) orelse return error.OpenPty;
    }

    pub fn close(self: *PeakPty) void {
        peak.ptyClose(&self.proc);
    }

    pub fn fd(self: *const PeakPty) std.posix.fd_t {
        return self.proc.fd;
    }

    pub fn write(self: *PeakPty, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            switch (peak.fdWrite(self.proc.fd, bytes[off..])) {
                .n => |n| {
                    if (n == 0) return;
                    off += n;
                },
                .would_block, .eof => return,
            }
        }
    }

    pub fn read(self: *PeakPty, buf: []u8) error{Hangup}![]u8 {
        return switch (peak.fdRead(self.proc.fd, buf)) {
            .would_block => buf[0..0],
            .eof => error.Hangup,
            .n => |n| buf[0..n],
        };
    }

    pub fn setWinsize(self: *PeakPty, dims: Dimensions) void {
        peak.ptyResize(&self.proc, dims.cols, dims.rows, dims.px_w, dims.px_h);
        var pgrp: std.os.linux.pid_t = 0;
        if (std.os.linux.tcgetpgrp(self.proc.fd, &pgrp) == 0 and pgrp > 1) {
            _ = std.os.linux.kill(-pgrp, std.os.linux.SIG.WINCH);
        } else if (self.proc.pid > 1) {
            _ = std.os.linux.kill(self.proc.pid, std.os.linux.SIG.WINCH);
        }
    }
};

fn modsOf(m: peak.KeyMod) Event.KeyMod {
    return .{
        .shift = m.shift,
        .ctrl = m.ctrl,
        .alt = m.alt,
        .super = m.super,
    };
}

fn isCopy(k: peak.Key) bool {
    return k.mod.ctrl and k.mod.shift and !k.mod.alt and k.key == .c;
}

fn isPaste(k: peak.Key) bool {
    if (k.mod.shift and !k.mod.ctrl and !k.mod.alt and k.key == .insert) return true;
    return k.mod.ctrl and k.mod.shift and !k.mod.alt and k.key == .v;
}

fn letterKey(key: peak.KeyCode) ?Event.KeyCode {
    return switch (key) {
        .a => .a,
        .b => .b,
        .c => .c,
        .d => .d,
        .e => .e,
        .f => .f,
        .g => .g,
        .h => .h,
        .i => .i,
        .j => .j,
        .k => .k,
        .l => .l,
        .m => .m,
        .n => .n,
        .o => .o,
        .p => .p,
        .q => .q,
        .r => .r,
        .s => .s,
        .t => .t,
        .u => .u,
        .v => .v,
        .w => .w,
        .x => .x,
        .y => .y,
        .z => .z,
        .@"0" => .num_0,
        .@"1" => .num_1,
        .@"2" => .num_2,
        .@"3" => .num_3,
        .@"4" => .num_4,
        .@"5" => .num_5,
        .@"6" => .num_6,
        .@"7" => .num_7,
        .@"8" => .num_8,
        .@"9" => .num_9,
        .space => .space,
        else => null,
    };
}

fn specialKey(key: peak.KeyCode) ?Event.KeyCode {
    return switch (key) {
        .enter => .enter,
        .escape => .escape,
        .backspace => .backspace,
        .tab => .tab,
        .up => .arrow_up,
        .down => .arrow_down,
        .left => .arrow_left,
        .right => .arrow_right,
        .page_up => .page_up,
        .page_down => .page_down,
        .home => .home,
        .end => .end,
        .insert => .insert,
        .delete => .delete,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
        else => null,
    };
}

fn cpOf(key: peak.KeyCode) u21 {
    return switch (key) {
        .a => 'a',
        .b => 'b',
        .c => 'c',
        .d => 'd',
        .e => 'e',
        .f => 'f',
        .g => 'g',
        .h => 'h',
        .i => 'i',
        .j => 'j',
        .k => 'k',
        .l => 'l',
        .m => 'm',
        .n => 'n',
        .o => 'o',
        .p => 'p',
        .q => 'q',
        .r => 'r',
        .s => 's',
        .t => 't',
        .u => 'u',
        .v => 'v',
        .w => 'w',
        .x => 'x',
        .y => 'y',
        .z => 'z',
        .@"0" => '0',
        .@"1" => '1',
        .@"2" => '2',
        .@"3" => '3',
        .@"4" => '4',
        .@"5" => '5',
        .@"6" => '6',
        .@"7" => '7',
        .@"8" => '8',
        .@"9" => '9',
        .space => ' ',
        .tab => 9,
        else => 0,
    };
}

fn nowMs() u32 {
    return @truncate(peak.time() / 1_000_000);
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
extern "c" fn chdir(path: [*:0]const u8) c_int;

fn shellPath() [*:0]const u8 {
    if (getenv("SHELL")) |s| {
        if (s[0] != 0) return s;
    }
    return "/bin/sh";
}

const Saved = struct {
    had: bool = false,
    buf: [256]u8 = undefined,
    n: usize = 0,
};

var save_term: Saved = .{};
var save_color: Saved = .{};
var save_prog: Saved = .{};
var save_kitty: Saved = .{};
var save_listen: Saved = .{};

fn remember(slot: *Saved, key: [:0]const u8) void {
    slot.* = .{};
    const v = getenv(key) orelse return;
    const span = std.mem.span(v);
    const n = @min(span.len, slot.buf.len - 1);
    @memcpy(slot.buf[0..n], span[0..n]);
    slot.buf[n] = 0;
    slot.n = n;
    slot.had = true;
}

fn restore(slot: *Saved, key: [:0]const u8) void {
    if (!slot.had) {
        _ = unsetenv(key);
        return;
    }
    slot.buf[slot.n] = 0;
    _ = setenv(key, slot.buf[0..slot.n :0], 1);
}

fn pushChildEnv() void {
    remember(&save_term, "TERM");
    remember(&save_color, "COLORTERM");
    remember(&save_prog, "TERM_PROGRAM");
    remember(&save_kitty, "KITTY_WINDOW_ID");
    remember(&save_listen, "KITTY_LISTEN_ON");
    _ = setenv("TERM", "xterm-256color", 1);
    _ = setenv("COLORTERM", "truecolor", 1);
    _ = setenv("TERM_PROGRAM", "velocitty", 1);
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "{d}", .{peak.pid()}) catch "1";
    _ = setenv("KITTY_WINDOW_ID", id, 1);
    _ = unsetenv("KITTY_LISTEN_ON");
}

fn popChildEnv() void {
    restore(&save_term, "TERM");
    restore(&save_color, "COLORTERM");
    restore(&save_prog, "TERM_PROGRAM");
    restore(&save_kitty, "KITTY_WINDOW_ID");
    restore(&save_listen, "KITTY_LISTEN_ON");
}
