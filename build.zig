const std = @import("std");

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 28, .patch = 0 } },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 28, .patch = 0 } },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const macos_sdk = b.option([]const u8, "macos-sdk", "macOS SDK directory for cross-compilation");
    const release_os = b.option(std.Target.Os.Tag, "release-os", "Restrict release/package builds to one operating system");

    // Main build step (optimize from -Doptimize / --release; default Debug).
    const exe = buildExeForTarget(b, target, optimize, macos_sdk);
    b.installArtifact(exe);
    if (target.result.os.tag == .linux) {
        b.installFile("velocitty.desktop", "share/applications/velocitty.desktop");
        b.installFile("icon.png", "share/icons/hicolor/512x512/apps/velocitty.png");
        b.installFile("velocitty.1", "share/man/man1/velocitty.1");
    }
    const tests_mod = appModule(b, target, optimize, "src/port_test.zig", macos_sdk);
    const tests = b.addTest(.{ .root_module = tests_mod });
    if (target.result.os.tag == .windows) tests.win32_manifest = b.path("velocitty.manifest");
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run inline and portable Peak regressions");
    test_step.dependOn(&test_run.step);
    const native_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    addPeakSource(native_mod, b, target, "tests/peak_native.c");
    addMacSdk(native_mod, b, target, macos_sdk);
    const native_tests = b.addExecutable(.{ .name = "peak-native-test", .root_module = native_mod });
    if (target.result.os.tag == .windows) native_tests.win32_manifest = b.path("velocitty.manifest");
    const native_run = b.addRunArtifact(native_tests);
    test_step.dependOn(&native_run.step);
    const check_step = b.step("check", "Compile the app and tests without running them");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&tests.step);
    check_step.dependOn(&native_tests.step);

    // Standard run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run velocitty");
    run_step.dependOn(&run_cmd.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = b.option(std.builtin.OptimizeMode, "bench-optimize", "Bench optimize mode (default ReleaseFast)") orelse .ReleaseFast,
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
    bench_run.addPassthruArgs();
    const bench_step = b.step("bench", "Run PTY pipeline, glyph cache and render benchmarks (ReleaseFast)");
    bench_step.dependOn(&bench_run.step);
    const bench_install = b.step("bench-install", "Install velocitty-bench to zig-out/bin (for +terminal-stream and scripts)");
    bench_install.dependOn(&b.addInstallArtifact(bench_exe, .{}).step);

    // Each OS uses its native SDK; Linux hosts can also build Windows directly.
    const release_step = b.step("release", "Build ReleaseFast binaries for available target SDKs");
    const package_step = b.step("package", "Build native tar.gz, Windows ZIP/installer, and macOS DMG packages");
    package_step.dependOn(release_step);

    const version = @import("build.zig.zon").version;

    for (targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        if (release_os) |os| if (resolved.result.os.tag != os) continue;
        if (!canLinkReleaseTarget(resolved, macos_sdk)) continue;
        // Keep ABI version requirements in the binary, not in artifact names.
        var package_query = query;
        package_query.glibc_version = null;
        const triple = package_query.zigTriple(b.allocator) catch @panic("OOM");

        const exe_rel = buildExeForTarget(b, resolved, .ReleaseFast, macos_sdk);

        const install = b.addInstallArtifact(exe_rel, .{
            .dest_dir = .{ .override = .{ .custom = triple } },
        });

        release_step.dependOn(&install.step);

        const pkg_cmd = b.addSystemCommand(&.{if (@import("builtin").os.tag == .windows) "python" else "python3"});
        pkg_cmd.addFileArg(b.path("scripts/package.py"));
        pkg_cmd.addArg(version);
        pkg_cmd.addArg(triple);
        pkg_cmd.addArtifactArg(exe_rel);

        // Relative to the build root (cwd below).
        pkg_cmd.addArg("packages");
        if (resolved.result.os.tag == .windows and @import("builtin").os.tag != .windows) pkg_cmd.addArg("--portable-only");
        pkg_cmd.setCwd(b.path("."));
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
    const usr_exe = buildExeForTarget(b, host_target, .ReleaseFast, macos_sdk);
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

fn canLinkReleaseTarget(target: std.Build.ResolvedTarget, macos_sdk: ?[]const u8) bool {
    const t = target.result;
    if (t.os.tag == .windows) return true;
    if (t.os.tag == .macos) return @import("builtin").os.tag == .macos or macos_sdk != null;
    if (t.os.tag != .linux or @import("builtin").os.tag != .linux) return false;
    return t.abi == .gnu or t.abi == .musl;
}

fn buildExeForTarget(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    macos_sdk: ?[]const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{ .name = "velocitty", .root_module = appModule(b, target, optimize, "src/main.zig", macos_sdk) });
    // Static musl cannot dlopen Peak's native window libraries. These artifacts
    // target musl distributions (e.g. Alpine) with their real runtime libraries.
    if (target.result.os.tag == .linux and target.result.abi == .musl) exe.linkage = .dynamic;
    if (target.result.os.tag == .windows) {
        exe.subsystem = .windows;
        exe.win32_manifest = b.path("velocitty.manifest");
        exe.root_module.addWin32ResourceFile(.{ .file = b.path("velocitty.rc"), .include_paths = &.{b.path(".")} });
    }
    return exe;
}

fn appModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, root: []const u8, macos_sdk: ?[]const u8) *std.Build.Module {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    addStbTrueType(exe_mod, b);
    exe_mod.addCSourceFile(.{ .file = b.path("src/platform/font.c"), .flags = &.{"-std=c99"} });
    addPeak(exe_mod, b, target);
    addMacSdk(exe_mod, b, target, macos_sdk);
    return exe_mod;
}

