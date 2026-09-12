//! linux.zig

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const Platform = @import("platform.zig");

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/keysym.h");
});

pub const Window = struct {
    width: u32,
    height: u32,
    framebuffer: Platform.Framebuffer,

    display: *c.Display,
    window: c.Window,
    gc: c.GC,
    image: *c.XImage,

    // Atoms for window management & clipboard
    wm_delete_window: c.Atom,
    atom_clipboard: c.Atom,
    atom_targets: c.Atom,
    atom_utf8: c.Atom,
    atom_selection_prop: c.Atom,

    gpa: std.mem.Allocator,

    pub fn open(self: *Window, allocator: std.mem.Allocator, title: []const u8, width: u32, height: u32) !void {
        self.gpa = allocator;
        self.width = width;
        self.height = height;

        const display = c.XOpenDisplay(null) orelse return error.CannotOpenDisplay;
        errdefer _ = c.XCloseDisplay(display);

        const screen = c.XDefaultScreen(display);
        const root = c.XRootWindow(display, screen);

        const win = c.XCreateSimpleWindow(
            display,
            root,
            10,
            10,
            width,
            height,
            1,
            c.XBlackPixel(display, screen),
            c.XWhitePixel(display, screen),
        );
        errdefer _ = c.XDestroyWindow(display, win);

        // Select input events
        _ = c.XSelectInput(
            display,
            win,
            c.KeyPressMask |
                c.KeyReleaseMask |
                c.StructureNotifyMask |
                c.FocusChangeMask,
        );

        // Intercept close button clicks
        const wm_delete = c.XInternAtom(display, "WM_DELETE_WINDOW", c.False);
        var protocols = [1]c.Atom{wm_delete};
        _ = c.XSetWMProtocols(display, win, &protocols, 1);

        _ = c.XStoreName(display, win, title.ptr);
        _ = c.XMapWindow(display, win);

        const gc = c.XCreateGC(display, win, 0, null);
        errdefer _ = c.XFreeGC(display, gc);

        // Allocate framebuffer backing store
        const pixels = try allocator.alloc(u32, width * height);
        errdefer allocator.free(pixels);

        const visual = c.XDefaultVisual(display, screen);
        const depth = c.XDefaultDepth(display, screen);

        const image = c.XCreateImage(
            display,
            visual,
            @intCast(depth),
            c.ZPixmap,
            0,
            @ptrCast(pixels.ptr),
            width,
            height,
            32,
            0,
        ) orelse return error.ImageCreationFailed;

        self.display = display;
        self.window = win;
        self.gc = gc;
        self.image = image;

        self.wm_delete_window = wm_delete;
        self.atom_clipboard = c.XInternAtom(display, "CLIPBOARD", c.False);
        self.atom_targets = c.XInternAtom(display, "TARGETS", c.False);
        self.atom_utf8 = c.XInternAtom(display, "UTF8_STRING", c.False);
        self.atom_selection_prop = c.XInternAtom(display, "ZT_SELECTION", c.False);

        self.framebuffer = .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .stride = width,
        };
    }

    pub fn close(self: *Window) void {
        if (self.image.data != null) {
            self.gpa.free(self.framebuffer.pixels);
            self.image.data = null;
            if (self.image.f.destroy_image) |destroy_fn| {
                _ = destroy_fn(self.image);
            }
        }
        _ = c.XFreeGC(self.display, self.gc);
        _ = c.XDestroyWindow(self.display, self.window);
        _ = c.XCloseDisplay(self.display);
    }

    pub fn pollEvent(self: *Window, ev: *Platform.Event) bool {
        while (c.XPending(self.display) > 0) {
            var xev: c.XEvent = undefined;
            _ = c.XNextEvent(self.display, &xev);

            switch (xev.type) {
                c.ClientMessage => {
                    if (@as(c.Atom, @intCast(xev.xclient.data.l[0])) == self.wm_delete_window) {
                        ev.* = .quit;
                        return true;
                    }
                },
                c.ConfigureNotify => {
                    const new_w: u32 = @intCast(xev.xconfigure.width);
                    const new_h: u32 = @intCast(xev.xconfigure.height);
                    if (new_w != self.width or new_h != self.height) {
                        self.resizeFramebuffer(new_w, new_h) catch {};
                        ev.* = .{ .resize = .{
                            .cols = @intCast(new_w / 8),
                            .rows = @intCast(new_h / 16),
                            .px_w = new_w,
                            .px_h = new_h,
                        } };
                        return true;
                    }
                },
                c.KeyPress => {
                    var buf: [32]u8 = undefined;
                    var keysym: c.KeySym = 0;
                    const len = c.XLookupString(&xev.xkey, &buf, buf.len, &keysym, null);

                    if (translateKey(keysym)) |key| {
                        ev.* = .{ .key_press = .{ .key = key, .mods = getMods(xev.xkey.state) } };
                        return true;
                    }

                    if (len > 0) {
                        var text: [32]u8 = undefined;
                        @memset(&text, 0);
                        @memcpy(text[0..@intCast(len)], buf[0..@intCast(len)]);
                        ev.* = .{ .text_input = text };
                        return true;
                    }
                },
                c.KeyRelease => {
                    var keysym: c.KeySym = 0;
                    _ = c.XLookupString(&xev.xkey, null, 0, &keysym, null);
                    if (translateKey(keysym)) |key| {
                        ev.* = .{ .key_release = .{ .key = key, .mods = getMods(xev.xkey.state) } };
                        return true;
                    }
                },
                c.FocusIn => {
                    ev.* = .focus_gained;
                    return true;
                },
                c.FocusOut => {
                    ev.* = .focus_lost;
                    return true;
                },
                else => {},
            }
        }
        return false;
    }

    pub fn present(self: *Window) void {
        _ = c.XPutImage(
            self.display,
            self.window,
            self.gc,
            self.image,
            0,
            0,
            0,
            0,
            self.width,
            self.height,
        );
        _ = c.XFlush(self.display);
    }

    pub fn getClipboard(self: *Window, allocator: std.mem.Allocator) ?[]const u8 {
        _ = c.XConvertSelection(
            self.display,
            self.atom_clipboard,
            self.atom_utf8,
            self.atom_selection_prop,
            self.window,
            c.CurrentTime,
        );
        _ = c.XFlush(self.display);

        var xev: c.XEvent = undefined;
        var attempts: usize = 0;
        while (attempts < 50) : (attempts += 1) {
            if (c.XCheckTypedWindowEvent(self.display, self.window, c.SelectionNotify, &xev) != 0) {
                if (xev.xselection.property == c.None) return null;

                var actual_type: c.Atom = undefined;
                var actual_format: c.c_int = undefined;
                var nitems: c_uint = undefined;
                var bytes_after: c_ulong = undefined;
                var prop: [*c]u8 = null;

                if (c.XGetWindowProperty(
                    self.display,
                    self.window,
                    self.atom_selection_prop,
                    0,
                    1024 * 1024,
                    c.False,
                    c.AnyPropertyType,
                    &actual_type,
                    &actual_format,
                    &nitems,
                    &bytes_after,
                    &prop,
                ) == c.Success and prop != null) {
                    defer _ = c.XFree(prop);
                    const slice = prop[0..nitems];
                    return allocator.dupe(u8, slice) catch null;
                }
                break;
            }
            std.time.sleep(2 * std.time.ns_per_ms);
        }
        return null;
    }

    pub fn setClipboard(self: *Window, text: []const u8) void {
        _ = self;
        _ = text;
    }

    fn resizeFramebuffer(self: *Window, w: u32, h: u32) !void {
        if (w == 0 or h == 0) return;

        self.gpa.free(self.framebuffer.pixels);
        self.image.data = null;
        if (self.image.f.destroy_image) |destroy_fn| {
            _ = destroy_fn(self.image);
        }

        const pixels = try self.gpa.alloc(u32, w * h);
        const screen = c.XDefaultScreen(self.display);
        const visual = c.XDefaultVisual(self.display, screen);
        const depth = c.XDefaultDepth(self.display, screen);

        const image_ptr = c.XCreateImage(
            self.display,
            visual,
            @intCast(depth),
            c.ZPixmap,
            0,
            @ptrCast(pixels.ptr),
            w,
            h,
            32,
            0,
        );

        self.image = image_ptr orelse return error.ImageCreationFailed;

        self.width = w;
        self.height = h;
        self.framebuffer = .{
            .pixels = pixels,
            .width = w,
            .height = h,
            .stride = w,
        };
    }
};

