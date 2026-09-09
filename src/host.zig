//! OS window. Presents CPU pixels. Not part of the library pipeline.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const xev = @import("xev");
const zt = @import("ZT");
const Loop = zt.Loop;
const Draw = zt.Draw;
const Pty = @import("pty.zig").Pty;
const Debug = zt.Debug;

const c = struct {
    pub const Window = opaque {};
    pub const Renderer = opaque {};
    pub const Texture = opaque {};

    pub const INIT_VIDEO: u32 = 0x00000020;
    pub const EVENT_QUIT: u32 = 0x100;
    pub const EVENT_WINDOW_RESIZED: u32 = 0x206;
    pub const EVENT_WINDOW_PIXEL_SIZE_CHANGED: u32 = 0x207;
    pub const EVENT_WINDOW_CLOSE_REQUESTED: u32 = 0x210;
    pub const EVENT_KEY_DOWN: u32 = 0x300;
    pub const EVENT_KEY_UP: u32 = 0x301;
    pub const EVENT_TEXT_INPUT: u32 = 0x303;
    pub const EVENT_MOUSE_MOTION: u32 = 0x400;
    pub const EVENT_MOUSE_BUTTON_DOWN: u32 = 0x401;
    pub const EVENT_MOUSE_BUTTON_UP: u32 = 0x402;
    pub const EVENT_MOUSE_WHEEL: u32 = 0x403;
    pub const EVENT_WINDOW_FOCUS_GAINED: u32 = 0x20e;
    pub const EVENT_WINDOW_FOCUS_LOST: u32 = 0x20f;
    pub const TEXTUREACCESS_STREAMING: c_int = 1;
    pub const PIXELFORMAT_ARGB8888: u32 = 0x16362004;
    pub const WINDOW_RESIZABLE: u64 = 0x0000000000000020;
    pub const WINDOW_HIGH_PIXEL_DENSITY: u64 = 0x0000000000002000;
    pub const SCALEMODE_NEAREST: c_int = 0;
    pub const KMOD_SHIFT: u16 = 0x0003;
    pub const KMOD_CTRL: u16 = 0x00C0;
    pub const KMOD_ALT: u16 = 0x0300;
    pub const KMOD_GUI: u16 = 0x0C00;
    pub const BUTTON_LEFT: u8 = 1;
    pub const BUTTON_MIDDLE: u8 = 2;
    pub const BUTTON_RIGHT: u8 = 3;

    pub const Event = extern union {
        type: u32,
        key: extern struct {
            type: u32,
            reserved: u32,
            timestamp: u64,
            window_id: u32,
            which: u32,
            scancode: u32,
            key: u32,
            mod: u16,
            raw: u16,
            down: u8,
            repeat: u8,
        },
        text: extern struct {
            type: u32,
            reserved: u32,
            timestamp: u64,
            window_id: u32,
            text: [*:0]const u8,
        },
        window: extern struct {
            type: u32,
            reserved: u32,
            timestamp: u64,
            window_id: u32,
            data1: i32,
            data2: i32,
        },
        motion: extern struct {
            type: u32,
            reserved: u32,
            timestamp: u64,
            window_id: u32,
            which: u32,
            state: u32,
            x: f32,
            y: f32,
            xrel: f32,
            yrel: f32,
        },
        button: extern struct {
            type: u32,
            reserved: u32,
            timestamp: u64,
            window_id: u32,
            which: u32,
            button: u8,
            down: u8,
            clicks: u8,
            padding: u8,
            x: f32,
            y: f32,
        },
        wheel: extern struct {
            type: u32,
            reserved: u32,
            timestamp: u64,
            window_id: u32,
            which: u32,
            x: f32,
            y: f32,
            direction: u32,
            mouse_x: f32,
            mouse_y: f32,
            integer_x: i32,
            integer_y: i32,
        },
        padding: [128]u8,
    };

    pub var SDL_Init: *const fn (flags: u32) callconv(.c) bool = undefined;
    pub var SDL_Quit: *const fn () callconv(.c) void = undefined;
    pub var SDL_CreateWindowAndRenderer: *const fn (
        title: [*:0]const u8,
        w: c_int,
        h: c_int,
        flags: u64,
        window: *?*Window,
        renderer: *?*Renderer,
    ) callconv(.c) bool = undefined;
    pub var SDL_CreateTexture: *const fn (
        renderer: *Renderer,
        format: u32,
        access: c_int,
        w: c_int,
        h: c_int,
    ) callconv(.c) ?*Texture = undefined;
    pub const Rect = extern struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
    };

    pub const FRect = extern struct {
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    };

    pub var SDL_UpdateTexture: *const fn (texture: *Texture, rect: ?*const Rect, pixels: *const anyopaque, pitch: c_int) callconv(.c) bool = undefined;
    pub var SDL_SetTextureScaleMode: *const fn (texture: *Texture, scaleMode: c_int) callconv(.c) bool = undefined;
    pub var SDL_RenderTexture: *const fn (renderer: *Renderer, texture: *Texture, src: ?*const FRect, dst: ?*const FRect) callconv(.c) bool = undefined;
    pub var SDL_GetError: *const fn () callconv(.c) [*:0]const u8 = undefined;
    pub var SDL_SetRenderDrawColor: *const fn (renderer: *Renderer, r: u8, g: u8, b: u8, a: u8) callconv(.c) bool = undefined;
    pub var SDL_RenderClear: *const fn (renderer: *Renderer) callconv(.c) bool = undefined;
    pub var SDL_RenderPresent: *const fn (renderer: *Renderer) callconv(.c) bool = undefined;
    pub var SDL_SetRenderVSync: ?*const fn (renderer: *Renderer, vsync: c_int) callconv(.c) bool = null;
    pub var SDL_GetWindowSizeInPixels: *const fn (window: *Window, w: ?*c_int, h: ?*c_int) callconv(.c) bool = undefined;
    pub var SDL_GetWindowPixelDensity: *const fn (window: *Window) callconv(.c) f32 = undefined;
    pub var SDL_DestroyTexture: *const fn (texture: *Texture) callconv(.c) void = undefined;
    pub var SDL_DestroyRenderer: *const fn (renderer: *Renderer) callconv(.c) void = undefined;
    pub var SDL_DestroyWindow: *const fn (window: *Window) callconv(.c) void = undefined;
    pub var SDL_PollEvent: *const fn (event: *Event) callconv(.c) bool = undefined;
    pub var SDL_StartTextInput: *const fn (window: *Window) callconv(.c) bool = undefined;
    pub var SDL_GetModState: *const fn () callconv(.c) u16 = undefined;
    pub var SDL_GetWindowProperties: *const fn (window: *Window) callconv(.c) u32 = undefined;
    pub var SDL_GetPointerProperty: *const fn (props: u32, name: [*:0]const u8, default_value: ?*anyopaque) callconv(.c) ?*anyopaque = undefined;
    pub var SDL_GetNumberProperty: *const fn (props: u32, name: [*:0]const u8, default_value: i64) callconv(.c) i64 = undefined;
};

