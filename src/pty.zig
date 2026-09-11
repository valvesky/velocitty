//! Host PTY. Send bytes to a shell.
//! 

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;

pub const Pty = struct {
    master: posix.fd_t,
    child: posix.pid_t,

    pub fn open(cols: u16, rows: u16, px_w: u16, px_h: u16) error{OpenPty}!Pty {
        return switch (builtin.os.tag) {
            .linux => openLinux(cols, rows, px_w, px_h),
            .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => openBsd(cols, rows, px_w, px_h),
            else => error.OpenPty,
        };
    }

    pub fn close(self: *Pty) void {
        switch (builtin.os.tag) {
            .linux => _ = linux.close(self.master),
            .windows, .wasi => {},
            else => _ = std.c.close(self.master),
        }
        self.* = undefined;
    }

    pub fn write(self: *Pty, bytes: []const u8) void {
        if (bytes.len == 0) return;
        switch (builtin.os.tag) {
            .linux => _ = linux.write(self.master, bytes.ptr, bytes.len),
            .windows, .wasi => {},
            else => _ = std.c.write(self.master, bytes.ptr, bytes.len),
        }
    }

    pub fn setWinsize(self: *Pty, cols: u16, rows: u16, px_w: u16, px_h: u16) void {
        var ws = posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = px_w,
            .ypixel = px_h,
        };
        switch (builtin.os.tag) {
            .linux => _ = linux.ioctl(self.master, linux.T.IOCSWINSZ, @intFromPtr(&ws)),
            .windows, .wasi => {},
            else => _ = std.c.ioctl(self.master, tiocswinsz(), @intFromPtr(&ws)),
        }
    }

    pub fn read(self: *Pty, buf: []u8) error{Hangup}![]u8 {
        switch (builtin.os.tag) {
            .linux => {
                const rc = linux.read(self.master, buf.ptr, buf.len);
                const e = linux.errno(rc);
                if (e == .AGAIN or e == .INTR) return buf[0..0];
                if (e != .SUCCESS) return error.Hangup;
                if (rc == 0) return error.Hangup;
                return buf[0..rc];
            },
            .windows, .wasi => return error.Hangup,
            else => {
                const n = posix.read(self.master, buf) catch |err| switch (err) {
                    error.WouldBlock => return buf[0..0],
                    else => return error.Hangup,
                };
                if (n == 0) return error.Hangup;
                return buf[0..n];
            },
        }
    }
};

fn openLinux(cols: u16, rows: u16, px_w: u16, px_h: u16) error{OpenPty}!Pty {
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
    const path = std.fmt.bufPrintZ(&path_buf, "/dev/pts/{d}", .{ptn}) catch return error.OpenPty;
    const shell = shellPath();
    const ws = posix.winsize{
        .row = rows,
        .col = cols,
        .xpixel = px_w,
        .ypixel = px_h,
    };

    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) return error.OpenPty;
    const pid: posix.pid_t = @intCast(pid_rc);
    if (pid == 0) childExecLinux(path, master, shell, ws);

    var ws_mut = ws;
    _ = linux.ioctl(master, linux.T.IOCSWINSZ, @intFromPtr(&ws_mut));
    return .{ .master = master, .child = pid };
}

fn openBsd(cols: u16, rows: u16, px_w: u16, px_h: u16) error{OpenPty}!Pty {
    const flags = std.c.O{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
        .NONBLOCK = true,
    };
    const master_rc = std.c.open("/dev/ptmx", flags);
    if (master_rc < 0) return error.OpenPty;
    const master: posix.fd_t = master_rc;
    errdefer _ = std.c.close(master);

    if (grantpt(master) != 0) return error.OpenPty;
    if (unlockpt(master) != 0) return error.OpenPty;
    const path = ptsname(master) orelse return error.OpenPty;
    const shell = shellPath();
    const ws = posix.winsize{
        .row = rows,
        .col = cols,
        .xpixel = px_w,
        .ypixel = px_h,
    };

    const pid = std.c.fork();
    if (pid < 0) return error.OpenPty;
    if (pid == 0) childExecBsd(path, master, shell, ws);

    var ws_mut = ws;
    _ = std.c.ioctl(master, tiocswinsz(), @intFromPtr(&ws_mut));
    return .{ .master = master, .child = pid };
}

fn shellPath() [*:0]const u8 {
    if (std.c.getenv("SHELL")) |s| {
        if (std.mem.span(s).len > 0) return s;
    }
    return "/bin/sh";
}

fn childExecLinux(slave_path: [*:0]const u8, master: posix.fd_t, shell: [*:0]const u8, ws: posix.winsize) noreturn {
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

fn childExecBsd(slave_path: [*:0]const u8, master: posix.fd_t, shell: [*:0]const u8, ws: posix.winsize) noreturn {
    _ = std.c.close(master);
    _ = std.c.setsid();
    const slave = std.c.open(slave_path, .{ .ACCMODE = .RDWR });
    if (slave < 0) std.process.exit(127);
    _ = std.c.ioctl(slave, tiocsctty(), @as(c_int, 0));
    var ws_mut = ws;
    _ = std.c.ioctl(slave, tiocswinsz(), @intFromPtr(&ws_mut));
    _ = std.c.dup2(slave, 0);
    _ = std.c.dup2(slave, 1);
    _ = std.c.dup2(slave, 2);
    if (slave > 2) _ = std.c.close(slave);
    execShell(shell);
}

fn execShell(shell: [*:0]const u8) noreturn {
    _ = setenv("TERM", "xterm-256color", 1);
    _ = setenv("COLORTERM", "truecolor", 1);
    const argv = [_:null]?[*:0]const u8{ shell, null };
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    _ = std.c.execve(shell, &argv, envp);
    std.process.exit(127);
}

fn tiocswinsz() c_int {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .dragonfly, .netbsd, .openbsd => ioctlNum(0x80087467),
        else => 0,
    };
}

fn tiocsctty() c_int {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .dragonfly, .netbsd, .openbsd => ioctlNum(0x20007461),
        else => 0,
    };
}

fn ioctlNum(v: u32) c_int {
    return @bitCast(v);
}
