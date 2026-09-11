const std = @import("std");
const builtin = @import("builtin");

const Pty = @import("pty.zig").Pty;

const Platform = @import("platform/platform.zig");
const Debug = @import("debug.zig");

pub fn main() !void {


    var gpa = std.heap.DebugAllocator(.{}){};

    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Initialize and open the window
    var window = try Platform.Window.open(allocator, "Velocitty", 800, 600);
    defer window.close();

    var running = true;


    while (running) {
        var ev: Platform.Event = undefined;
        while (window.pollEvent(&ev)) {
            switch (ev) {
                .quit => {
                    running = false;
                },
                .resize => |r| {
                    Debug.log("Resized to: {d}x{d} (cols: {d}, rows: {d})\n", .{
                        r.px_w, r.px_h, r.cols, r.rows,
                    });
                },
                .key_press => |k| {
                    if (k.key == .escape) {
                        running = false;
                    }
                    Debug.log("Key pressed: {}\n", .{k.key});
                },
                .text_input => |text| {
                    Debug.log("Text input: {s}\n", .{text});
                },
                else => {},
            }
        }

        const fb = window.framebuffer();
        fb.clear(0xFF1E1E1E);
        window.present();
    }
}