var sdl_loaded: bool = false;

fn loadSdl() bool {
    if (sdl_loaded) return true;
    sdl_loaded = switch (builtin.os.tag) {
        .windows => loadSdlWindows(),
        else => loadSdlPosix(),
    };
    return sdl_loaded;
}

fn loadSdlPosix() bool {
    const names = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => [_][:0]const u8{
            "libSDL3.0.dylib",
            "libSDL3.dylib",
            "SDL3.framework/SDL3",
        },
        else => [_][:0]const u8{
            "libSDL3.so.0",
            "libSDL3.so",
        },
    };
    for (names) |name| {
        if (openBesideExe(name)) |lib| return bindPosix(lib);
        if (std.DynLib.open(name)) |lib| return bindPosix(lib) else |_| {}
    }
    return false;
}

fn openBesideExe(name: []const u8) ?std.DynLib {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(std.Io.Threaded.global_single_threaded.io(), &buf) catch return null;
    const dir = std.fs.path.dirname(buf[0..n]) orelse return null;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, name }) catch return null;
    return std.DynLib.openZ(path) catch null;
}

fn bindPosix(lib: std.DynLib) bool {
    var l = lib;
    return bindAll(lookupPosix, &l);
}

fn lookupPosix(lib: *std.DynLib, name: [:0]const u8) ?*const anyopaque {
    return lib.lookup(*const anyopaque, name);
}

fn loadSdlWindows() bool {
    const names = [_][:0]const u8{"SDL3.dll"};
    for (names) |name| {
        const handle = LoadLibraryA(name) orelse continue;
        if (bindWindows(handle)) return true;
    }
    return false;
}

fn bindWindows(handle: *anyopaque) bool {
    return bindAll(lookupWindows, handle);
}

fn lookupWindows(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
    return GetProcAddress(handle, name);
}

