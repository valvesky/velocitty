//! JSONL daemon protocol. Escape sequences are never accepted or emitted.

const std = @import("std");
const assert = std.debug.assert;
const xev = @import("xev");
const Loop = @import("loop.zig").Loop;

pub const default_port: u16 = 7701;

pub const Cmd = enum {
    attach,
    detach,
    list,
    new,
    kill,
};

pub const Request = struct {
    cmd: Cmd,
    args: []const u8,
};

pub const Options = struct {
    port: u16 = default_port,
};

pub fn parseLine(line: []const u8) error{InvalidProtocol}!Request {
    const s = std.mem.trim(u8, line, " \t\r\n");
    if (s.len < 2 or s[0] != '{' or s[s.len - 1] != '}') return error.InvalidProtocol;
    const inner = s[1 .. s.len - 1];
    const cmd_s = (try jsonStr(inner, "cmd")) orelse return error.InvalidProtocol;
    const args = (try jsonStr(inner, "args")) orelse "";
    const cmd = std.meta.stringToEnum(Cmd, cmd_s) orelse return error.InvalidProtocol;
    return .{ .cmd = cmd, .args = args };
}

pub fn encodeAlloc(allocator: std.mem.Allocator, cmd: Cmd, args: []const u8) std.mem.Allocator.Error![]u8 {
    assert(std.mem.indexOfScalar(u8, args, 0x1b) == null);
    assert(std.mem.indexOfScalar(u8, args, '"') == null);
    return std.fmt.allocPrint(allocator, "{{\"cmd\":\"{s}\",\"args\":\"{s}\"}}\n", .{ @tagName(cmd), args });
}

fn jsonStr(obj: []const u8, key: []const u8) error{InvalidProtocol}!?[]const u8 {
    var keybuf: [16]u8 = undefined;
    const k = std.fmt.bufPrint(&keybuf, "\"{s}\"", .{key}) catch return error.InvalidProtocol;
    const at = std.mem.indexOf(u8, obj, k) orelse return null;
    var i = at + k.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) i += 1;
    if (i >= obj.len or obj[i] != ':') return error.InvalidProtocol;
    i += 1;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) i += 1;
    if (i >= obj.len or obj[i] != '"') return error.InvalidProtocol;
    i += 1;
    const vstart = i;
    while (i < obj.len) : (i += 1) {
        if (obj[i] == '"') return obj[vstart..i];
        if (obj[i] == 0x1b or obj[i] == '\\') return error.InvalidProtocol;
    }
    return error.InvalidProtocol;
}

