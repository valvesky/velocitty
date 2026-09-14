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
    @cInclude("X11/extensions/XInput2.h");
});

const XiAxis = struct {
    deviceid: i32,
    number: i32,
    increment: f64,
    last: f64 = 0,
    acc: f64 = 0,
    have: bool = false,
};

/// CSS/X11 pixels-per-inch for converting terminal font points to raster pixels.
pub fn screenDpi() f32 {
    const display = c.XOpenDisplay(null) orelse return 96;
    defer _ = c.XCloseDisplay(display);
    const screen = c.XDefaultScreen(display);
    const px = c.XDisplayWidth(display, screen);
    const mm = c.XDisplayWidthMM(display, screen);
    if (px <= 0 or mm <= 0) return 96;
    const dpi = @as(f32, @floatFromInt(px)) * 25.4 / @as(f32, @floatFromInt(mm));
    if (!std.math.isFinite(dpi) or dpi < 24 or dpi > 576) return 96;
    return dpi;
}

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

    xi_opcode: c_int = 0,
    xi_axes: [8]XiAxis = undefined,
    xi_axis_n: u8 = 0,
    paste_buf: []u8 = &.{},

    gpa: std.mem.Allocator,

    pub fn open(self: *Window, allocator: std.mem.Allocator, title: [*:0]const u8, class: [*:0]const u8, width: u32, height: u32) !void {
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
            0,
            c.XBlackPixel(display, screen),
            c.XBlackPixel(display, screen),
        );
        errdefer _ = c.XDestroyWindow(display, win);

        // Select input events
        _ = c.XSelectInput(
            display,
            win,
            c.KeyPressMask |
                c.KeyReleaseMask |
                c.ButtonPressMask |
                c.StructureNotifyMask |
                c.ExposureMask |
                c.FocusChangeMask,
        );

        // Intercept close button clicks
        const wm_delete = c.XInternAtom(display, "WM_DELETE_WINDOW", c.False);
        var protocols = [1]c.Atom{wm_delete};
        _ = c.XSetWMProtocols(display, win, &protocols, 1);

        _ = c.XStoreName(display, win, title);
        var class_hint = c.XClassHint{
            .res_name = @constCast(class),
            .res_class = @constCast(class),
        };
        _ = c.XSetClassHint(display, win, &class_hint);
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

        self.xi_opcode = 0;
        self.xi_axis_n = 0;
        self.paste_buf = &.{};
        initXi(self);
    }

    pub fn close(self: *Window) void {
        if (self.paste_buf.len != 0) self.gpa.free(self.paste_buf);
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

    pub fn eventFd(self: *const Window) posix.fd_t {
        return @intCast(c.XConnectionNumber(self.display));
    }

    /// True if Xlib already has events (fd may be idle). Never sleep on eventFd in that case.
    pub fn eventsPending(self: *Window) bool {
        return c.XPending(self.display) > 0;
    }

    pub fn pollEvent(self: *Window, ev: *Platform.Event) bool {
        while (c.XPending(self.display) > 0) {
            var xev: c.XEvent = undefined;
            _ = c.XNextEvent(self.display, &xev);

            switch (xev.type) {
                c.GenericEvent => {
                    if (self.xi_opcode != 0 and xev.xcookie.extension == self.xi_opcode) {
                        if (c.XGetEventData(self.display, &xev.xcookie) != 0) {
                            defer c.XFreeEventData(self.display, &xev.xcookie);
                            if (xev.xcookie.evtype == c.XI_Motion) {
                                if (wheelFromXi(self, @ptrCast(@alignCast(xev.xcookie.data)), ev)) return true;
                            }
                        }
                    }
                },
                c.SelectionNotify => {
                    if (takeSelection(self, xev.xselection.property, ev)) return true;
                },
                c.ClientMessage => {
                    if (@as(c.Atom, @intCast(xev.xclient.data.l[0])) == self.wm_delete_window) {
                        ev.* = .quit;
                        return true;
                    }
                },
                c.ConfigureNotify => {
                    const new_w: u32 = @intCast(xev.xconfigure.width);
                    const new_h: u32 = @intCast(xev.xconfigure.height);
                    if (new_w == 0 or new_h == 0) continue;
                    if (new_w != self.width or new_h != self.height) {
                        self.resizeFramebuffer(new_w, new_h) catch {};
                        ev.* = .{ .resize = .{
                            .cols = @intCast(@max(1, new_w / 8)),
                            .rows = @intCast(@max(1, new_h / 16)),
                            .px_w = @intCast(@min(new_w, std.math.maxInt(u16))),
                            .px_h = @intCast(@min(new_h, std.math.maxInt(u16))),
                        } };
                        return true;
                    }
                },
                c.Expose => {
                    if (xev.xexpose.count != 0) continue;
                    ev.* = .redraw;
                    return true;
                },
                c.KeyPress => {
                    var buf: [32]u8 = undefined;
                    var keysym: c.KeySym = 0;
                    const len = c.XLookupString(&xev.xkey, &buf, buf.len, &keysym, null);
                    const mods = getMods(xev.xkey.state);
                    if (isPasteKey(keysym, mods)) {
                        ev.* = .paste_request;
                        return true;
                    }

                    if (translateKey(keysym)) |key| {
                        ev.* = .{ .key_press = .{ .key = key, .mods = mods } };
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
                c.ButtonPress => {
                    const button = xev.xbutton.button;
                    if (button == 2) {
                        ev.* = .paste_request;
                        return true;
                    }
                    if (button == 4 or button == 5) {
                        ev.* = .{ .mouse_wheel = .{
                            .up = button == 4,
                            .x = xev.xbutton.x,
                            .y = xev.xbutton.y,
                            .mods = getMods(xev.xbutton.state),
                        } };
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

    pub fn requestPaste(self: *Window) void {
        _ = c.XConvertSelection(
            self.display,
            self.atom_clipboard,
            self.atom_utf8,
            self.atom_selection_prop,
            self.window,
            c.CurrentTime,
        );
        _ = c.XFlush(self.display);
    }

    pub fn setClipboard(self: *Window, text: []const u8) void {
        _ = self;
        _ = text;
    }

    fn resizeFramebuffer(self: *Window, w: u32, h: u32) !void {
        if (w == 0 or h == 0) return;
        if (w == self.width and h == self.height) return;

        const pixels = try self.gpa.alloc(u32, w * h);
        @memset(pixels, 0);
        const old = self.framebuffer.pixels;
        self.image.data = @ptrCast(pixels.ptr);
        self.image.width = @intCast(w);
        self.image.height = @intCast(h);
        self.image.bytes_per_line = @intCast(w * @sizeOf(u32));
        self.width = w;
        self.height = h;
        self.framebuffer = .{
            .pixels = pixels,
            .width = w,
            .height = h,
            .stride = w,
        };
        self.gpa.free(old);
    }
};

fn xiMaskIsSet(mask: [*]const u8, mask_len: c_int, bit: i32) bool {
    if (bit < 0) return false;
    const byte: i32 = bit >> 3;
    if (byte >= mask_len) return false;
    return (mask[@intCast(byte)] & (@as(u8, 1) << @intCast(bit & 7))) != 0;
}

fn xiSetMask(mask: []u8, bit: c_int) void {
    if (bit < 0) return;
    const byte: usize = @intCast(bit >> 3);
    if (byte >= mask.len) return;
    mask[byte] |= @as(u8, 1) << @intCast(bit & 7);
}

fn initXi(self: *Window) void {
    var opcode: c_int = 0;
    var event: c_int = 0;
    var err: c_int = 0;
    if (c.XQueryExtension(self.display, "XInputExtension", &opcode, &event, &err) == 0) return;
    var major: c_int = 2;
    var minor: c_int = 0;
    if (c.XIQueryVersion(self.display, &major, &minor) != c.Success) return;
    self.xi_opcode = opcode;

    var mask = [_]u8{0} ** 4;
    xiSetMask(&mask, c.XI_Motion);
    var evmask = c.XIEventMask{
        .deviceid = c.XIAllMasterDevices,
        .mask_len = mask.len,
        .mask = &mask,
    };
    _ = c.XISelectEvents(self.display, self.window, &evmask, 1);

    var ndevices: c_int = 0;
    const info = c.XIQueryDevice(self.display, c.XIAllDevices, &ndevices);
    if (info == null) return;
    defer c.XIFreeDeviceInfo(info);

    var n: u8 = 0;
    var i: c_int = 0;
    while (i < ndevices) : (i += 1) {
        const dev = info[@intCast(i)];
        var j: c_int = 0;
        while (j < dev.num_classes) : (j += 1) {
            const class = dev.classes[@intCast(j)] orelse continue;
            if (class.*.type != c.XIScrollClass) continue;
            const scroll: *c.XIScrollClassInfo = @ptrCast(@alignCast(class));
            if (scroll.scroll_type != c.XIScrollTypeVertical) continue;
            if (n >= self.xi_axes.len) break;
            var inc = scroll.increment;
            if (inc == 0 or !std.math.isFinite(inc)) inc = 1;
            self.xi_axes[n] = .{
                .deviceid = dev.deviceid,
                .number = scroll.number,
                .increment = @abs(inc),
            };
            n += 1;
        }
    }
    self.xi_axis_n = n;
}

fn wheelFromXi(self: *Window, dev: *c.XIDeviceEvent, ev: *Platform.Event) bool {
    const vals = dev.valuators;
    if (vals.mask == null or vals.values == null or vals.mask_len <= 0) return false;

    var value_idx: usize = 0;
    var bit: i32 = 0;
    const mask_bits = vals.mask_len * 8;
    var steps_up: i32 = 0;
    var steps_down: i32 = 0;
    while (bit < mask_bits) : (bit += 1) {
        if (!xiMaskIsSet(vals.mask, vals.mask_len, bit)) continue;
        const val = vals.values[value_idx];
        value_idx += 1;

        var a: u8 = 0;
        while (a < self.xi_axis_n) : (a += 1) {
            const axis = &self.xi_axes[a];
            if (axis.deviceid != dev.deviceid and axis.deviceid != dev.sourceid) continue;
            if (axis.number != bit) continue;
            if (!axis.have) {
                axis.last = val;
                axis.have = true;
                axis.acc = 0;
                break;
            }
            const delta = val - axis.last;
            axis.last = val;
            if (delta == 0 or !std.math.isFinite(delta)) break;
            axis.acc += delta;
            const inc = axis.increment;
            while (axis.acc >= inc) {
                axis.acc -= inc;
                steps_down += 1;
            }
            while (axis.acc <= -inc) {
                axis.acc += inc;
                steps_up += 1;
            }
            break;
        }
    }

    const down = steps_down > 0;
    const up = steps_up > 0;
    if (!down and !up) return false;
    // If both directions accumulated in one event, prefer the larger.
    const up_event = if (up and down) steps_up >= steps_down else up;
    const n = if (up_event) steps_up else steps_down;
    ev.* = .{ .mouse_wheel = .{
        .up = up_event,
        .x = @intFromFloat(dev.event_x),
        .y = @intFromFloat(dev.event_y),
        .mods = getMods(@intCast(dev.mods.effective)),
        .steps = @intCast(@min(n, 32)),
    } };
    return true;
}

fn takeSelection(self: *Window, property: c.Atom, ev: *Platform.Event) bool {
    if (property == c.None) return false;
    var actual_type: c.Atom = undefined;
    var actual_format: c_int = undefined;
    var nitems: c_ulong = undefined;
    var bytes_after: c_ulong = undefined;
    var prop: [*c]u8 = null;
    if (c.XGetWindowProperty(
        self.display,
        self.window,
        property,
        0,
        1024 * 1024,
        c.True,
        c.AnyPropertyType,
        &actual_type,
        &actual_format,
        &nitems,
        &bytes_after,
        &prop,
    ) != c.Success or prop == null) return false;
    defer _ = c.XFree(prop);
    const slice = prop[0..nitems];
    if (self.paste_buf.len < slice.len) {
        if (self.paste_buf.len != 0) self.gpa.free(self.paste_buf);
        self.paste_buf = self.gpa.alloc(u8, slice.len) catch return false;
    }
    @memcpy(self.paste_buf[0..slice.len], slice);
    ev.* = .{ .paste = self.paste_buf[0..slice.len] };
    return true;
}

fn isPasteKey(sym: c.KeySym, mods: Platform.Event.KeyMod) bool {
    if (mods.shift and !mods.ctrl and !mods.alt and sym == c.XK_Insert) return true;
    if (mods.ctrl and mods.shift and (sym == c.XK_v or sym == c.XK_V)) return true;
    return false;
}

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
        c.XK_Return => .enter,
        c.XK_Escape => .escape,
        c.XK_BackSpace => .backspace,
        c.XK_Tab => .tab,
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
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn execvpe(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;

pub const Pty = struct {
    master: posix.fd_t,
    child: posix.pid_t,

    pub fn open(self: *Pty, dims: Platform.Dimensions, spawn: Platform.Spawn) !void {
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

            execChild(spawn);
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

    pub fn setWinsize(self: *Pty, dims: Platform.Dimensions) void {
        var ws = toWinsize(dims);
        _ = linux.ioctl(self.master, linux.T.IOCSWINSZ, @intFromPtr(&ws));
    }
};

inline fn toWinsize(dims: Platform.Dimensions) posix.winsize {
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

fn applyChildEnv() void {
    // kitty.zig implements the graphics protocol; advertise it so icat/nvim/etc. use APC G.
    _ = setenv("TERM", "xterm-kitty", 1);
    _ = setenv("COLORTERM", "truecolor", 1);
    _ = setenv("TERM_PROGRAM", "velocitty", 1);
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrintZ(&id_buf, "{d}", .{linux.getpid()}) catch "1";
    _ = setenv("KITTY_WINDOW_ID", id, 1);
    _ = unsetenv("KITTY_LISTEN_ON");
}

fn execChild(spawn: Platform.Spawn) noreturn {
    applyChildEnv();
    if (spawn.cwd) |dir| {
        if (linux.errno(linux.chdir(dir)) != .SUCCESS) linux.exit(127);
    }
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    if (spawn.argv.len == 0) {
        const shell = getShellPath();
        const argv = [_:null]?[*:0]const u8{ shell, null };
        _ = std.c.execve(shell, &argv, envp);
        linux.exit(127);
    }
    var buf: [64]?[*:0]const u8 = undefined;
    if (spawn.argv.len >= buf.len) linux.exit(127);
    for (spawn.argv, 0..) |a, i| buf[i] = a;
    buf[spawn.argv.len] = null;
    _ = execvpe(spawn.argv[0], @ptrCast(&buf), envp);
    linux.exit(127);
}