fn bindAll(lookup: anytype, ctx: anytype) bool {
    inline for (.{
        .{ "SDL_Init", &c.SDL_Init },
        .{ "SDL_Quit", &c.SDL_Quit },
        .{ "SDL_CreateWindowAndRenderer", &c.SDL_CreateWindowAndRenderer },
        .{ "SDL_CreateTexture", &c.SDL_CreateTexture },
        .{ "SDL_UpdateTexture", &c.SDL_UpdateTexture },
        .{ "SDL_SetTextureScaleMode", &c.SDL_SetTextureScaleMode },
        .{ "SDL_RenderTexture", &c.SDL_RenderTexture },
        .{ "SDL_SetRenderDrawColor", &c.SDL_SetRenderDrawColor },
        .{ "SDL_RenderClear", &c.SDL_RenderClear },
        .{ "SDL_RenderPresent", &c.SDL_RenderPresent },
        .{ "SDL_GetWindowSizeInPixels", &c.SDL_GetWindowSizeInPixels },
        .{ "SDL_GetWindowPixelDensity", &c.SDL_GetWindowPixelDensity },
        .{ "SDL_DestroyTexture", &c.SDL_DestroyTexture },
        .{ "SDL_DestroyRenderer", &c.SDL_DestroyRenderer },
        .{ "SDL_DestroyWindow", &c.SDL_DestroyWindow },
        .{ "SDL_PollEvent", &c.SDL_PollEvent },
        .{ "SDL_StartTextInput", &c.SDL_StartTextInput },
        .{ "SDL_GetModState", &c.SDL_GetModState },
        .{ "SDL_GetWindowProperties", &c.SDL_GetWindowProperties },
        .{ "SDL_GetPointerProperty", &c.SDL_GetPointerProperty },
        .{ "SDL_GetNumberProperty", &c.SDL_GetNumberProperty },
        .{ "SDL_GetError", &c.SDL_GetError },
    }) |pair| {
        const ptr = lookup(ctx, pair[0]) orelse return false;
        pair[1].* = @ptrCast(@alignCast(ptr));
    }
    if (lookup(ctx, "SDL_SetRenderVSync")) |ptr| {
        c.SDL_SetRenderVSync = @ptrCast(@alignCast(ptr));
    }
    return true;
}

extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

