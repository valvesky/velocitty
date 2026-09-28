//! Calls into `godstack/Peak/peak.h` that the terminal uses.
//! Struct layouts match that header. Linux only.

const std = @import("std");

pub const handle_invalid: i32 = -1;

/// Bit 0 is shift. Matches `PEAK_KEYMOD_*`.
pub const KeyMod = packed struct(u32) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    caps: bool = false,
    super: bool = false,
    _reserved: u27 = 0,
};

pub const KeyCode = enum(c_int) {
    unknown = 0,
    up,
    down,
    left,
    right,
    space,
    escape,
    enter,
    backspace,
    tab,
    delete,
    insert,
    home,
    end,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    @"0",
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
};

pub const Clip = enum(c_int) {
    clipboard = 0,
    primary,
};

pub const EventType = enum(c_int) {
    none = 0,
    key_down,
    key_up,
    window_close,
    window_resize,
    pointer,
    pointer_connected,
    pointer_disconnected,
    clip,
    text,
    drop,
    focus,
    expose,
    last,
};

pub const PointerState = enum(c_int) {
    moved = 0,
    pressed,
    released,
};

pub const PointerType = enum(c_int) {
    left = 0,
    right,
    middle,
    touch,
    wheel_up,
    wheel_down,
};

pub const WindowFlags = packed struct(u32) {
    transparent: bool = false,
    fullscreen: bool = false,
    _reserved: u30 = 0,
};

pub const Key = struct {
    key: KeyCode,
    mod: KeyMod,
    /// Platform code. On X11 this is `XLookupString`.
    code: u32,
};

pub const Pointer = struct {
    state: PointerState,
    kind: PointerType,
    x: f32,
    y: f32,
    mod: KeyMod,
};

pub const Event = union(EventType) {
    none: void,
    key_down: Key,
    key_up: Key,
    window_close: void,
    window_resize: struct { width: u32, height: u32 },
    pointer: Pointer,
    pointer_connected: void,
    pointer_disconnected: void,
    clip: struct { which: Clip, n: usize },
    text: usize,
    drop: usize,
    focus: bool,
    expose: void,
    last: void,
};

const KeyRaw = extern struct {
    key: c_int,
    mod: c_int,
    code: u32,
};

const ResizeRaw = extern struct {
    width: u32,
    height: u32,
};

const PointerRaw = extern struct {
    state: c_int,
    @"type": c_int,
    x: f32,
    y: f32,
    mod: c_int,
};

const ClipRaw = extern struct {
    which: c_int,
    n: usize,
};

const BytesRaw = extern struct {
    n: usize,
};

const FocusRaw = extern struct {
    on: c_int,
};

const RawEvent = extern struct {
    @"type": c_int,
    payload: extern union {
        key: KeyRaw,
        resize: ResizeRaw,
        pointer: PointerRaw,
        clip: ClipRaw,
        text: BytesRaw,
        drop: BytesRaw,
        focus: FocusRaw,
    },
};

pub const Window = extern struct {
    internal: extern struct { w: ?*anyopaque },
    tick: ?*const fn (*Window, ?*anyopaque) callconv(.c) c_int,
    userdata: ?*anyopaque,
    buffer: ?[*]u32,
    width: u32,
    height: u32,
    bufsize: u32,
    audio: ?[*]u16,
    running: c_int,

    pub fn live(self: Window) bool {
        return self.internal.w != null;
    }

    pub fn close(self: *Window) void {
        peak_window_close(self);
    }

    pub fn epoll(self: *Window) ?Event {
        var raw: RawEvent = undefined;
        if (peak_window_epoll(self, &raw) == 0) return null;
        return eventFrom(raw);
    }

    pub fn fd(self: *Window) i32 {
        return peak_window_fd(self);
    }

    pub fn pending(self: *Window) i32 {
        return peak_window_pending(self);
    }

    /// Backbuffer pixels. Valid until the next resize or close.
    pub fn backbuffer(self: *Window) []u32 {
        var w: usize = 0;
        var h: usize = 0;
        const p = peak_window_backbuffer(self, &w, &h) orelse return &.{};
        return p[0 .. w * h];
    }

    pub fn present(self: *Window) void {
        peak_window_present(self);
    }

    pub fn setTitle(self: *Window, name: [:0]const u8) void {
        peak_window_set_title(self, name.ptr);
    }

    pub fn setClass(self: *Window, name: [:0]const u8) void {
        peak_window_set_class(self, name.ptr);
    }

    pub fn setOpacity(self: *Window, alpha: u8) void {
        peak_window_set_opacity(self, alpha);
    }

    /// 0 default, 1 text, 2 hand, 3 wait, 4 crosshair, 5 not-allowed, 6 help.
    pub fn setCursorShape(self: *Window, shape: u8) void {
        peak_window_cursor_shape(self, shape);
    }
};

pub const Proc = extern struct {
    fd: i32,
    pid: c_int,
};

pub const Io = union(enum) {
    n: usize,
    would_block,
    eof,
};

/// Null-terminated argv, as Peak expects (`argv` itself is not copied).
pub const Argv = [*:null]const ?[*:0]const u8;

pub fn init() bool {
    return peak_init() != 0;
}

pub fn quit() void {
    peak_quit();
}

pub fn windowOpen(name: [:0]const u8, width: u32, height: u32, flags: WindowFlags) Window {
    return peak_window_open(name.ptr, width, height, @bitCast(flags));
}

pub fn time() u64 {
    return peak_get_time();
}

pub fn pid() i32 {
    return peak_pid();
}

pub fn ptySpawn(file: [:0]const u8, argv: Argv, cols: u32, rows: u32, xpixel: u32, ypixel: u32) ?Proc {
    const p = peak_pty_spawn(file.ptr, argv, cols, rows, xpixel, ypixel);
    if (p.fd == handle_invalid and p.pid == 0) return null;
    return p;
}