const Client = struct {
    server: *Server,
    tcp: xev.TCP,
    c_read: xev.Completion = .{},
    c_write: xev.Completion = .{},
    c_close: xev.Completion = .{},
    read_buf: [512]u8 = undefined,
    line: std.ArrayList(u8) = .empty,
    out: ?[]u8 = null,
    closing: bool = false,

    fn drain(self: *Client, l: *xev.Loop) void {
        if (self.out != null or self.closing) return;
        const nl = std.mem.indexOfScalar(u8, self.line.items, '\n') orelse return;
        const req = parseLine(self.line.items[0 .. nl + 1]) catch {
            self.shutdown(l);
            return;
        };
        const resp = self.server.apply(req) catch unreachable;
        self.line.replaceRange(self.server.allocator, 0, nl + 1, &.{}) catch unreachable;
        self.out = resp;
        self.tcp.write(l, &self.c_write, .{ .slice = resp }, Client, self, &onWrite);
    }

    fn shutdown(self: *Client, l: *xev.Loop) void {
        if (self.closing) return;
        self.closing = true;
        self.tcp.close(l, &self.c_close, Client, self, &onClose);
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    loop: *Loop,
    port: u16,
    tcp: ?xev.TCP = null,
    c_accept: xev.Completion = .{},
    c_close: xev.Completion = .{},
    sessions: std.ArrayList([]u8) = .empty,
    clients: std.ArrayList(*Client) = .empty,

    pub fn init(allocator: std.mem.Allocator, loop: *Loop, options: Options) Server {
        return .{
            .allocator = allocator,
            .loop = loop,
            .port = options.port,
        };
    }

    pub fn deinit(self: *Server) void {
        for (self.clients.items) |c| {
            c.line.deinit(self.allocator);
            if (c.out) |o| self.allocator.free(o);
            self.allocator.destroy(c);
        }
        self.clients.deinit(self.allocator);
        for (self.sessions.items) |n| self.allocator.free(n);
        self.sessions.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn listen(self: *Server) !void {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", self.port);
        const tcp = try xev.TCP.init(addr);
        try tcp.bind(addr);
        try tcp.listen(128);
        self.tcp = tcp;
        tcp.accept(&self.loop.inner, &self.c_accept, Server, self, &onAccept);
    }

    pub fn close(self: *Server) void {
        const tcp = self.tcp orelse return;
        tcp.close(&self.loop.inner, &self.c_close, Server, self, &onListenClose);
    }

    pub fn apply(self: *Server, req: Request) std.mem.Allocator.Error![]u8 {
        switch (req.cmd) {
            .new => {
                const name = try self.allocator.dupe(u8, req.args);
                errdefer self.allocator.free(name);
                try self.sessions.append(self.allocator, name);
                return encodeAlloc(self.allocator, .new, name);
            },
            .kill => {
                var i: usize = 0;
                while (i < self.sessions.items.len) {
                    if (std.mem.eql(u8, self.sessions.items[i], req.args)) {
                        self.allocator.free(self.sessions.items[i]);
                        _ = self.sessions.orderedRemove(i);
                        break;
                    }
                    i += 1;
                }
                return encodeAlloc(self.allocator, .kill, req.args);
            },
            .list => {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(self.allocator);
                for (self.sessions.items, 0..) |n, i| {
                    if (i != 0) try buf.append(self.allocator, ' ');
                    try buf.appendSlice(self.allocator, n);
                }
                return encodeAlloc(self.allocator, .list, buf.items);
            },
            .attach, .detach => return encodeAlloc(self.allocator, req.cmd, req.args),
        }
    }
};

fn onAccept(
    ud: ?*Server,
    l: *xev.Loop,
    _: *xev.Completion,
    r: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    const self = ud.?;
    const conn = r catch return .disarm;
    const client = self.allocator.create(Client) catch unreachable;
    client.* = .{
        .server = self,
        .tcp = conn,
    };
    self.clients.append(self.allocator, client) catch unreachable;
    client.tcp.read(l, &client.c_read, .{ .slice = &client.read_buf }, Client, client, &onRead);
    return .rearm;
}

fn onRead(
    ud: ?*Client,
    l: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const self = ud.?;
    const n = r catch {
        self.shutdown(l);
        return .disarm;
    };
    if (n == 0) {
        self.shutdown(l);
        return .disarm;
    }
    if (self.line.items.len + n > 4096) {
        self.shutdown(l);
        return .disarm;
    }
    self.line.appendSlice(self.server.allocator, self.read_buf[0..n]) catch unreachable;
    self.drain(l);
    if (self.closing) return .disarm;
    return .rearm;
}

fn onWrite(
    ud: ?*Client,
    l: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const self = ud.?;
    if (self.out) |o| {
        self.server.allocator.free(o);
        self.out = null;
    }
    _ = r catch {
        self.shutdown(l);
        return .disarm;
    };
    self.drain(l);
    return .disarm;
}

fn onClose(
    ud: ?*Client,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    r: xev.CloseError!void,
) xev.CallbackAction {
    _ = r catch {};
    const self = ud.?;
    const server = self.server;
    for (server.clients.items, 0..) |c, i| {
        if (c == self) {
            _ = server.clients.orderedRemove(i);
            break;
        }
    }
    self.line.deinit(server.allocator);
    if (self.out) |o| server.allocator.free(o);
    server.allocator.destroy(self);
    return .disarm;
}

fn onListenClose(
    ud: ?*Server,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    r: xev.CloseError!void,
) xev.CallbackAction {
    _ = r catch {};
    ud.?.tcp = null;
    return .disarm;
}

const Rpc = struct {
    tcp: xev.TCP,
    c: xev.Completion = .{},
    w: xev.Completion = .{},
    buf: [1024]u8 = undefined,
    out: []u8,
    reply: []u8 = &.{},
    allocator: std.mem.Allocator,
    failed: bool = false,
};

pub fn request(allocator: std.mem.Allocator, loop: *Loop, port: u16, cmd: Cmd, args: []const u8) ![]u8 {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var st: Rpc = .{
        .tcp = try xev.TCP.init(addr),
        .out = try encodeAlloc(allocator, cmd, args),
        .allocator = allocator,
    };
    st.tcp.connect(&loop.inner, &st.c, addr, Rpc, &st, &onRpcConnect);
    try loop.run();
    if (st.failed) {
        if (st.reply.len != 0) allocator.free(st.reply);
        return error.InvalidProtocol;
    }
    return st.reply;
}

fn onRpcConnect(
    ud: ?*Rpc,
    l: *xev.Loop,
    _: *xev.Completion,
    s: xev.TCP,
    r: xev.ConnectError!void,
) xev.CallbackAction {
    const st = ud.?;
    _ = r catch {
        st.failed = true;
        st.allocator.free(st.out);
        st.out = &.{};
        return .disarm;
    };
    s.write(l, &st.w, .{ .slice = st.out }, Rpc, st, &onRpcWrite);
    return .disarm;
}

fn onRpcWrite(
    ud: ?*Rpc,
    l: *xev.Loop,
    _: *xev.Completion,
    s: xev.TCP,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const st = ud.?;
    st.allocator.free(st.out);
    st.out = &.{};
    _ = r catch {
        st.failed = true;
        return .disarm;
    };
    s.read(l, &st.c, .{ .slice = &st.buf }, Rpc, st, &onRpcRead);
    return .disarm;
}

fn onRpcRead(
    ud: ?*Rpc,
    l: *xev.Loop,
    _: *xev.Completion,
    s: xev.TCP,
    _: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const st = ud.?;
    const n = r catch {
        st.failed = true;
        return .disarm;
    };
    if (n == 0) {
        st.failed = true;
        s.close(l, &st.w, Rpc, st, &onRpcClose);
        return .disarm;
    }
    st.reply = st.allocator.dupe(u8, st.buf[0..n]) catch {
        st.failed = true;
        return .disarm;
    };
    s.close(l, &st.w, Rpc, st, &onRpcClose);
    return .disarm;
}

fn onRpcClose(
    _: ?*Rpc,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    r: xev.CloseError!void,
) xev.CallbackAction {
    _ = r catch {};
    return .disarm;
}

test "parse attach" {
    const req = try parseLine("{\"cmd\":\"attach\",\"args\":\"dev\"}");
    try std.testing.expectEqual(Cmd.attach, req.cmd);
    try std.testing.expectEqualStrings("dev", req.args);
}

test "reject escape" {
    try std.testing.expectError(error.InvalidProtocol, parseLine("{\"cmd\":\"new\",\"args\":\"\x1b[0m\"}"));
}

test "encode has no esc" {
    const gpa = std.testing.allocator;
    const line = try encodeAlloc(gpa, .list, "");
    defer gpa.free(line);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, 0x1b) == null);
    const round = try parseLine(line);
    try std.testing.expectEqual(Cmd.list, round.cmd);
}

test "apply new list kill" {
    const gpa = std.testing.allocator;
    var loop = try Loop.init(gpa);
    defer loop.deinit();
    var server = Server.init(gpa, &loop, .{});
    defer server.deinit();
    const created = try server.apply(.{ .cmd = .new, .args = "dev" });
    defer gpa.free(created);
    const listed = try server.apply(.{ .cmd = .list, .args = "" });
    defer gpa.free(listed);
    const round = try parseLine(listed);
    try std.testing.expectEqual(Cmd.list, round.cmd);
    try std.testing.expectEqualStrings("dev", round.args);
    const killed = try server.apply(.{ .cmd = .kill, .args = "dev" });
    defer gpa.free(killed);
    const empty = try server.apply(.{ .cmd = .list, .args = "" });
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("", (try parseLine(empty)).args);
}