pub const Host = struct {
    window: *c.Window,
    renderer: *c.Renderer,
    texture: *c.Texture,
    width: u32,
    height: u32,
    pty: ?*Pty = null,
    loop: ?*Loop = null,
    last_mouse_col: u16 = 0xffff,
    last_mouse_row: u16 = 0xffff,
    pty_file: xev.File = undefined,
    pty_c: xev.Completion = .{},
    win_file: xev.File = undefined,
    win_c: xev.Completion = .{},
    repeat_timer: xev.Timer = .{},
    repeat_c: xev.Completion = .{},
    keys_held: u32 = 0,
    repeat_armed: bool = false,
    overlay: []u32 = &.{},
    restore_frame: bool = false,
    origin_x: i32 = 0,
    origin_y: i32 = 0,

    pub fn open(title: []const u8, width: u32, height: u32) error{OpenWindow}!Host {
        assert(width > 0);
        assert(height > 0);
        if (!loadSdl()) {
            Debug.log("sdl: dlopen/bind failed", .{});
            return error.OpenWindow;
        }
        if (!c.SDL_Init(c.INIT_VIDEO)) {
            sdlFail("Init");
            return error.OpenWindow;
        }
        errdefer c.SDL_Quit();

        var title_z: [256]u8 = undefined;
        const n = @min(title.len, title_z.len - 1);
        @memcpy(title_z[0..n], title[0..n]);
        title_z[n] = 0;

        var window: ?*c.Window = null;
        var renderer: ?*c.Renderer = null;
        if (!c.SDL_CreateWindowAndRenderer(
            title_z[0..n :0],
            @intCast(width),
            @intCast(height),
            c.WINDOW_RESIZABLE | c.WINDOW_HIGH_PIXEL_DENSITY,
            &window,
            &renderer,
        )) {
            sdlFail("CreateWindowAndRenderer");
            return error.OpenWindow;
        }
        const win = window.?;
        const rend = renderer.?;
        errdefer {
            c.SDL_DestroyRenderer(rend);
            c.SDL_DestroyWindow(win);
        }

        if (c.SDL_SetRenderVSync) |set_vsync| {
            _ = set_vsync(rend, 0);
        }
        const texture = makeTexture(rend, width, height) orelse {
            sdlFail("CreateTexture");
            return error.OpenWindow;
        };
        _ = c.SDL_StartTextInput(win);
        return .{
            .window = win,
            .renderer = rend,
            .texture = texture,
            .width = width,
            .height = height,
        };
    }

    pub fn close(self: *Host) void {
        if (self.overlay.len != 0) std.heap.page_allocator.free(self.overlay);
        c.SDL_DestroyTexture(self.texture);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        self.* = undefined;
    }

    pub fn watch(self: *Host, loop: *Loop) void {
        assert(self.loop == null);
        self.loop = loop;
        switch (comptime builtin.os.tag) {
            .windows, .wasi => {},
            else => {
                if (self.pty) |pty| {
                    self.pty_file = xev.File.initFd(pty.master);
                    self.pty_file.poll(&loop.inner, &self.pty_c, .read, Host, self, &onPty);
                }
                if (windowFd(self.window)) |fd| {
                    self.win_file = xev.File.initFd(fd);
                    self.win_file.poll(&loop.inner, &self.win_c, .read, Host, self, &onWin);
                }
            },
        }
        self.drainPty();
        self.drainSdl();
    }

    fn onPty(
        ud: ?*Host,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        r: xev.PollError!xev.PollEvent,
    ) xev.CallbackAction {
        _ = r catch return .disarm;
        const self = ud.?;
        const loop = self.loop.?;
        if (loop.stopped) return .disarm;
        self.drainPty();
        self.drainSdl();
        return if (loop.stopped) .disarm else .rearm;
    }

    fn onWin(
        ud: ?*Host,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        r: xev.PollError!xev.PollEvent,
    ) xev.CallbackAction {
        _ = r catch return .disarm;
        const self = ud.?;
        const loop = self.loop.?;
        if (loop.stopped) return .disarm;
        self.drainSdl();
        self.drainPty();
        return if (loop.stopped) .disarm else .rearm;
    }

    fn drainPty(self: *Host) void {
        const pty = self.pty orelse return;
        self.loop.?.drain(pty);
        self.flushReports();
    }

    fn flushReports(self: *Host) void {
        const loop = self.loop orelse return;
        const engine = loop.engine orelse return;
        if (!engine.queries.pending()) return;
        engine.refresh() catch |err| {
            Debug.log("refresh: {}", .{err});
            return;
        };
        var buf: [512]u8 = undefined;
        const n = engine.takeReports(&buf);
        if (n != 0) {
            if (self.pty) |pty| pty.write(buf[0..n]);
        }
        if (loop.on_frame) |f| f(loop);
    }

    fn drainSdl(self: *Host) void {
        const loop = self.loop.?;
        var ev: c.Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.EVENT_QUIT, c.EVENT_WINDOW_CLOSE_REQUESTED => {
                    loop.stop();
                    return;
                },
                c.EVENT_WINDOW_RESIZED, c.EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
                    self.syncEngine(loop.engine.?);
                    if (loop.on_frame) |f| f(loop);
                },
                c.EVENT_TEXT_INPUT => {
                    const mods = modsFrom(c.SDL_GetModState());
                    if (mods.ctrl or mods.alt) continue;
                    const s = std.mem.span(ev.text.text);
                    if (s.len != 0) self.send(loop, s);
                },
                c.EVENT_KEY_DOWN => {
                    if (ev.key.repeat == 0) self.keys_held += 1;
                    self.handleKey(loop, ev.key.key, ev.key.mod, ev.key.repeat != 0);
                },
                c.EVENT_KEY_UP => {
                    if (self.keys_held > 0) self.keys_held -= 1;
                },
                c.EVENT_MOUSE_BUTTON_DOWN, c.EVENT_MOUSE_BUTTON_UP => {
                    const down = ev.type == c.EVENT_MOUSE_BUTTON_DOWN;
                    const button = sdlButton(ev.button.button);
                    self.handleMouse(loop, .{
                        .x = @intFromFloat(ev.button.x),
                        .y = @intFromFloat(ev.button.y),
                        .button = button,
                        .action = if (down) .press else .release,
                        .mods = modsFrom(c.SDL_GetModState()),
                    }, ev.button.x, ev.button.y);
                },
                c.EVENT_MOUSE_MOTION => {
                    const button = motionButton(ev.motion.state);
                    const action: zt.Events.MouseAction = if (button == .none) .move else .drag;
                    self.handleMouse(loop, .{
                        .x = @intFromFloat(ev.motion.x),
                        .y = @intFromFloat(ev.motion.y),
                        .button = button,
                        .action = action,
                        .mods = modsFrom(c.SDL_GetModState()),
                    }, ev.motion.x, ev.motion.y);
                },
                c.EVENT_MOUSE_WHEEL => {
                    var y_ticks = ev.wheel.integer_y;
                    if (y_ticks == 0) {
                        if (ev.wheel.y > 0) y_ticks = 1 else if (ev.wheel.y < 0) y_ticks = -1;
                    }
                    if (ev.wheel.direction != 0) y_ticks = -y_ticks;
                    var x_ticks = ev.wheel.integer_x;
                    if (x_ticks == 0) {
                        if (ev.wheel.x > 0) x_ticks = 1 else if (ev.wheel.x < 0) x_ticks = -1;
                    }
                    if (ev.wheel.direction != 0) x_ticks = -x_ticks;
                    const mods = modsFrom(c.SDL_GetModState());
                    if (y_ticks != 0) {
                        const button: zt.Events.Button = if (y_ticks > 0) .wheel_up else .wheel_down;
                        var n: i32 = if (y_ticks > 0) y_ticks else -y_ticks;
                        while (n > 0) : (n -= 1) {
                            self.handleMouse(loop, .{
                                .x = @intFromFloat(ev.wheel.mouse_x),
                                .y = @intFromFloat(ev.wheel.mouse_y),
                                .button = button,
                                .action = .press,
                                .mods = mods,
                            }, ev.wheel.mouse_x, ev.wheel.mouse_y);
                        }
                    }
                    if (x_ticks != 0) {
                        const button: zt.Events.Button = if (x_ticks > 0) .wheel_right else .wheel_left;
                        var n: i32 = if (x_ticks > 0) x_ticks else -x_ticks;
                        while (n > 0) : (n -= 1) {
                            self.handleMouse(loop, .{
                                .x = @intFromFloat(ev.wheel.mouse_x),
                                .y = @intFromFloat(ev.wheel.mouse_y),
                                .button = button,
                                .action = .press,
                                .mods = mods,
                            }, ev.wheel.mouse_x, ev.wheel.mouse_y);
                        }
                    }
                },
                c.EVENT_WINDOW_FOCUS_GAINED, c.EVENT_WINDOW_FOCUS_LOST => {
                    if (ev.type == c.EVENT_WINDOW_FOCUS_LOST) self.keys_held = 0;
                    const engine = loop.engine orelse continue;
                    if (!engine.screen.inputMode().focus_event) continue;
                    const on = ev.type == c.EVENT_WINDOW_FOCUS_GAINED;
                    self.send(loop, zt.Events.encodeFocus(on));
                },
                else => {},
            }
        }
        if (self.keys_held != 0) self.armRepeat();
    }

    fn armRepeat(self: *Host) void {
        const loop = self.loop orelse return;
        if (self.repeat_armed or loop.stopped or self.keys_held == 0) return;
        self.repeat_armed = true;
        self.repeat_timer.run(&loop.inner, &self.repeat_c, 16, Host, self, &onRepeat);
    }

    fn onRepeat(
        ud: ?*Host,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        const self = ud.?;
        self.repeat_armed = false;
        _ = r catch return .disarm;
        const loop = self.loop orelse return .disarm;
        if (loop.stopped) return .disarm;
        self.drainSdl();
        self.drainPty();
        return .disarm;
    }

    fn handleKey(self: *Host, loop: *Loop, sdl_key: u32, sdl_mod: u16, repeat: bool) void {
        const mods = modsFrom(sdl_mod);
        if (sdl_key == 0x4000003c and !mods.ctrl and !mods.alt) {
            if (repeat) return;
            if (!Debug.toggle()) self.restore_frame = true;
            if (loop.engine) |engine| self.present(&engine.frame);
            return;
        }
        const printable = sdl_key >= 0x20 and sdl_key < 0x7f;
        if (printable and !mods.ctrl and !mods.alt) return;
        const code = mapSdlKey(sdl_key);
        if (code == 0) return;
        const engine = loop.engine orelse return;
        var buf: [32]u8 = undefined;
        const bytes = zt.Events.encodeKey(&buf, .{ .code = code, .mods = mods }, engine.screen.inputMode());
        if (bytes.len != 0) self.send(loop, bytes);
    }

    fn toPixels(self: *const Host, x: f32, y: f32) struct { x: f32, y: f32 } {
        const d = c.SDL_GetWindowPixelDensity(self.window);
        const s = if (d > 0.01) d else 1;
        return .{ .x = x * s, .y = y * s };
    }

    fn handleMouse(self: *Host, loop: *Loop, mouse: zt.Events.Mouse, px: f32, py: f32) void {
        const engine = loop.engine orelse return;
        const pix = self.toPixels(px, py);
        var m = mouse;
        m.x = @intFromFloat(pix.x);
        m.y = @intFromFloat(pix.y);
        const mode = engine.screen.inputMode();
        const cell = cellAt(engine, pix.x, pix.y, self.origin_x, self.origin_y);
        const wheel = switch (mouse.button) {
            .wheel_up, .wheel_down, .wheel_left, .wheel_right => true,
            else => false,
        };
        if (mode.mouse == .off) {
            if (!wheel) return;
            if (engine.screen.altScreen() and mode.alt_scroll) {
                const sym: zt.Events.KeySym = switch (mouse.button) {
                    .wheel_up => .up,
                    .wheel_down => .down,
                    .wheel_left => .left,
                    .wheel_right => .right,
                    else => return,
                };
                var buf: [32]u8 = undefined;
                const bytes = zt.Events.encodeKey(&buf, .{ .code = @intFromEnum(sym), .mods = mouse.mods }, mode);
                if (bytes.len != 0) self.send(loop, bytes);
            } else if (!engine.screen.altScreen() and (mouse.button == .wheel_up or mouse.button == .wheel_down)) {
                const delta: i32 = if (mouse.button == .wheel_up) 3 else -3;
                engine.scrollBy(delta);
                self.present(&engine.frame);
            }
            return;
        }
        if (mouse.action == .move or mouse.action == .drag) {
            if (cell.col == self.last_mouse_col and cell.row == self.last_mouse_row) return;
        }
        self.last_mouse_col = cell.col;
        self.last_mouse_row = cell.row;
        var buf: [32]u8 = undefined;
        const bytes = zt.Events.encodeMouse(&buf, m, cell.col + 1, cell.row + 1, .{
            .tracking = mode.mouse,
            .sgr = mode.mouse_sgr,
            .urxvt = mode.mouse_urxvt,
            .pixels = mode.mouse_pixels,
        });
        if (bytes.len != 0) self.send(loop, bytes);
    }

    fn send(self: *Host, loop: *Loop, bytes: []const u8) void {
        if (self.pty) |pty| {
            pty.write(bytes);
            return;
        }
        loop.ingest(bytes);
        loop.kick();
    }

    pub fn syncEngine(self: *Host, engine: *zt.Engine) void {
        var pw: c_int = 0;
        var ph: c_int = 0;
        if (!c.SDL_GetWindowSizeInPixels(self.window, &pw, &ph) or pw <= 0 or ph <= 0) {
            pw = @intCast(self.width);
            ph = @intCast(self.height);
        }
        const density = blk: {
            const d = c.SDL_GetWindowPixelDensity(self.window);
            break :blk if (d > 0.01) d else 1;
        };
        const size_px: f32 = @max(1, @round(engine.base_size_px * density));
        var cell_w = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(engine.base_cell_w)) * density))));
        var cell_h = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(engine.base_cell_h)) * density))));
        if (engine.type_ctx) |ctx| {
            if (ctx.metrics(size_px)) |m| {
                const h = m.ascender - m.descender + m.line_gap;
                cell_h = @max(1, @as(u32, @intFromFloat(@ceil(h))));
            } else |err| Debug.log("metrics: {}", .{err});
            if (ctx.glyph('M', size_px)) |g| {
                cell_w = @max(1, @as(u32, @intFromFloat(@ceil(g.advance))));
            } else |err| Debug.log("glyph M: {}", .{err});
        }
        const metrics_changed = engine.setCellMetrics(cell_w, cell_h, size_px);

        const cols_u32 = @max(1, @as(u32, @intCast(pw)) / engine.cell_w);
        const rows_u32 = @max(1, @as(u32, @intCast(ph)) / engine.cell_h);
        const cols: u16 = @intCast(@min(cols_u32, 65535));
        const rows: u16 = @intCast(@min(rows_u32, 65535));
        const width = @as(u32, cols) * engine.cell_w;
        const height = @as(u32, rows) * engine.cell_h;
        setOrigin(self, @intCast(pw), @intCast(ph), width, height);
        if (width != self.width or height != self.height) {
            const texture = makeTexture(self.renderer, width, height) orelse {
                sdlFail("CreateTexture");
                return;
            };
            c.SDL_DestroyTexture(self.texture);
            self.texture = texture;
            self.width = width;
            self.height = height;
        }
        if (cols != engine.screen.cols or rows != engine.screen.rows or
            engine.frame.width != width or engine.frame.height != height)
        {
            engine.resize(cols, rows) catch |err| {
                Debug.log("resize: {}", .{err});
                return;
            };
        } else if (metrics_changed) {
            engine.frame.invalidate();
            engine.refresh() catch |err| {
                Debug.log("refresh: {}", .{err});
                return;
            };
        }
        if (self.pty) |pty| {
            pty.setWinsize(
                cols,
                rows,
                @intCast(@min(width, 65535)),
                @intCast(@min(height, 65535)),
            );
        }
    }

    pub fn present(self: *Host, frame: *const Draw.Frame) void {
        assert(frame.width == self.width);
        assert(frame.height == self.height);
        const overlay_on = Debug.visible;
        if (!overlay_on and !self.restore_frame and !frame.damaged()) return;
        const pixels = if (overlay_on) self.overlayPixels(frame) else frame.pixels;
        const pitch: c_int = @intCast(self.width * @sizeOf(u32));
        if (overlay_on or self.restore_frame or frame.dirty_full) {
            if (!c.SDL_UpdateTexture(self.texture, null, pixels.ptr, pitch)) sdlFail("UpdateTexture");
        } else {
            const y = frame.dirty_y;
            const h = frame.dirty_h;
            const rect = c.Rect{
                .x = 0,
                .y = @intCast(y),
                .w = @intCast(self.width),
                .h = @intCast(h),
            };
            if (!c.SDL_UpdateTexture(self.texture, &rect, frame.pixels[y * self.width ..].ptr, pitch)) sdlFail("UpdateTexture");
        }
        self.restore_frame = false;
        const bg = schemeBg(self);
        if (!c.SDL_SetRenderDrawColor(self.renderer, bg.r, bg.g, bg.b, bg.a)) sdlFail("SetRenderDrawColor");
        if (!c.SDL_RenderClear(self.renderer)) sdlFail("RenderClear");
        var pw: c_int = 0;
        var ph: c_int = 0;
        if (c.SDL_GetWindowSizeInPixels(self.window, &pw, &ph) and pw > 0 and ph > 0) {
            setOrigin(self, @intCast(pw), @intCast(ph), self.width, self.height);
        }
        const dst = c.FRect{
            .x = @floatFromInt(self.origin_x),
            .y = @floatFromInt(self.origin_y),
            .w = @floatFromInt(self.width),
            .h = @floatFromInt(self.height),
        };
        if (!c.SDL_RenderTexture(self.renderer, self.texture, null, &dst)) sdlFail("RenderTexture");
        if (!c.SDL_RenderPresent(self.renderer)) sdlFail("RenderPresent");
    }

    fn overlayPixels(self: *Host, frame: *const Draw.Frame) []u32 {
        const n = frame.pixels.len;
        if (self.overlay.len != n) {
            if (self.overlay.len != 0) std.heap.page_allocator.free(self.overlay);
            self.overlay = std.heap.page_allocator.alloc(u32, n) catch {
                self.overlay = &.{};
                Debug.log("overlay alloc failed", .{});
                return frame.pixels;
            };
        }
        @memcpy(self.overlay, frame.pixels);
        var status_buf: [96]u8 = undefined;
        const status = overlayStatus(self, frame, &status_buf);
        Debug.paint(self.overlay, frame.width, frame.height, status);
        return self.overlay;
    }
};

