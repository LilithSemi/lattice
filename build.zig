const std = @import("std");
const wayland_build = @import("wayland");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gpu_drivers = b.option([]const []const u8, "gpu-drivers", "GPU driver to enable; repeat to select multiple drivers. Defaults to Prism's choice.");

    const on_linux = target.result.os.tag == .linux;
    const known_client = [_][]const u8{ "wayland", "x11", "kms", "headless" };
    const known_compositor = [_][]const u8{"wayland"};
    const client_opt = b.option([]const []const u8, "client-backends", "Client backend to compile in; repeat to select multiple backends. Defaults to all that apply to the target.");
    const compositor_opt = b.option([]const []const u8, "compositor-backends", "Compositor backend to compile in; repeat to select multiple backends. Defaults to all that apply to the target.");
    const client_set = parseBackendList(b, client_opt, &known_client, "client-backends");
    const compositor_set = parseBackendList(b, compositor_opt, &known_compositor, "compositor-backends");
    const client_wayland = client_set.contains("wayland") and on_linux;
    const client_x11 = client_set.contains("x11") and on_linux;
    const client_kms = client_set.contains("kms") and on_linux;
    const client_headless = client_set.contains("headless");
    const compositor_wayland = compositor_set.contains("wayland");
    const prism_display_backends = prismDisplayBackends(b, client_wayland, client_x11, client_kms, client_headless);

    if (!(client_wayland or client_x11 or client_kms or client_headless)) {
        std.debug.panic("no client backend applies to {s}: a build with none cannot construct a Context", .{@tagName(target.result.os.tag)});
    }

    const backend_options = b.addOptions();
    backend_options.addOption(bool, "client_wayland", client_wayland);
    backend_options.addOption(bool, "client_x11", client_x11);
    backend_options.addOption(bool, "client_kms", client_kms);
    backend_options.addOption(bool, "client_headless", client_headless);
    backend_options.addOption(bool, "compositor_wayland", compositor_wayland);

    const root_module = b.addModule("lattice", .{
        .root_source_file = b.path("lib/lattice.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build-options", .module = backend_options.createModule() },
        },
    });

    const needs_wayland = client_wayland or compositor_wayland;
    const wayland_dep: ?*std.Build.Dependency = if (needs_wayland)
        b.dependency("wayland", .{ .target = target, .optimize = optimize })
    else
        null;

    const prism_dep = b.dependency("prism", .{
        .target = target,
        .optimize = optimize,
        .drivers = gpu_drivers,
        .@"display-backends" = prism_display_backends,
    });

    const xkbcommon_dep = b.dependency("xkbcommon", .{
        .target = target,
        .optimize = optimize,
    });
    const x11_modules: ?X11Modules = if (client_x11)
        makeXkbcommonModule(b, xkbcommon_dep, target, optimize)
    else
        null;
    const xkbcommon_module = if (x11_modules) |modules| modules.xkbcommon else xkbcommon_dep.module("xkbcommon");

    const drm_dep = b.dependency("drm", .{
        .target = target,
        .optimize = optimize,
    });

    const libseat_dep = b.dependency("libseat", .{
        .target = target,
        .optimize = optimize,
    });

    const udev_dep = b.dependency("udev", .{
        .target = target,
        .optimize = optimize,
    });

    const libinput_dep = b.dependency("libinput", .{
        .target = target,
        .optimize = optimize,
    });

    const wayland_modules: ?WaylandModules = if (needs_wayland)
        generateWaylandProtocols(b, wayland_dep.?)
    else
        null;
    if (wayland_modules) |wl| {
        root_module.addImport("wayland", wl.wayland);
        root_module.addImport("wayland_protocol", wl.wayland_protocol);
        root_module.addImport("xdg_shell", wl.xdg_shell);
        root_module.addImport("linux_dmabuf", wl.linux_dmabuf);
        root_module.addImport("color_management", wl.color_management);
        root_module.addImport("relative_pointer", wl.relative_pointer);
        root_module.addImport("pointer_constraints", wl.pointer_constraints);
        root_module.addImport("tablet_v2", wl.tablet_v2);
        root_module.addImport("xdg_decoration", wl.xdg_decoration);
        root_module.addImport("viewporter", wl.viewporter);
        root_module.addImport("fractional_scale", wl.fractional_scale);
    }
    root_module.addImport("prism", prism_dep.module("prism"));
    root_module.addImport("xkbcommon", xkbcommon_module);
    if (x11_modules) |modules| {
        root_module.addImport("x11", modules.x11);
        root_module.addImport("xproto", modules.x11_xproto);
    }
    root_module.addImport("drm", drm_dep.module("drm"));
    root_module.addImport("libseat", libseat_dep.module("libseat"));
    root_module.addImport("udev", udev_dep.module("udev"));
    root_module.addImport("libinput", libinput_dep.module("libinput"));
    if (target.result.abi.isAndroid()) root_module.linkSystemLibrary("android", .{});

    const example = b.addExecutable(.{
        .name = "lattice-window",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/window.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example.root_module.addImport("lattice", root_module);
    b.installArtifact(example);
    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example-window", "Run the window example");
    example_step.dependOn(&run_example.step);

    if (target.result.os.tag == .linux) {
        if (compositor_wayland) {
            const smoke = b.addExecutable(.{
                .name = "compositor-smoke",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("example/compositor_smoke.zig"),
                    .target = target,
                    .optimize = optimize,
                }),
            });
            smoke.root_module.addImport("lattice", root_module);
            smoke.root_module.addImport("prism", prism_dep.module("prism"));
            b.installArtifact(smoke);

            const run_smoke = b.addRunArtifact(smoke);
            const smoke_step = b.step("example-compositor-smoke", "Run the compositor smoke test");
            smoke_step.dependOn(&run_smoke.step);

            const nested = b.addExecutable(.{
                .name = "lattice-nested",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("example/nested.zig"),
                    .target = target,
                    .optimize = optimize,
                }),
            });
            nested.root_module.addImport("lattice", root_module);
            b.installArtifact(nested);

            const run_nested = b.addRunArtifact(nested);
            // Ensure lattice-window is built and installed before we run nested.
            run_nested.step.dependOn(&b.addInstallArtifact(example, .{}).step);
            const nested_step = b.step("example-nested", "Run the nested compositor self-host example");
            nested_step.dependOn(&run_nested.step);
        }

        const kms_demo = b.addExecutable(.{
            .name = "lattice-kms-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("example/kms_demo.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        kms_demo.root_module.addImport("lattice", root_module);
        b.installArtifact(kms_demo);

        const run_kms = b.addRunArtifact(kms_demo);
        const kms_step = b.step("example-kms", "Run the KMS scanout demo (needs root + a free VT)");
        kms_step.dependOn(&run_kms.step);

        if (compositor_wayland) {
            const wl = wayland_modules.?;
            const constraints_e2e = b.addExecutable(.{
                .name = "constraints-e2e",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("example/constraints_e2e.zig"),
                    .target = target,
                    .optimize = optimize,
                }),
            });
            constraints_e2e.root_module.addImport("lattice", root_module);
            constraints_e2e.root_module.addImport("prism", prism_dep.module("prism"));
            constraints_e2e.root_module.addImport("wayland", wl.wayland);
            constraints_e2e.root_module.addImport("wayland_protocol", wl.wayland_protocol);
            constraints_e2e.root_module.addImport("xdg_shell", wl.xdg_shell);
            constraints_e2e.root_module.addImport("relative_pointer", wl.relative_pointer);
            constraints_e2e.root_module.addImport("pointer_constraints", wl.pointer_constraints);

            b.installArtifact(constraints_e2e);
            const run_e2e = b.addRunArtifact(constraints_e2e);
            const e2e_step = b.step("example-constraints-e2e", "Run the pointer-constraints e2e test");
            e2e_step.dependOn(&run_e2e.step);
        }
    }

    const tests = b.addTest(.{ .root_module = root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn prismDisplayBackends(
    b: *std.Build,
    wayland: bool,
    x11: bool,
    kms: bool,
    headless: bool,
) []const []const u8 {
    var selected: std.ArrayList([]const u8) = .empty;
    if (wayland) selected.append(b.allocator, "wayland") catch @panic("OOM");
    if (x11) selected.append(b.allocator, "x11") catch @panic("OOM");
    if (kms) {
        selected.append(b.allocator, "drm") catch @panic("OOM");
        selected.append(b.allocator, "gbm") catch @panic("OOM");
    }
    if (headless or selected.items.len == 0) selected.append(b.allocator, "headless") catch @panic("OOM");
    return selected.items;
}

const WaylandModules = struct {
    wayland: *std.Build.Module,
    wayland_protocol: *std.Build.Module,
    xdg_shell: *std.Build.Module,
    linux_dmabuf: *std.Build.Module,
    color_management: *std.Build.Module,
    relative_pointer: *std.Build.Module,
    pointer_constraints: *std.Build.Module,
    tablet_v2: *std.Build.Module,
    xdg_decoration: *std.Build.Module,
    viewporter: *std.Build.Module,
    fractional_scale: *std.Build.Module,
};

fn generateWaylandProtocols(b: *std.Build, wayland: *std.Build.Dependency) WaylandModules {
    const protocols = b.dependency("wayland_protocols", .{});
    const wayland_xml = b.dependency("wayland_xml", .{});
    return .{
        .wayland = wayland.module("wayland"),
        .wayland_protocol = wayland_build.generateProtocol(b, wayland, wayland_xml.path("protocol/wayland.xml"), "wayland_protocol"),
        .xdg_shell = wayland_build.generateProtocol(b, wayland, protocols.path("stable/xdg-shell/xdg-shell.xml"), "xdg_shell"),
        .linux_dmabuf = wayland_build.generateProtocol(b, wayland, protocols.path("stable/linux-dmabuf/linux-dmabuf-v1.xml"), "linux_dmabuf"),
        .color_management = wayland_build.generateProtocol(b, wayland, wayland.path("protocol/color-management-v1.xml"), "color_management"),
        .relative_pointer = wayland_build.generateProtocol(b, wayland, protocols.path("unstable/relative-pointer/relative-pointer-unstable-v1.xml"), "relative_pointer"),
        .pointer_constraints = wayland_build.generateProtocol(b, wayland, protocols.path("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml"), "pointer_constraints"),
        .tablet_v2 = wayland_build.generateProtocol(b, wayland, protocols.path("unstable/tablet/tablet-unstable-v2.xml"), "tablet_v2"),
        .xdg_decoration = wayland_build.generateProtocol(b, wayland, protocols.path("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"), "xdg_decoration"),
        .viewporter = wayland_build.generateProtocol(b, wayland, protocols.path("stable/viewporter/viewporter.xml"), "viewporter"),
        .fractional_scale = wayland_build.generateProtocol(b, wayland, protocols.path("staging/fractional-scale/fractional-scale-v1.xml"), "fractional_scale"),
    };
}

/// Compose xkbcommon here so its generated core-protocol file has a distinct
/// cache name from Prism's X11 binding. Both dependencies emit `xproto.zig`
/// from the same XML, which Zig rejects when owned by separate modules.
const X11Modules = struct {
    xkbcommon: *std.Build.Module,
    x11: *std.Build.Module,
    xkb_xproto: *std.Build.Module,
    x11_xproto: *std.Build.Module,
};

fn makeXkbcommonModule(
    b: *std.Build,
    dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) X11Modules {
    const module = b.createModule(.{
        .root_source_file = dep.path("src/xkbcommon.zig"),
        .target = target,
        .optimize = optimize,
    });

    const xml_dep = dep.builder.dependency("xml", .{ .target = target, .optimize = optimize });
    module.addImport("xml", xml_dep.module("xml"));

    const x11_dep = dep.builder.dependency("x11", .{ .target = target, .optimize = optimize });
    const x11_module = x11_dep.module("x11");
    module.addImport("x11", x11_module);
    const xcbproto = x11_dep.builder.dependency("xcbproto", .{});
    const xproto_xml = xcbproto.path("src/xproto.xml");

    const xkb_xproto_gen = b.addRunArtifact(x11_dep.artifact("x11-gen-host"));
    xkb_xproto_gen.addFileArg(xproto_xml);
    const xkb_xproto = b.createModule(.{
        .root_source_file = xkb_xproto_gen.addOutputFileArg("lattice_xkb_xproto.zig"),
        .target = target,
        .optimize = optimize,
    });
    xkb_xproto.addImport("x11", x11_module);

    const xkb_gen = b.addRunArtifact(x11_dep.artifact("x11-gen-host"));
    xkb_gen.addFileArg(xcbproto.path("src/xkb.xml"));
    const xkb = b.createModule(.{
        .root_source_file = xkb_gen.addOutputFileArg("lattice_xkb.zig"),
        .target = target,
        .optimize = optimize,
    });
    xkb_gen.addFileArg(xproto_xml);
    xkb.addImport("x11", x11_module);
    xkb.addImport("xproto", xkb_xproto);
    module.addImport("xproto", xkb_xproto);
    module.addImport("xkbproto", xkb);

    const xproto_gen = b.addRunArtifact(x11_dep.artifact("x11-gen-host"));
    xproto_gen.addFileArg(xproto_xml);
    const x11_xproto = b.createModule(.{
        .root_source_file = xproto_gen.addOutputFileArg("lattice_x11_xproto.zig"),
        .target = target,
        .optimize = optimize,
    });
    x11_xproto.addImport("x11", x11_module);

    const keysyms_root = b.createModule(.{
        .root_source_file = dep.path("generator/keysyms.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const keysyms_exe = b.addExecutable(.{ .name = "lattice-keysyms-gen", .root_module = keysyms_root });
    const keysyms_run = b.addRunArtifact(keysyms_exe);
    const xorgproto = dep.builder.dependency("xorgproto", .{});
    keysyms_run.addFileArg(xorgproto.path("include/X11/keysymdef.h"));
    keysyms_run.addFileArg(xorgproto.path("include/X11/XF86keysym.h"));
    module.addImport("keysym_tables", b.createModule(.{
        .root_source_file = keysyms_run.addOutputFileArg("lattice_keysym_tables.zig"),
    }));
    return .{ .xkbcommon = module, .x11 = x11_module, .xkb_xproto = xkb_xproto, .x11_xproto = x11_xproto };
}

fn parseBackendList(
    b: *std.Build,
    opt: ?[]const []const u8,
    known: []const []const u8,
    flag: []const u8,
) std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(b.allocator);
    const list = opt orelse {
        for (known) |name| set.put(name, {}) catch @panic("OOM");
        return set;
    };
    for (list) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) continue;
        var known_name = false;
        for (known) |candidate| {
            if (std.mem.eql(u8, candidate, name)) known_name = true;
        }
        if (!known_name) std.debug.panic("unknown {s} value: {s}", .{ flag, name });
        set.put(name, {}) catch @panic("OOM");
    }
    return set;
}
