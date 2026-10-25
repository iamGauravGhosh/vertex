const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gui = b.option(bool, "gui", "Build the Linux Wayland terminal") orelse (target.result.os.tag == .linux);
    if (gui and target.result.os.tag != .linux) @panic("The GUI currently requires Linux; use -Dgui=false");

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
    const options = b.addOptions();
    options.addOption(bool, "gui", gui);
    exe.root_module.addOptions("build_options", options);
    var linux_tests: ?*std.Build.Step.Run = null;
    if (gui) {
        const protocols = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }), " \r\n\t");
        const xml: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ protocols, "stable/xdg-shell/xdg-shell.xml" }) };
        const header_cmd = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        header_cmd.addFileArg(xml);
        const header = header_cmd.addOutputFileArg("xdg-shell-client-protocol.h");
        const code_cmd = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        code_cmd.addFileArg(xml);
        const code = code_cmd.addOutputFileArg("xdg-shell-protocol.c");
        const bindings = b.addTranslateC(.{
            .root_source_file = b.path("src/platform/c.h"),
            .target = target,
            .optimize = optimize,
        });
        bindings.addIncludePath(header.dirname());
        bindings.linkSystemLibrary("freetype2", .{});
        bindings.linkSystemLibrary("fontconfig", .{});
        bindings.linkSystemLibrary("wayland-client", .{});
        bindings.linkSystemLibrary("xkbcommon", .{});
        bindings.linkSystemLibrary("harfbuzz", .{});
        bindings.linkSystemLibrary("egl", .{});
        bindings.linkSystemLibrary("glesv2", .{});
        bindings.linkSystemLibrary("wayland-egl", .{});
        const c_module = bindings.createModule();
        configureLinux(exe.root_module, c_module, code);
        const integration = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/linux_tests.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        configureLinux(integration.root_module, c_module, code);
        linux_tests = b.addRunArtifact(integration);
    }

    b.installArtifact(exe);
    b.installFile("LICENSE", "share/licenses/vertex/LICENSE");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    b.step("run", "Run Vertex").dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
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
    const test_step = b.step("test", "Run parser, screen, CLI, and module-consumer tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_consumer_tests.step);
    if (linux_tests) |run_linux_tests| test_step.dependOn(&run_linux_tests.step);
}

fn configureLinux(module: *std.Build.Module, bindings: *std.Build.Module, protocol: std.Build.LazyPath) void {
    module.addImport("c", bindings);
    module.link_libc = true;
    for ([_][]const u8{ "wayland-client", "xkbcommon", "freetype2", "fontconfig", "harfbuzz", "EGL", "GLESv2", "wayland-egl", "util" }) |library| {
        module.linkSystemLibrary(library, .{});
    }
    module.addCSourceFile(.{ .file = protocol });
}