fn setOrigin(self: *Host, win_w: u32, win_h: u32, grid_w: u32, grid_h: u32) void {
    self.origin_x = @intCast(if (win_w > grid_w) (win_w - grid_w) / 2 else 0);
    self.origin_y = @intCast(if (win_h > grid_h) (win_h - grid_h) / 2 else 0);
}

fn schemeBg(self: *const Host) zt.Term.Color {
    if (self.loop) |loop| {
        if (loop.engine) |engine| return engine.screen.scheme.bg;
    }
    return .{ .r = 0, .g = 0, .b = 0 };
}

fn overlayStatus(self: *const Host, frame: *const Draw.Frame, buf: []u8) []const u8 {
    if (self.loop) |loop| {
        if (loop.engine) |e| {
            return std.fmt.bufPrint(buf, "{d}x{d} cell {d}x{d} {d}x{d}px fill {d}ns glyph {d}ns log {d}", .{
                e.screen.cols,
                e.screen.rows,
                e.cell_w,
                e.cell_h,
                frame.width,
                frame.height,
                e.frame.last_fill_ns,
                e.frame.last_glyph_ns,
                Debug.count(),
            }) catch "debug";
        }
    }
    return std.fmt.bufPrint(buf, "frame {d}x{d} log {d}", .{ frame.width, frame.height, Debug.count() }) catch "debug";
}