pub fn ptyResize(p: *Proc, cols: u32, rows: u32, xpixel: u32, ypixel: u32) void {
    peak_pty_resize(p, cols, rows, xpixel, ypixel);
}

pub fn ptyClose(p: *Proc) void {
    peak_pty_close(p);
}

pub fn fdRead(fd: i32, buf: []u8) Io {
    if (buf.len == 0) return .eof;
    return ioFrom(peak_fd_read(fd, buf.ptr, buf.len));
}

pub fn fdWrite(fd: i32, buf: []const u8) Io {
    if (buf.len == 0) return .{ .n = 0 };
    return ioFrom(peak_fd_write(fd, buf.ptr, buf.len));
}

pub fn clipSet(win: *Window, which: Clip, utf8: []const u8) bool {
    const p: ?[*]const u8 = if (utf8.len == 0) null else utf8.ptr;
    return peak_clip_set(win, @intFromEnum(which), p, utf8.len) != 0;
}

pub fn clipRequest(win: *Window, which: Clip) bool {
    return peak_clip_request(win, @intFromEnum(which)) != 0;
}

pub fn clipTake(win: *Window, dst: []u8) ?usize {
    return take(peak_clip_take, win, dst);
}

pub fn textTake(win: *Window, dst: []u8) ?usize {
    return take(peak_text_take, win, dst);
}

fn ioFrom(n: c_int) Io {
    if (n < 0) return .would_block;
    if (n == 0) return .eof;
    return .{ .n = @intCast(n) };
}

fn keyModFrom(v: c_int) KeyMod {
    return @bitCast(@as(u32, @bitCast(v)));
}

fn enumFrom(comptime T: type, v: c_int) ?T {
    return std.enums.fromInt(T, v);
}

fn eventFrom(raw: RawEvent) Event {
    const kind = enumFrom(EventType, raw.@"type") orelse return .none;
    return switch (kind) {
        .none, .last => .none,
        .key_down, .key_up => blk: {
            const key = Key{
                .key = enumFrom(KeyCode, raw.payload.key.key) orelse .unknown,
                .mod = keyModFrom(raw.payload.key.mod),
                .code = raw.payload.key.code,
            };
            break :blk if (kind == .key_down) .{ .key_down = key } else .{ .key_up = key };
        },
        .window_close => .window_close,
        .window_resize => .{ .window_resize = .{
            .width = raw.payload.resize.width,
            .height = raw.payload.resize.height,
        } },
        .pointer => .{ .pointer = .{
            .state = enumFrom(PointerState, raw.payload.pointer.state) orelse .moved,
            .kind = enumFrom(PointerType, raw.payload.pointer.@"type") orelse .left,
            .x = raw.payload.pointer.x,
            .y = raw.payload.pointer.y,
            .mod = keyModFrom(raw.payload.pointer.mod),
        } },
        .pointer_connected => .pointer_connected,
        .pointer_disconnected => .pointer_disconnected,
        .clip => .{ .clip = .{
            .which = enumFrom(Clip, raw.payload.clip.which) orelse .clipboard,
            .n = raw.payload.clip.n,
        } },
        .text => .{ .text = raw.payload.text.n },
        .drop => .{ .drop = raw.payload.drop.n },
        .focus => .{ .focus = raw.payload.focus.on != 0 },
        .expose => .expose,
    };
}

const TakeFn = *const fn (*Window, ?[*]u8, usize, *usize) callconv(.c) c_int;

fn take(f: TakeFn, win: *Window, dst: []u8) ?usize {
    var n: usize = 0;
    const p: ?[*]u8 = if (dst.len == 0) null else dst.ptr;
    if (f(win, p, dst.len, &n) == 0) return null;
    return n;
}

extern fn peak_init() c_int;
extern fn peak_quit() void;
extern fn peak_window_open(name: [*:0]const u8, width: u32, height: u32, flags: u32) Window;
extern fn peak_window_close(window: *Window) void;
extern fn peak_window_epoll(win: *Window, ev: *RawEvent) c_int;
extern fn peak_window_fd(win: *Window) c_int;
extern fn peak_window_pending(win: *Window) c_int;
extern fn peak_window_backbuffer(win: *Window, width: *usize, height: *usize) ?[*]u32;
extern fn peak_window_present(win: *Window) void;
extern fn peak_window_set_title(win: *Window, name: [*:0]const u8) void;
extern fn peak_window_set_class(win: *Window, name: [*:0]const u8) void;
extern fn peak_window_set_opacity(win: *Window, alpha: u8) void;
extern fn peak_window_cursor_shape(win: *Window, shape: c_int) void;
extern fn peak_get_time() u64;
extern fn peak_pid() c_int;
extern fn peak_pty_spawn(file: [*:0]const u8, argv: Argv, cols: u32, rows: u32, xpixel: u32, ypixel: u32) Proc;
extern fn peak_pty_resize(pty: *Proc, cols: u32, rows: u32, xpixel: u32, ypixel: u32) void;
extern fn peak_pty_close(pty: *Proc) void;
extern fn peak_fd_read(fd: i32, buf: *anyopaque, n: usize) c_int;
extern fn peak_fd_write(fd: i32, buf: *const anyopaque, n: usize) c_int;
extern fn peak_clip_set(win: *Window, which: c_int, utf8: ?[*]const u8, n: usize) c_int;
extern fn peak_clip_request(win: *Window, which: c_int) c_int;
extern fn peak_clip_take(win: *Window, dst: ?[*]u8, cap: usize, n: *usize) c_int;
extern fn peak_text_take(win: *Window, dst: ?[*]u8, cap: usize, n: *usize) c_int;
