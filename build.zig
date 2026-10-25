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
        var extra_headers: [5]std.Build.LazyPath = undefined;
        var extra_codes: [5]std.Build.LazyPath = undefined;
        for ([_][]const u8{ "primary-selection", "text-input", "xdg-decoration", "cursor-shape", "tablet" }, [_][]const u8{ "unstable/primary-selection/primary-selection-unstable-v1.xml", "unstable/text-input/text-input-unstable-v3.xml", "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml", "staging/cursor-shape/cursor-shape-v1.xml", "unstable/tablet/tablet-unstable-v2.xml" }, 0..) |name, path, i| {
            const protocol_xml: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ protocols, path }) };
            const header_generator = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
            header_generator.addFileArg(protocol_xml);
            extra_headers[i] = header_generator.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{name}));
            const code_generator = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
            code_generator.addFileArg(protocol_xml);
            extra_codes[i] = code_generator.addOutputFileArg(b.fmt("{s}-protocol.c", .{name}));
        }
        const bindings = b.addTranslateC(.{
            .root_source_file = b.path("src/platform/c.h"),
            .target = target,
            .optimize = optimize,
        });
        bindings.addIncludePath(header.dirname());
        bindings.addIncludePath(b.path("vendor/tomlc17"));
        for (extra_headers) |extra| bindings.addIncludePath(extra.dirname());
        bindings.linkSystemLibrary("freetype2", .{});
        bindings.linkSystemLibrary("fontconfig", .{});
        bindings.linkSystemLibrary("wayland-client", .{});
        bindings.linkSystemLibrary("xkbcommon", .{});
        bindings.linkSystemLibrary("harfbuzz", .{});
        bindings.linkSystemLibrary("fribidi", .{});
        bindings.linkSystemLibrary("egl", .{});
        bindings.linkSystemLibrary("glesv2", .{});
        bindings.linkSystemLibrary("wayland-egl", .{});
        const c_module = bindings.createModule();
        // Separate integration step: these binaries are never Vertex runtime dependencies.
        const mux_host = b.addExecutable(.{ .name = "vertex-multiplexer-host", .root_module = b.createModule(.{
            .root_source_file = b.path("src/multiplexer_host.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        mux_host.root_module.addImport("c", c_module);
        mux_host.root_module.link_libc = true;
        const mux_local = b.addSystemCommand(&.{ "python3", "tests/multiplexer_smoke.py" });
        mux_local.addArtifactArg(mux_host);
        mux_local.addArg("--require-multiplexers");
        const mux_ssh = b.addSystemCommand(&.{ "python3", "tests/ssh_multiplexer_smoke.py" });
        mux_ssh.addArtifactArg(mux_host);
        mux_ssh.addArg("--require-multiplexers");
        const mux_step = b.step("test-multiplexers", "Check standalone, tmux, Zellij and Herdr locally and over isolated SSH");
        mux_step.dependOn(&mux_local.step);
        mux_step.dependOn(&mux_ssh.step);
        configureLinux(exe.root_module, c_module, code);
        for (extra_codes) |extra| exe.root_module.addCSourceFile(.{ .file = extra });
        const integration = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/linux_tests.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        configureLinux(integration.root_module, c_module, code);
        for (extra_codes) |extra| integration.root_module.addCSourceFile(.{ .file = extra });
        linux_tests = b.addRunArtifact(integration);
    }

    b.installArtifact(exe);
    b.installFile("LICENSE", "share/licenses/vertex/LICENSE");
    if (gui) {
        b.installFile("vendor/stb/LICENSE", "share/licenses/vertex/stb_image-LICENSE");
        b.installFile("vendor/tomlc17/LICENSE", "share/licenses/vertex/tomlc17-LICENSE");
        b.installFile("src/config_defaults.toml", "share/vertex/config.example.toml");
        b.installDirectory(.{ .source_dir = b.path("assets"), .install_dir = .prefix, .install_subdir = "share/vertex/assets" });
        b.installDirectory(.{ .source_dir = b.path("docs"), .install_dir = .prefix, .install_subdir = "share/vertex/docs" });
    }

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
    for ([_][]const u8{ "wayland-client", "xkbcommon", "freetype2", "fontconfig", "harfbuzz", "fribidi", "EGL", "GLESv2", "wayland-egl", "util" }) |library| {
        module.linkSystemLibrary(library, .{});
    }
    module.addCSourceFile(.{ .file = protocol });
    module.addIncludePath(.{ .cwd_relative = "vendor/tomlc17" });
    module.addCSourceFile(.{ .file = .{ .cwd_relative = "vendor/tomlc17/tomlc17.c" }, .flags = &.{"-std=c17"} });
    module.addCSourceFile(.{ .file = .{ .cwd_relative = "src/platform/image_decode.c" }, .flags = &.{"-std=c11"} });
}
