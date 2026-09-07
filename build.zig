const std = @import("std");

const BuildContext = struct {
    b:       *std.Build,
    target:   std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(b: *std.Build) void {
    const ctx: BuildContext = .{
        .b        = b,
        .target   = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    };

    const xcb = buildXcb(ctx);
    buildExe(ctx, &.{
        .{ .name = "xcb", .module = xcb },
    });
}

fn buildXcb(ctx: BuildContext) *std.Build.Module {
    const b = ctx.b;

    const xcb = b.addTranslateC(.{
        .root_source_file = b.path("src/xcb.h"),
        .target           = ctx.target,
        .optimize         = ctx.optimize,
    });
    xcb.linkSystemLibrary("xcb", .{});
    xcb.linkSystemLibrary("xcb-shape", .{});

    return xcb.createModule();
}

fn buildExe(ctx: BuildContext, imports: []const std.Build.Module.Import) void {
    const b = ctx.b;

    const exe = b.addExecutable(.{
        .name = "lmdsotsblkiaisdamiwlaoosk",
        .root_module = ctx.b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target           = ctx.target,
            .optimize         = ctx.optimize,
            .imports          = imports,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the thing");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
