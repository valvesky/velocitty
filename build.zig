const std = @import("std");

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
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
    b.installFile("velocitty.1", "share/man/man1/velocitty.1");

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
    bench_run.setCwd(b.path("."));
    bench_run.has_side_effects = true;
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run pipeline microbenchmark: IO/parse/VT/draw/LRU (ReleaseFast)");
    bench_step.dependOn(&bench_run.step);

    // Release: Linux gnu/musl. Same-arch links system X11; other arches use
    // link-time X11/Xi stubs (runtime still needs the real libraries).
    const release_step = b.step("release", "Build optimized velocitty for all target platforms");
    const package_step = b.step("package", "Build release and write tar.gz archives to packages/");
    package_step.dependOn(release_step);

    const version = @import("build.zig.zon").version;
    const packages_dir = b.pathFromRoot("packages");

    for (targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        if (!canLinkReleaseTarget(b, resolved)) continue;
        const triple = query.zigTriple(b.allocator) catch @panic("OOM");

        const exe_rel = buildExeForTarget(b, resolved, .ReleaseFast);

        const install = b.addInstallArtifact(exe_rel, .{
            .dest_dir = .{ .override = .{ .custom = triple } },
        });

        release_step.dependOn(&install.step);

        const pkg_cmd = b.addSystemCommand(&.{"bash"});
        pkg_cmd.addFileArg(b.path("scripts/package.sh"));
        pkg_cmd.addArg(version);
        pkg_cmd.addArg(triple);
        pkg_cmd.addArtifactArg(exe_rel);
        pkg_cmd.addFileArg(b.path("velocitty.desktop"));
        pkg_cmd.addFileArg(b.path("icon.png"));
        pkg_cmd.addFileArg(b.path("velocitty.1"));
        pkg_cmd.addArg(packages_dir);
        pkg_cmd.stdio = .inherit;
        pkg_cmd.has_side_effects = true;
        pkg_cmd.disable_zig_progress = true;
        pkg_cmd.setName(b.fmt("package-{s}", .{triple}));
        package_step.dependOn(&pkg_cmd.step);
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
    usr_cmd.addFileArg(b.path("velocitty.1"));
    usr_cmd.stdio = .inherit;
    usr_cmd.has_side_effects = true;
    usr_cmd.disable_zig_progress = true;
    usr_cmd.setName("install-usr");

    const usr_step = b.step("install-usr", "Build ReleaseFast for the host and install to /usr (sudo/pkexec)");
    usr_step.dependOn(&usr_cmd.step);
}

fn canLinkReleaseTarget(_: *std.Build, target: std.Build.ResolvedTarget) bool {
    const t = target.result;
    if (t.os.tag != .linux) return false;
    return t.abi == .gnu or t.abi == .musl;
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
    // After Zig's libc so host bits/math.h cannot shadow the target headers.
    mod.addAfterIncludePath(.{ .cwd_relative = "/usr/include" });
    const host = b.graph.host.result;
    if (target.result.cpu.arch == host.cpu.arch) {
        mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    } else {
        // Host has no aarch64 (etc.) libX11/libXi; stub .so files provide link
        // symbols and the libX11.so.6 / libXi.so.6 sonames. Not packaged.
        const x11 = addX11LinkStub(b, target, "X11", "src/platform/x11_link_stub.c");
        const xi = addX11LinkStub(b, target, "Xi", "src/platform/xi_link_stub.c");
        mod.addLibraryPath(x11.getEmittedBinDirectory());
        mod.addLibraryPath(xi.getEmittedBinDirectory());
    }
    const syslib: std.Build.Module.LinkSystemLibraryOptions = .{
        .needed = true,
        .use_pkg_config = .no,
    };
    mod.linkSystemLibrary("X11", syslib);
    mod.linkSystemLibrary("Xi", syslib);
}

fn addX11LinkStub(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    src: []const u8,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .version = .{ .major = 6, .minor = 0, .patch = 0 },
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseSmall,
            .link_libc = true,
            .pic = true,
        }),
    });
    lib.root_module.addCSourceFile(.{
        .file = b.path(src),
        .flags = &.{ "-std=c99", "-fPIC", "-fno-sanitize=undefined" },
    });
    return lib;
}

fn addStbTrueType(mod: *std.Build.Module, b: *std.Build) void {
    mod.addIncludePath(b.path("lib"));
    const flags: []const []const u8 = &.{ "-std=c99", "-fno-sanitize=undefined" };
    mod.addCSourceFile(.{ .file = b.path("src/type/stb_truetype.c"), .flags = flags });
    mod.addCSourceFile(.{ .file = b.path("src/stb_image.c"), .flags = flags });
}
