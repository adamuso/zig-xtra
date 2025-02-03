const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("zig-xtra", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zig-xtra",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const example_unit_tests = b.addTest(.{
        .name = "example-test",
        .root_module = example_mod,
    });

    example_unit_tests.root_module.addImport("zig-xtra", lib_mod);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const run_example_unit_tests = b.addRunArtifact(example_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_example_unit_tests.step);
}
