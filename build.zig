const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Documentation
    const docs = b.addObject(.{
        .name = "zigsharedstring",
        .root_module = b.addModule("zigsharedstring", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const docsget = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    b.default_step.dependOn(&docsget.step);

    // Tests
    const main_tests = b.addTest(.{
        .root_module = b.addModule("zigsharedstring-tests", .{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    // Example binary
    const example = b.addExecutable(.{
        .name = "example",
        .root_module = b.addModule("example", .{
            .root_source_file = b.path("src/example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "Build and run the example");
    example_step.dependOn(&run_example.step);

    b.installArtifact(example);
}
