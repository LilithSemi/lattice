const std = @import("std");
const enabled = @import("backends_enabled.zig");

pub const BackendKind = enum { auto, wayland, kms, headless };

/// Neutral pointer acceleration profile. Maps to libinput filter.Profile
/// inside the KMS backend; safe to use on all platforms.
pub const AccelProfile = enum { flat, adaptive };

/// Neutral scroll method. Maps to libinput pointer.ScrollMethod inside the
/// KMS backend; safe to use on all platforms.
pub const ScrollMethod = enum { none, on_button_down };

/// Per-device input configuration applied at device-open time in the KMS
/// backend. Defaults match libinput's built-in defaults: adaptive accel,
/// speed 0, all behavioural bools false, scroll disabled.
/// The nested (Wayland) backend ignores this - the parent compositor owns it.
pub const InputConfig = struct {
    accel_speed: f64 = 0.0,
    accel_profile: AccelProfile = .adaptive,
    natural_scroll: bool = false,
    left_handed: bool = false,
    middle_emulation: bool = false,
    scroll_method: ScrollMethod = .none,
};

pub const Options = struct {
    backend: BackendKind = .auto,
    initial_width: u32 = 800,
    initial_height: u32 = 600,
    driver: ?[]const u8 = null,
    /// When false, the KMS backend runs in kiosk mode: never initiates a VT
    /// switch and best-effort locks switching. Default true = normal switching.
    vt_switch: bool = true,
    /// Per-device input configuration applied to each libinput device as it is
    /// opened (initial enumeration + hotplug). KMS backend only; ignored by
    /// nested (Wayland) and headless backends.
    input: InputConfig = .{},
};

pub const EnvProbe = struct {
    wayland_display: ?[]const u8 = null,
    x11_display: ?[]const u8 = null,
    xdg_session_type: ?[]const u8 = null,
    kms_device: ?[]const u8 = null,
};

fn eq(a: ?[]const u8, b: []const u8) bool {
    return a != null and std.mem.eql(u8, a.?, b);
}

/// Resolve the concrete backend. Session type wins over device presence.
pub fn resolveBackend(opts: Options, probe: EnvProbe) !BackendKind {
    return switch (opts.backend) {
        .wayland => if (enabled.client_wayland) .wayland else error.InvalidBackend,
        .kms => if (enabled.client_kms) .kms else error.InvalidBackend,
        .headless => if (enabled.client_headless) .headless else error.InvalidBackend,
        .auto => detectAuto(probe),
    };
}

/// Pure backend auto-detection from environment indicators. OS-agnostic: it only
/// reads the probe (which env vars are filled + whether a DRM device exists is
/// the caller's job in context.zig). A wayland/x11 SESSION means another display
/// server owns the GPU, so we never grab KMS just because a card node exists.
fn detectAuto(probe: EnvProbe) !BackendKind {
    if (enabled.client_wayland and (probe.wayland_display != null or eq(probe.xdg_session_type, "wayland"))) return .wayland;
    if (enabled.client_headless and (probe.x11_display != null or eq(probe.xdg_session_type, "x11"))) return .headless;
    if (enabled.client_kms and eq(probe.xdg_session_type, "tty")) return .kms;
    if (enabled.client_kms and probe.xdg_session_type == null and probe.wayland_display == null and probe.x11_display == null and probe.kms_device != null) return .kms;
    if (enabled.client_headless) return .headless;
    return error.InvalidBackend;
}

test "resolveBackend picks wayland when WAYLAND_DISPLAY set" {
    if (!enabled.client_kms or !enabled.client_wayland or !enabled.client_headless) return error.SkipZigTest;
    try std.testing.expectEqual(BackendKind.wayland, try resolveBackend(.{}, .{ .wayland_display = "wayland-0" }));
    try std.testing.expectEqual(BackendKind.headless, try resolveBackend(.{}, .{ .wayland_display = null }));
    try std.testing.expectEqual(BackendKind.wayland, try resolveBackend(.{ .backend = .wayland }, .{ .wayland_display = null }));
}

test "resolveBackend: explicit kms" {
    if (!enabled.client_kms or !enabled.client_wayland or !enabled.client_headless) return error.SkipZigTest;
    try std.testing.expectEqual(BackendKind.kms, try resolveBackend(.{ .backend = .kms }, .{ .kms_device = null }));
}
test "resolveBackend: auto picks kms when a DRM device is present and no wayland" {
    if (!enabled.client_kms or !enabled.client_wayland or !enabled.client_headless) return error.SkipZigTest;
    try std.testing.expectEqual(BackendKind.kms, try resolveBackend(.{}, .{ .kms_device = "/dev/dri/card0" }));
}
test "resolveBackend: wayland wins over kms in auto" {
    if (!enabled.client_kms or !enabled.client_wayland or !enabled.client_headless) return error.SkipZigTest;
    try std.testing.expectEqual(BackendKind.wayland, try resolveBackend(.{}, .{ .wayland_display = "wayland-1", .kms_device = "/dev/dri/card0" }));
}

