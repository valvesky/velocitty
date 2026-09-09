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

    const xev = b.addModule("xev", .{
        .root_source_file = b.path("lib/libxev/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkWindowsSockets(xev, target);

    const mod = b.addModule("ZT", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "xev", .module = xev },
        },
    });
    addStbTrueType(mod, b);

    const lib = b.addLibrary(.{
        .name = "ZT",
        .root_module = mod,
    });

    const exe = addExe(b, mod, xev, target, optimize);
    b.installArtifact(exe);
    installSdlRuntime(b, target, .bin, b.getInstallStep());
    installUserBin(b, exe, target);

    const release_step = b.step("release", "Build optimized zt for each platform");
    for (targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const triple = query.zigTriple(b.allocator) catch @panic("OOM");
        const xev_t = b.createModule(.{
            .root_source_file = b.path("lib/libxev/src/main.zig"),
            .target = resolved,
            .optimize = .ReleaseFast,
        });
        linkWindowsSockets(xev_t, resolved);
        const zt_t = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = resolved,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{
                .{ .name = "xev", .module = xev_t },
            },
        });
        addStbTrueType(zt_t, b);
        const exe_t = addExe(b, zt_t, xev_t, resolved, .ReleaseFast);
        const install = b.addInstallArtifact(exe_t, .{
            .dest_dir = .{ .override = .{ .custom = triple } },
        });
        release_step.dependOn(&install.step);
        installSdlRuntime(b, resolved, .{ .custom = triple }, release_step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zt");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ZT", .module = mod },
        },
    });
    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    const run_integration = b.addRunArtifact(integration_tests);
    run_integration.setCwd(b.path("."));
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_integration.step);

    const fuzz_exe = b.addExecutable(.{
        .name = "zt-fuzz-render",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz_render.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ZT", .module = mod },
            },
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| run_fuzz.addArgs(args);
    const fuzz_step = b.step("fuzz-render", "Random VT dirty-vs-full pixel check");
    fuzz_step.dependOn(&run_fuzz.step);

    const bench_exe = b.addExecutable(.{
        .name = "zt-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/pipeline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ZT", .module = mod },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Benchmark pipeline stages");
    bench_step.dependOn(&run_bench.step);

    const docs_step = b.step("docs", "Install API docs");
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);
}

fn addStbTrueType(mod: *std.Build.Module, b: *std.Build) void {
    mod.addIncludePath(b.path("lib"));
    const flags: []const []const u8 = &.{ "-std=c99", "-fno-sanitize=undefined" };
    mod.addCSourceFile(.{ .file = b.path("src/type/stb_truetype.c"), .flags = flags });
    mod.addCSourceFile(.{ .file = b.path("src/stb_image.c"), .flags = flags });
}

fn addExe(
    b: *std.Build,
    zt: *std.Build.Module,
    xev: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "zt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ZT", .module = zt },
                .{ .name = "xev", .module = xev },
            },
            .link_libc = true,
        }),
    });
}

fn installSdlRuntime(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    dir: std.Build.InstallDir,
    step: *std.Build.Step,
) void {
    switch (target.result.os.tag) {
        .windows => if (target.result.cpu.arch == .x86_64) {
            const dep = b.lazyDependency("sdl3_win32_x64", .{}) orelse return;
            const install = b.addInstallFileWithDir(dep.path("SDL3.dll"), dir, "SDL3.dll");
            step.dependOn(&install.step);
        },
        else => {},
    }
}

fn linkWindowsSockets(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .windows) return;
    mod.linkSystemLibrary("ws2_32", .{});
    mod.linkSystemLibrary("mswsock", .{});
}

fn installUserBin(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    const host = b.graph.host.result;
    if (target.result.os.tag != host.os.tag or target.result.cpu.arch != host.cpu.arch) return;
    const dest_dir = userBinDir(b) orelse return;
    const step = b.step("install-user", b.fmt("Copy zt to {s}", .{dest_dir}));
    addCopyToDir(b, step, exe.getEmittedBin(), dest_dir, exe.out_filename);
    if (host.os.tag == .windows) {
        const dep = b.lazyDependency("sdl3_win32_x64", .{}) orelse return;
        addCopyToDir(b, step, dep.path("SDL3.dll"), dest_dir, "SDL3.dll");
    }
}

fn userBinDir(b: *std.Build) ?[]const u8 {
    if (b.graph.environ_map.get("XDG_BIN_HOME")) |p| {
        if (p.len != 0) return p;
    }
    const home = b.graph.environ_map.get("HOME") orelse b.graph.environ_map.get("USERPROFILE") orelse return null;
    return b.pathJoin(&.{ home, ".local", "bin" });
}

const CopyToDir = struct {
    step: std.Build.Step,
    source: std.Build.LazyPath,
    dest_dir: []const u8,
    dest_name: []const u8,

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *CopyToDir = @fieldParentPtr("step", step);
        _ = try step.installDir(self.dest_dir);
        const dest = step.owner.pathJoin(&.{ self.dest_dir, self.dest_name });
        _ = try step.installFile(self.source, dest);
    }
};

fn addCopyToDir(
    b: *std.Build,
    parent: *std.Build.Step,
    source: std.Build.LazyPath,
    dest_dir: []const u8,
    dest_name: []const u8,
) void {
    const copy = b.allocator.create(CopyToDir) catch @panic("OOM");
    copy.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = b.fmt("copy {s} to {s}", .{ dest_name, dest_dir }),
            .owner = b,
            .makeFn = CopyToDir.make,
        }),
        .source = source,
        .dest_dir = dest_dir,
        .dest_name = dest_name,
    };
    source.addStepDependencies(&copy.step);
    parent.dependOn(&copy.step);
}
