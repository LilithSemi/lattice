//! Root of lattice: a portable, neutral display library. Consumers reach the
//! pieces as namespaces: `lattice.Context`, `lattice.Surface`, `lattice.Output`,
//! `lattice.Event`, `lattice.color`.
const std = @import("std");
const enabled = @import("lattice/backends_enabled.zig");

pub const backends_enabled = enabled;

pub const name = "lattice";

pub const options = @import("lattice/options.zig");
pub const Options = options.Options;
pub const InputConfig = options.InputConfig;
pub const AccelProfile = options.AccelProfile;
pub const ScrollMethod = options.ScrollMethod;

pub const color = @import("lattice/color.zig");
pub const PixelFormat = color.PixelFormat;
pub const Colorspace = color.Colorspace;
pub const TransferFunction = color.TransferFunction;
pub const Luminance = color.Luminance;
pub const ColorConfig = color.ColorConfig;

pub const id = @import("lattice/id.zig");
pub const SurfaceId = id.SurfaceId;
pub const OutputId = id.OutputId;

pub const event = @import("lattice/event.zig");
pub const Event = event.Event;
pub const InputEvent = event.InputEvent;
pub const SeatCapabilities = event.SeatCapabilities;

pub const text_input = @import("lattice/text_input.zig");
pub const TextInputState = text_input.State;
pub const TextInputEvent = text_input.Event;

pub const keyboard = @import("lattice/keyboard.zig");
pub const KeyboardState = keyboard.KeyboardState;

pub const output = @import("lattice/output.zig");
pub const Output = output.Output;
pub const HdrCaps = output.HdrCaps;

pub const surface = @import("lattice/surface.zig");
pub const Surface = surface.Surface;
pub const SurfaceDesc = surface.SurfaceDesc;
pub const RenderTarget = surface.RenderTarget;

pub const window_chrome = @import("lattice/window_chrome.zig");
pub const DecorationMode = window_chrome.DecorationMode;
pub const ResizeEdge = window_chrome.ResizeEdge;
pub const WindowState = window_chrome.WindowState;
pub const WindowConfigure = window_chrome.Configure;
pub const WindowPosition = window_chrome.Position;
pub const WindowSize = window_chrome.Size;

pub const backend = @import("lattice/backend.zig");
pub const Backend = backend.Backend;
pub const Capabilities = backend.Capabilities;

pub const backends = struct {
    pub const Headless = if (enabled.client_headless) @import("lattice/backend/headless.zig").Headless else void;
    pub const Android = @import("lattice/backend/android.zig").Android;
    pub const backends_wayland = if (enabled.client_wayland) @import("lattice/backend/wayland.zig") else void;
};

pub const context = @import("lattice/context.zig");
pub const Context = context.Context;
pub const Handler = context.Handler;
pub const ClientInfo = context.ClientInfo;

pub const render = @import("lattice/render.zig");

pub const outputs_internal = if (enabled.client_wayland) @import("lattice/backend/wayland/outputs.zig") else void;
pub const shmbuffer_internal = if (enabled.client_wayland) @import("lattice/backend/wayland/shmbuffer.zig") else void;
pub const dispatch_internal = if (enabled.client_wayland) @import("lattice/backend/wayland/dispatch.zig") else void;
pub const wayland_color_internal = if (enabled.client_wayland) @import("lattice/backend/wayland/color.zig") else void;
pub const surface_state_internal = if (enabled.compositor_wayland) @import("lattice/compositor/surface_state.zig") else void;

pub const compositor_types = if (enabled.compositor_wayland) @import("lattice/compositor/hosted.zig") else void;
pub const HostedSurface = if (enabled.compositor_wayland) compositor_types.HostedSurface else void;
pub const CompositorEvent = if (enabled.compositor_wayland) compositor_types.CompositorEvent else void;

pub const compositor = if (enabled.compositor_wayland) @import("lattice/compositor.zig") else void;
pub const Compositor = if (enabled.compositor_wayland) compositor.Compositor else void;
pub const Rect = if (enabled.compositor_wayland) compositor.Rect else void;

pub const compositor_xdg = if (enabled.compositor_wayland) @import("lattice/compositor/xdg.zig") else void;
pub const compositor_draw = if (enabled.compositor_wayland) @import("lattice/compositor/draw.zig") else void;
pub const compositor_seat = if (enabled.compositor_wayland) @import("lattice/compositor/seat.zig") else void;
pub const compositor_color_manager = if (enabled.compositor_wayland) @import("lattice/compositor/color_manager.zig") else void;
pub const constraints_internal = if (enabled.compositor_wayland) @import("lattice/compositor/constraints.zig") else void;
pub const tablet_input_internal = if (enabled.compositor_wayland) @import("lattice/compositor/tablet_input.zig") else void;

pub const format_map = @import("lattice/format_map.zig");

pub const dmabuf_bindings_test = @import("lattice/dmabuf_bindings_test.zig");
pub const color_management_bindings_test = @import("lattice/color_management_bindings_test.zig");
pub const xkbcommon_bindings_test = @import("lattice/xkbcommon_bindings_test.zig");
pub const kms_input_internal = if (enabled.client_kms) @import("lattice/backend/kms/input.zig") else void;
pub const wayland_input_internal = if (enabled.client_wayland) @import("lattice/backend/wayland/input.zig") else void;

test "module compiles and name is set" {
    try std.testing.expectEqualStrings("lattice", name);
}

test {
    std.testing.refAllDecls(@This());
}
