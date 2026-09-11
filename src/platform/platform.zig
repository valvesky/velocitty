//! platform.zig
//!
//! As a terminal emulator, there are a few things we need from
//! the operating system:
//! - Opening a window.
//! - Window bitmap to write to directly.
//! - PTY / filedescriptors
//! - Clipboard.
//! - Keypresses.

const std = @import("std");
const builtin = @import("builtin");
const Linux = @import("linux.zig");

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
    };

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
    text_input: [32]u8, // UTF-8 encoded text stream from OS IME/Keyboard
    resize: struct { cols: u16, rows: u16, px_w: u32, px_h: u32 },
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
    impl: Impl,

    const Impl = switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd => Linux.Window,
        else => @compileError("Unsupported operating system for platform layer"),
    };

    pub fn open(allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32) !Window {
        var win: Window = undefined;
        try win.impl.open(allocator, title, width, height);
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

    pub fn getClipboard(self: *Window, gpa: std.mem.Allocator) ?[]const u8 {
        return self.impl.getClipboard(gpa);
    }

    pub fn setClipboard(self: *Window, text: []const u8) void {
        self.impl.setClipboard(text);
    }

    pub fn framebuffer(self: *Window) *Framebuffer {
        return &self.impl.framebuffer;
    }
};