fn sdlFail(what: []const u8) void {
    const err = std.mem.span(c.SDL_GetError());
    Debug.log("sdl {s}: {s}", .{ what, err });
}

fn makeTexture(renderer: *c.Renderer, width: u32, height: u32) ?*c.Texture {
    const texture = c.SDL_CreateTexture(
        renderer,
        c.PIXELFORMAT_ARGB8888,
        c.TEXTUREACCESS_STREAMING,
        @intCast(width),
        @intCast(height),
    ) orelse return null;
    _ = c.SDL_SetTextureScaleMode(texture, c.SCALEMODE_NEAREST);
    return texture;
}

fn modsFrom(m: u16) zt.Events.Mods {
    return .{
        .shift = m & c.KMOD_SHIFT != 0,
        .ctrl = m & c.KMOD_CTRL != 0,
        .alt = m & c.KMOD_ALT != 0,
        .super = m & c.KMOD_GUI != 0,
    };
}

fn sdlButton(b: u8) zt.Events.Button {
    return switch (b) {
        c.BUTTON_LEFT => .left,
        c.BUTTON_MIDDLE => .middle,
        c.BUTTON_RIGHT => .right,
        else => .none,
    };
}

fn motionButton(state: u32) zt.Events.Button {
    if (state & 1 != 0) return .left;
    if (state & 2 != 0) return .middle;
    if (state & 4 != 0) return .right;
    return .none;
}