test "resolveBackend: wayland session (even if a DRM card exists) -> wayland, NOT kms" {
    if (!enabled.client_kms or !enabled.client_wayland or !enabled.client_headless) return error.SkipZigTest;
    try std.testing.expectEqual(BackendKind.wayland, try resolveBackend(.{}, .{ .wayland_display = "wayland-1", .xdg_session_type = "wayland", .kms_device = "/dev/dri/card0" }));
    try std.testing.expectEqual(BackendKind.wayland, try resolveBackend(.{}, .{ .xdg_session_type = "wayland", .kms_device = "/dev/dri/card0" }));
}
test "resolveBackend: tty session -> kms" {
    if (!enabled.client_kms or !enabled.client_wayland or !enabled.client_headless) return error.SkipZigTest;
    try std.testing.expectEqual(BackendKind.kms, try resolveBackend(.{}, .{ .xdg_session_type = "tty", .kms_device = "/dev/dri/card0" }));
}
test "resolveBackend: unset session type, no gfx indicators, drm present -> kms (best-effort)" {
    if (!enabled.client_kms or !enabled.client_wayland or !enabled.client_headless) return error.SkipZigTest;
    try std.testing.expectEqual(BackendKind.kms, try resolveBackend(.{}, .{ .kms_device = "/dev/dri/card0" }));
}
test "resolveBackend: x11 session -> headless (x11 backend unbuilt)" {
    if (!enabled.client_kms or !enabled.client_wayland or !enabled.client_headless) return error.SkipZigTest;
    try std.testing.expectEqual(BackendKind.headless, try resolveBackend(.{}, .{ .x11_display = ":0", .xdg_session_type = "x11" }));
}
test "resolveBackend: nothing -> headless" {
    if (!enabled.client_kms or !enabled.client_wayland or !enabled.client_headless) return error.SkipZigTest;
    try std.testing.expectEqual(BackendKind.headless, try resolveBackend(.{}, .{}));
}
test "resolveBackend: explicit kinds pass through" {
    if (!enabled.client_kms or !enabled.client_wayland or !enabled.client_headless) return error.SkipZigTest;
    try std.testing.expectEqual(BackendKind.kms, try resolveBackend(.{ .backend = .kms }, .{}));
    try std.testing.expectEqual(BackendKind.headless, try resolveBackend(.{ .backend = .headless }, .{}));
}

test "resolveBackend rejects a backend that is not compiled in" {
    if (!enabled.client_kms) {
        try std.testing.expectError(error.InvalidBackend, resolveBackend(.{ .backend = .kms }, .{}));
    }
    if (!enabled.client_wayland) {
        try std.testing.expectError(error.InvalidBackend, resolveBackend(.{ .backend = .wayland }, .{}));
    }
    if (!enabled.client_headless) {
        try std.testing.expectError(error.InvalidBackend, resolveBackend(.{ .backend = .headless }, .{}));
    }
}

test "auto never picks a backend that is not compiled in" {
    const probes = [_]EnvProbe{
        .{ .wayland_display = "wayland-0" },
        .{ .xdg_session_type = "wayland" },
        .{ .xdg_session_type = "tty", .kms_device = "/dev/dri/card0" },
        .{ .kms_device = "/dev/dri/card0" },
        .{ .x11_display = ":0", .xdg_session_type = "x11" },
        .{},
    };
    for (probes) |probe| {
        const got = resolveBackend(.{}, probe) catch continue;
        switch (got) {
            .wayland => try std.testing.expect(enabled.client_wayland),
            .kms => try std.testing.expect(enabled.client_kms),
            .headless => try std.testing.expect(enabled.client_headless),
            .auto => try std.testing.expect(false),
        }
    }
}

test "InputConfig defaults match libinput built-in defaults" {
    const cfg = InputConfig{};
    try std.testing.expectEqual(AccelProfile.adaptive, cfg.accel_profile);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), cfg.accel_speed, 1e-12);
    try std.testing.expect(!cfg.natural_scroll);
    try std.testing.expect(!cfg.left_handed);
    try std.testing.expect(!cfg.middle_emulation);
    try std.testing.expectEqual(ScrollMethod.none, cfg.scroll_method);
}

test "Options.input field zero-initialises to default InputConfig" {
    const opts = Options{};
    try std.testing.expectEqual(AccelProfile.adaptive, opts.input.accel_profile);
    try std.testing.expectEqual(ScrollMethod.none, opts.input.scroll_method);
}
