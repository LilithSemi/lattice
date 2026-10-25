const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build-options");

pub const client_wayland = build_options.client_wayland and builtin.os.tag == .linux;
pub const client_kms = build_options.client_kms and builtin.os.tag == .linux;
pub const client_headless = build_options.client_headless;
pub const compositor_wayland = build_options.compositor_wayland;

test "at least one client backend is enabled" {
    try std.testing.expect(client_wayland or client_kms or client_headless);
}

test "the wayland and kms clients imply linux" {
    if (client_wayland or client_kms) try std.testing.expect(builtin.os.tag == .linux);
}