fn mapSdlKey(k: u32) u32 {
    const KS = zt.Events.KeySym;
    return switch (k) {
        0x0d, 0x40000058 => @intFromEnum(KS.enter),
        0x1b => @intFromEnum(KS.escape),
        0x08 => @intFromEnum(KS.backspace),
        0x09 => @intFromEnum(KS.tab),
        0x20 => @intFromEnum(KS.space),
        0x7f => @intFromEnum(KS.delete),
        0x4000003a => @intFromEnum(KS.f1),
        0x4000003b => @intFromEnum(KS.f2),
        0x4000003c => @intFromEnum(KS.f3),
        0x4000003d => @intFromEnum(KS.f4),
        0x4000003e => @intFromEnum(KS.f5),
        0x4000003f => @intFromEnum(KS.f6),
        0x40000040 => @intFromEnum(KS.f7),
        0x40000041 => @intFromEnum(KS.f8),
        0x40000042 => @intFromEnum(KS.f9),
        0x40000043 => @intFromEnum(KS.f10),
        0x40000044 => @intFromEnum(KS.f11),
        0x40000045 => @intFromEnum(KS.f12),
        0x40000049 => @intFromEnum(KS.insert),
        0x4000004a => @intFromEnum(KS.home),
        0x4000004b => @intFromEnum(KS.page_up),
        0x4000004d => @intFromEnum(KS.end),
        0x4000004e => @intFromEnum(KS.page_down),
        0x4000004f => @intFromEnum(KS.right),
        0x40000050 => @intFromEnum(KS.left),
        0x40000051 => @intFromEnum(KS.down),
        0x40000052 => @intFromEnum(KS.up),
        else => if (k >= 0x20 and k < 0x7f) k else 0,
    };
}

