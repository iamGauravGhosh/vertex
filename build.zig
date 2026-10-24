const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const terminal_module = b.addModule("vertex_terminal", .{
        .root_source_file = b.path("src/terminal/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "vertex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);
    b.installFile("LICENSE", "share/licenses/vertex/LICENSE");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    b.step("run", "Run Vertex").dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(unit_tests);
    const consumer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/consumer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vertex_terminal", .module = terminal_module }},
        }),
    });
    const run_consumer_tests = b.addRunArtifact(consumer_tests);
    const test_step = b.step("test", "Run parser, CLI, and module-consumer tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_consumer_tests.step);
}
