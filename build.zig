const std = @import("std");

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main build step (optimize from -Doptimize / --release; default Debug).
    const exe = buildExeForTarget(b, target, optimize);
    b.installArtifact(exe);
    b.installFile("velocitty.desktop", "share/applications/velocitty.desktop");
    b.installFile("icon.png", "share/icons/hicolor/512x512/apps/velocitty.png");

    // Standard run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run velocitty");
    run_step.dependOn(&run_cmd.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    addStbTrueType(bench_mod, b);
    const bench_exe = b.addExecutable(.{
        .name = "velocitty-bench",
        .root_module = bench_mod,
    });
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run firehose/parse/VT microbenchmark (ReleaseFast)");
    bench_step.dependOn(&bench_run.step);

    // Release cross-compilation step. Only targets the host can actually
    // compile and link are built (Linux + same-arch X11 today).
    const release_step = b.step("release", "Build optimized velocitty for all target platforms");

    for (targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        if (!canLinkReleaseTarget(b, resolved)) continue;
        const triple = query.zigTriple(b.allocator) catch @panic("OOM");

        const exe_rel = buildExeForTarget(b, resolved, .ReleaseFast);

        const install = b.addInstallArtifact(exe_rel, .{
            .dest_dir = .{ .override = .{ .custom = triple } },
        });

        release_step.dependOn(&install.step);
    }

    // `install` is Zig's prefix step (zig-out by default). This one is the
    // host ReleaseFast copy to /usr so it shows up on PATH and the Omarchy menu.
    // Privilege: sudo when stdin is a TTY, pkexec (polkit dialog) otherwise.
    const host_target = b.resolveTargetQuery(.{});
    const usr_exe = buildExeForTarget(b, host_target, .ReleaseFast);
    const usr_cmd = b.addSystemCommand(&.{"bash"});
    usr_cmd.addFileArg(b.path("scripts/install-usr.sh"));
    usr_cmd.addArtifactArg(usr_exe);
    usr_cmd.addFileArg(b.path("velocitty.desktop"));
    usr_cmd.addFileArg(b.path("icon.png"));
    usr_cmd.stdio = .inherit;
    usr_cmd.has_side_effects = true;
    usr_cmd.disable_zig_progress = true;
    usr_cmd.setName("install-usr");

    const usr_step = b.step("install-usr", "Build ReleaseFast for the host and install to /usr (sudo/pkexec)");
    usr_step.dependOn(&usr_cmd.step);
}

fn canLinkReleaseTarget(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = b.graph.host.result;
    const t = target.result;
    if (t.os.tag != .linux) return false;
    if (t.cpu.arch != host.cpu.arch) return false;
    if (t.abi != host.abi) return false;
    return true;
}

fn buildExeForTarget(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    addStbTrueType(exe_mod, b);

    const exe = b.addExecutable(.{
        .name = "velocitty",
        .root_module = exe_mod,
    });

    if (target.result.os.tag == .linux) {
        addLinuxX11(b, exe.root_module, target);
    } else if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("ws2_32", .{});
        exe.root_module.linkSystemLibrary("mswsock", .{});
    }

    return exe;
}

fn addLinuxX11(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const host = b.graph.host.result;
    if (target.result.cpu.arch == host.cpu.arch) {
        mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    }
    mod.linkSystemLibrary("X11", .{});
    mod.linkSystemLibrary("Xi", .{});
}

fn addStbTrueType(mod: *std.Build.Module, b: *std.Build) void {
    mod.addIncludePath(b.path("lib"));
    const flags: []const []const u8 = &.{ "-std=c99", "-fno-sanitize=undefined" };
    mod.addCSourceFile(.{ .file = b.path("src/type/stb_truetype.c"), .flags = flags });
    mod.addCSourceFile(.{ .file = b.path("src/stb_image.c"), .flags = flags });
}