fn cellAt(engine: *zt.Engine, px: f32, py: f32, origin_x: i32, origin_y: i32) struct { col: u16, row: u16 } {
    const x: i32 = @max(0, @as(i32, @intFromFloat(@floor(px))) - origin_x);
    const y: i32 = @max(0, @as(i32, @intFromFloat(@floor(py))) - origin_y);
    const cw: i32 = @intCast(engine.cell_w);
    const ch: i32 = @intCast(engine.cell_h);
    var col: u16 = @intCast(@min(@divTrunc(x, cw), @as(i32, engine.screen.cols) - 1));
    var row: u16 = @intCast(@min(@divTrunc(y, ch), @as(i32, engine.screen.rows) - 1));
    if (engine.screen.cols == 0) col = 0;
    if (engine.screen.rows == 0) row = 0;
    return .{ .col = col, .row = row };
}

fn windowFd(window: *c.Window) ?std.posix.fd_t {
    return switch (builtin.os.tag) {
        .linux => windowFdLinux(window),
        else => null,
    };
}

fn windowFdLinux(window: *c.Window) ?std.posix.fd_t {
    const props = c.SDL_GetWindowProperties(window);
    if (props == 0) return null;
    if (c.SDL_GetPointerProperty(props, "SDL.window.wayland.display", null)) |ptr| {
        if (cIntFn("libwayland-client.so.0", "wl_display_get_fd")) |f| {
            const fd = f(ptr);
            if (fd >= 0) return fd;
        }
    }
    if (c.SDL_GetPointerProperty(props, "SDL.window.x11.display", null)) |ptr| {
        if (cIntFn("libX11.so.6", "XConnectionNumber")) |f| {
            const fd = f(ptr);
            if (fd >= 0) return fd;
        }
    }
    return null;
}

fn cIntFn(lib: [*:0]const u8, sym: [*:0]const u8) ?*const fn (?*anyopaque) callconv(.c) c_int {
    const noload = std.c.RTLD{ .LAZY = true, .NOLOAD = true };
    const lazy = std.c.RTLD{ .LAZY = true };
    const handle = std.c.dlopen(lib, noload) orelse std.c.dlopen(lib, lazy) orelse return null;
    const p = std.c.dlsym(handle, sym) orelse return null;
    return @ptrCast(@alignCast(p));
}
