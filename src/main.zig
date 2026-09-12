const std = @import("std");
const builtin = @import("builtin");

const Platform = @import("platform/platform.zig");
const Debug = @import("debug.zig");

const CircBuffer = @import("circbuffer.zig").CircBuffer;
const Term = @import("term.zig").Term;

pub fn main() !void {


    var gpa = std.heap.DebugAllocator(.{}){};

    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var term: Term = Term.init(allocator, 80, 60);
    defer term.deinit();

    var circbuffer: CircBuffer = CircBuffer.create(allocator, 64 * 1024);
    defer circbuffer.destroy();

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
                    term.resize(r.cols, r.rows);
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

        // NOTE(vasco):
        // We want something like the following:
        //
        // while(pty.wait)
        // if eof => consume; break;
        // if eagain check 1/hz clock => consume
        // else continue

        const runs = circbuffer.consumeAndGetRuns(term);
        term.feedRuns(runs, circbuffer.storage);

        const fb = window.framebuffer();
        fb.clear(0xFF1E1E1E);
        window.present();
    }
}
