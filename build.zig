const std = @import("std");
// Capy's build.zig exposes `runStep`, which sets the right Windows subsystem
// (Console in Debug, GUI otherwise) and creates the run command.
const capy_build = @import("capy");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const capy_dep = b.dependency("capy", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("capy", capy_dep.module("capy"));

    // Headers: dr_libs + miniaudio live in vendor/, our own C glue in src/c/.
    exe_mod.addIncludePath(b.path("vendor"));
    exe_mod.addIncludePath(b.path("src/c"));

    // dr_libs (decoding) and miniaudio (output) implementations.
    // The third-party single-header libraries trip UBSan in Debug builds, so it is disabled for them.
    exe_mod.addCSourceFile(.{
        .file = b.path("src/c/audio_impl.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });

    switch (target.result.os.tag) {
        .windows => {
            exe_mod.linkSystemLibrary("comdlg32", .{}); // open-file dialog
            exe_mod.linkSystemLibrary("ole32", .{}); // WASAPI (used by miniaudio)
            exe_mod.linkSystemLibrary("user32", .{});
            exe_mod.linkSystemLibrary("advapi32", .{});
        },
        else => {},
    }

    const exe = b.addExecutable(.{
        .name = "lmp3",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the player (extra args = audio files to add)");
    run_step.dependOn(try capy_build.runStep(exe, .{ .args = b.args }));
}