fn getMods(state: c_uint) Platform.Event.KeyMod {
    return .{
        .shift = (state & c.ShiftMask) != 0,
        .ctrl = (state & c.ControlMask) != 0,
        .alt = (state & c.Mod1Mask) != 0,
        .super = (state & c.Mod4Mask) != 0,
    };
}

fn translateKey(sym: c.KeySym) ?Platform.Event.KeyCode {
    return switch (sym) {
        c.XK_a => .a,
        c.XK_b => .b,
        c.XK_c => .c,
        c.XK_d => .d,
        c.XK_e => .e,
        c.XK_f => .f,
        c.XK_g => .g,
        c.XK_h => .h,
        c.XK_i => .i,
        c.XK_j => .j,
        c.XK_k => .k,
        c.XK_l => .l,
        c.XK_m => .m,
        c.XK_n => .n,
        c.XK_o => .o,
        c.XK_p => .p,
        c.XK_q => .q,
        c.XK_r => .r,
        c.XK_s => .s,
        c.XK_t => .t,
        c.XK_u => .u,
        c.XK_v => .v,
        c.XK_w => .w,
        c.XK_x => .x,
        c.XK_y => .y,
        c.XK_z => .z,

        c.XK_0 => .num_0,
        c.XK_1 => .num_1,
        c.XK_2 => .num_2,
        c.XK_3 => .num_3,
        c.XK_4 => .num_4,
        c.XK_5 => .num_5,
        c.XK_6 => .num_6,
        c.XK_7 => .num_7,
        c.XK_8 => .num_8,
        c.XK_9 => .num_9,

        c.XK_Return => .enter,
        c.XK_Escape => .escape,
        c.XK_BackSpace => .backspace,
        c.XK_Tab => .tab,
        c.XK_space => .space,
        c.XK_Up => .arrow_up,
        c.XK_Down => .arrow_down,
        c.XK_Left => .arrow_left,
        c.XK_Right => .arrow_right,
        c.XK_Page_Up => .page_up,
        c.XK_Page_Down => .page_down,
        c.XK_Home => .home,
        c.XK_End => .end,
        c.XK_Insert => .insert,
        c.XK_Delete => .delete,

        c.XK_F1 => .f1,
        c.XK_F2 => .f2,
        c.XK_F3 => .f3,
        c.XK_F4 => .f4,
        c.XK_F5 => .f5,
        c.XK_F6 => .f6,
        c.XK_F7 => .f7,
        c.XK_F8 => .f8,
        c.XK_F9 => .f9,
        c.XK_F10 => .f10,
        c.XK_F11 => .f11,
        c.XK_F12 => .f12,
        else => null,
    };
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const Pty = struct {
    master: posix.fd_t,
    child: posix.pid_t,

    pub fn open(self: *Pty, dims: Platform.Pty.Dimensions) !void {
        const master_rc = linux.open("/dev/ptmx", .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
            .NONBLOCK = true,
        }, 0);
        if (linux.errno(master_rc) != .SUCCESS) return error.OpenPty;
        const master: posix.fd_t = @intCast(master_rc);
        errdefer _ = linux.close(master);

        var unlock: i32 = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS)
            return error.OpenPty;

        var ptn: u32 = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&ptn))) != .SUCCESS)
            return error.OpenPty;

        var path_buf: [64]u8 = undefined;
        const slave_path = std.fmt.bufPrintZ(&path_buf, "/dev/pts/{d}", .{ptn}) catch return error.OpenPty;
        const shell = getShellPath();
        const ws = toWinsize(dims);

        const pid_rc = linux.fork();
        if (linux.errno(pid_rc) != .SUCCESS) return error.OpenPty;
        const pid: posix.pid_t = @intCast(pid_rc);

        if (pid == 0) {
            // Child Process
            _ = linux.close(master);
            _ = linux.setsid();

            const slave_rc = linux.open(slave_path, .{ .ACCMODE = .RDWR }, 0);
            if (linux.errno(slave_rc) != .SUCCESS) linux.exit(127);
            const slave: i32 = @intCast(slave_rc);

            _ = linux.ioctl(slave, linux.T.IOCSCTTY, 0);

            var ws_mut = ws;
            _ = linux.ioctl(slave, linux.T.IOCSWINSZ, @intFromPtr(&ws_mut));

            _ = linux.dup2(slave, 0);
            _ = linux.dup2(slave, 1);
            _ = linux.dup2(slave, 2);
            if (slave > 2) _ = linux.close(slave);

            execShell(shell);
        }

        // Parent Process
        var ws_mut = ws;
        _ = linux.ioctl(master, linux.T.IOCSWINSZ, @intFromPtr(&ws_mut));

        self.master = master;
        self.child = pid;
    }

    pub fn close(self: *Pty) void {
        _ = linux.close(self.master);
        self.* = undefined;
    }

    pub fn write(self: *Pty, bytes: []const u8) void {
        if (bytes.len == 0) return;
        _ = linux.write(self.master, bytes.ptr, bytes.len);
    }

    pub fn read(self: *Pty, buf: []u8) error{Hangup}![]u8 {
        const rc = linux.read(self.master, buf.ptr, buf.len);
        const err = linux.errno(rc);

        if (err == .AGAIN or err == .INTR) return buf[0..0];
        if (err != .SUCCESS or rc == 0) return error.Hangup;

        return buf[0..rc];
    }

    pub fn setWinsize(self: *Pty, dims: Platform.Pty.Dimensions) void {
        var ws = toWinsize(dims);
        _ = linux.ioctl(self.master, linux.T.IOCSWINSZ, @intFromPtr(&ws));
    }
};

inline fn toWinsize(dims: Platform.Pty.Dimensions) posix.winsize {
    return .{
        .row = dims.rows,
        .col = dims.cols,
        .xpixel = dims.px_w,
        .ypixel = dims.px_h,
    };
}

fn getShellPath() [*:0]const u8 {
    if (std.c.getenv("SHELL")) |s| {
        if (std.mem.span(s).len > 0) return s;
    }
    return "/bin/sh";
}

fn execShell(shell: [*:0]const u8) noreturn {
    _ = setenv("TERM", "xterm-256color", 1);
    _ = setenv("COLORTERM", "truecolor", 1);
    const argv = [_:null]?[*:0]const u8{ shell, null };
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    _ = std.c.execve(shell, &argv, envp);
    std.process.exit(127);
}