fn addMacSdk(mod: *std.Build.Module, b: *std.Build, target: std.Build.ResolvedTarget, macos_sdk: ?[]const u8) void {
    if (target.result.os.tag == .macos) {
        if (macos_sdk) |sdk| {
            mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) });
            mod.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
            mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
        }
    }
}

fn addPeak(mod: *std.Build.Module, b: *std.Build, target: std.Build.ResolvedTarget) void {
    addPeakSource(mod, b, target, "vendor/godstack/Peak/peak.c");
}

fn addPeakSource(mod: *std.Build.Module, b: *std.Build, target: std.Build.ResolvedTarget, source: []const u8) void {
    mod.addIncludePath(b.path("vendor/godstack/Peak"));
    // X11 and Wayland headers. After Zig's libc so host bits/math.h
    // cannot shadow the target headers. Those libraries are dlopened.
    if (target.result.os.tag == .linux) mod.addAfterIncludePath(.{ .cwd_relative = "/usr/include" });
    mod.addCSourceFile(.{
        .file = b.path(source),
        // Gaming mice can also expose /dev/input/js*: never turn their
        // global joystick events into clicks in every terminal window.
        .flags = if (target.result.os.tag == .macos)
            &.{ "-fblocks", "-std=c99", "-Wno-deprecated-declarations", "-DPEAK_NO_GAMEPAD" }
        else
            &.{ "-std=c99", "-Wno-deprecated-declarations", "-DPEAK_NO_GAMEPAD" },
        // Zig places -cflags after the file, so `-x objective-c` would be ignored.
        .language = if (target.result.os.tag == .macos) .objective_c else null,
    });
    // musl folds dl, pthread, and openpty into libc.
    if (target.result.os.tag == .linux and target.result.abi != .musl and target.result.abi != .none) {
        const lib: std.Build.Module.LinkSystemLibraryOptions = .{ .use_pkg_config = .no };
        mod.linkSystemLibrary("dl", lib);
        mod.linkSystemLibrary("pthread", lib);
        mod.linkSystemLibrary("util", lib);
    }
    if (target.result.os.tag == .macos) {
        mod.linkSystemLibrary("objc", .{});
        for ([_][]const u8{ "AppKit", "AudioToolbox", "CoreGraphics", "QuartzCore", "CoreText", "CoreFoundation" }) |framework| {
            mod.linkFramework(framework, .{});
        }
    }
    if (target.result.os.tag == .windows) {
        for ([_][]const u8{ "user32", "gdi32", "shell32", "advapi32" }) |lib| mod.linkSystemLibrary(lib, .{});
    }
}

fn addStbTrueType(mod: *std.Build.Module, b: *std.Build) void {
    mod.addIncludePath(b.path("lib"));
    const flags: []const []const u8 = &.{ "-std=c99", "-fno-sanitize=undefined" };
    mod.addCSourceFile(.{ .file = b.path("src/type/stb_truetype.c"), .flags = flags });
    mod.addCSourceFile(.{ .file = b.path("src/stb_image.c"), .flags = flags });
}
