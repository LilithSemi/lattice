const std = @import("std");
const builtin = @import("builtin");
const id = @import("id.zig");
const surface = @import("surface.zig");
const output = @import("output.zig");
const event = @import("event.zig");
const text_input = @import("text_input.zig");
const window_chrome = @import("window_chrome.zig");
const backendMod = @import("backend.zig");
const options_mod = @import("options.zig");
const enabled = @import("backends_enabled.zig");
const prism = @import("prism");

pub const Handler = *const fn (ctx_data: *anyopaque, ev: event.Event) void;

pub const ClientInfo = struct { id: u32, title: []const u8 };

/// Bridges the neutral Handler to the backend's EventSink. Stored on the stack
/// during a poll so no allocation happens on the event path.
const Dispatch = struct {
    ctx: *Context,
    handler: Handler,
    handler_ctx: *anyopaque,

    fn sink(ptr: *anyopaque, ev: event.Event) void {
        const self: *Dispatch = @ptrCast(@alignCast(ptr));
        // Plan 1 is single-surface: any close_requested ends the run loop. Multi-surface
        // close handling (close one window, keep running) lands with the hosting layer.
        if (ev == .close_requested) self.ctx.running = false;
        self.handler(self.handler_ctx, ev);
    }
};

pub const Context = struct {
    backend: backendMod.Backend,
    running: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, opts: options_mod.Options) !Context {
        const probe = options_mod.EnvProbe{
            .wayland_display = env.get("WAYLAND_DISPLAY"),
            .x11_display = env.get("DISPLAY"),
            .xdg_session_type = env.get("XDG_SESSION_TYPE"),
            .kms_device = env.get("DRM_DEVICE") orelse defaultDrmDevice(io),
        };
        const kind = try options_mod.resolveBackend(opts, probe);
        switch (kind) {
            .wayland => {
                if (comptime !enabled.client_wayland) return error.InvalidBackend;
                const wayland_backend = @import("backend/wayland.zig");
                var path_buf: [4096]u8 = undefined;
                const wl = @import("wayland");
                const socket_path = try wl.client.resolveSocketPath(env, &path_buf);
                const w = try wayland_backend.Wayland.init(gpa, io, socket_path, opts);
                return initWithBackend(w.backend());
            },
            .kms => {
                if (comptime !enabled.client_kms) return error.InvalidBackend;
                const kms_backend = @import("backend/kms.zig");
                const device_path = probe.kms_device orelse ""; // "" -> kms.init discovers via udev
                const k = kms_backend.Kms.init(gpa, io, device_path, opts) catch |err| switch (err) {
                    // If we AUTO-selected kms but can't acquire the device (no seat, denied,
                    // or no card), fall back to headless instead of failing the whole app.
                    error.NoSession, error.DeviceAccessDenied, error.NoDrmDevice => if (comptime enabled.client_headless) {
                        if (opts.backend == .auto) {
                            const h = try @import("backend/headless.zig").Headless.init(gpa, io);
                            return initWithBackend(h.backend());
                        }
                        return err;
                    } else return err,
                    else => return err,
                };
                return initWithBackend(k.backend());
            },
            .headless => {
                if (comptime !enabled.client_headless) return error.InvalidBackend;
                const headless_backend = @import("backend/headless.zig");
                const h = try headless_backend.Headless.init(gpa, io);
                return initWithBackend(h.backend());
            },
            .auto => unreachable,
        }
    }

    pub fn initWithBackend(b: backendMod.Backend) Context {
        return .{ .backend = b };
    }

    pub fn deinit(self: *Context) void {
        self.backend.deinit();
    }

    pub fn createSurface(self: *Context, desc: surface.SurfaceDesc) !surface.Surface {
        return self.backend.createSurface(desc);
    }

    pub fn destroySurface(self: *Context, s: id.SurfaceId) void {
        self.backend.destroySurface(s);
    }

    pub fn renderTarget(self: *Context, s: id.SurfaceId) !surface.RenderTarget {
        return self.backend.surfaceRenderTarget(s);
    }

    pub fn commit(self: *Context, s: id.SurfaceId) !void {
        return self.backend.commitFrame(s);
    }

    pub fn renderAvailable(self: *Context, s: id.SurfaceId) bool {
        return self.backend.renderAvailable(s);
    }

    pub fn outputs(self: *Context) []const output.Output {
        return self.backend.enumerateOutputs();
    }

    pub fn clients(_: *Context) []const ClientInfo {
        return &.{};
    }

    pub fn capabilities(self: *Context) backendMod.Capabilities {
        return self.backend.capabilities();
    }

    /// The seat's device classes as of now. Valid before the first poll, so a
    /// shell can pick its first layout from it. A later change arrives as an
    /// `.seat_capabilities` event, which is the only way to learn about a mouse
    /// plugged in while the loop is idle.
    pub fn seatCapabilities(self: *Context) event.SeatCapabilities {
        return self.backend.seatCapabilities();
    }

    pub fn fd(self: *Context) ?std.posix.fd_t {
        return self.backend.fd();
    }

    pub fn renderDevice(self: *Context) ?*prism.Device {
        return self.backend.renderDevice();
    }

    /// Forward a pointer constraint request from the compositor to the backend.
    /// Call this from the App's CompositorEvent handler when receiving a
    /// `.pointer_constraint` event so the parent compositor (Wayland backend)
    /// or display server (KMS backend) can enforce the hardware pointer constraint.
    pub fn applyPointerConstraint(self: *Context, req: backendMod.PointerConstraintReq) void {
        self.backend.applyPointerConstraint(req);
    }

    pub fn setTextInput(self: *Context, s: id.SurfaceId, state: ?text_input.State) !void {
        try self.backend.setTextInput(s, state);
    }

    pub fn setTitle(self: *Context, s: id.SurfaceId, title: []const u8) !void {
        try self.backend.windowCommand(s, .{ .set_title = title });
    }

    pub fn setAppId(self: *Context, s: id.SurfaceId, app_id: []const u8) !void {
        try self.backend.windowCommand(s, .{ .set_app_id = app_id });
    }

    pub fn setDecorationMode(self: *Context, s: id.SurfaceId, mode: window_chrome.DecorationMode) !void {
        try self.backend.windowCommand(s, .{ .set_decoration_mode = mode });
    }

    /// Start a compositor move with the current pointer press. Call this from
    /// that press's event handler. A released or unfocused press returns
    /// error.NoActivePointerPress.
    pub fn beginMove(self: *Context, s: id.SurfaceId) !void {
        try self.backend.windowCommand(s, .move);
    }

    /// Start a compositor resize with the current pointer press.
    pub fn beginResize(self: *Context, s: id.SurfaceId, edge: window_chrome.ResizeEdge) !void {
        try self.backend.windowCommand(s, .{ .resize = edge });
    }

    pub fn setMaximized(self: *Context, s: id.SurfaceId, maximized: bool) !void {
        try self.backend.windowCommand(s, .{ .set_maximized = maximized });
    }

    pub fn minimize(self: *Context, s: id.SurfaceId) !void {
        try self.backend.windowCommand(s, .minimize);
    }

    pub fn setFullscreen(self: *Context, s: id.SurfaceId, fullscreen: bool) !void {
        try self.backend.windowCommand(s, .{ .set_fullscreen = fullscreen });
    }

    /// Show the compositor menu for the current pointer press.
    pub fn showWindowMenu(self: *Context, s: id.SurfaceId, position: window_chrome.Position) !void {
        try self.backend.windowCommand(s, .{ .show_window_menu = position });
    }

    pub fn setMinSize(self: *Context, s: id.SurfaceId, size: window_chrome.Size) !void {
        try self.backend.windowCommand(s, .{ .set_min_size = size });
    }

    pub fn setMaxSize(self: *Context, s: id.SurfaceId, size: window_chrome.Size) !void {
        try self.backend.windowCommand(s, .{ .set_max_size = size });
    }

    pub fn poll(self: *Context, timeout_ms: ?u32, handler: Handler, handler_ctx: *anyopaque) !void {
        var dispatch = Dispatch{ .ctx = self, .handler = handler, .handler_ctx = handler_ctx };
        try self.backend.pump(timeout_ms, Dispatch.sink, &dispatch);
    }

    pub fn pump(self: *Context, handler: Handler, handler_ctx: *anyopaque) !void {
        return self.poll(null, handler, handler_ctx);
    }

    pub fn run(self: *Context, handler: Handler, handler_ctx: *anyopaque) !void {
        self.running = true;
        while (self.running) {
            try self.poll(null, handler, handler_ctx);
        }
    }

    pub fn quit(self: *Context) void {
        self.running = false;
        self.backend.wakeup();
    }
};

/// The default primary DRM node path IF it exists, else null. Only meaningful on
/// Linux; other OSes return null so `.auto` never considers KMS. This is the only
/// place a /dev/dri path or an existence check lives in the core selection path.
fn defaultDrmDevice(io: std.Io) ?[]const u8 {
    if (builtin.os.tag != .linux) return null;
    // TODO: make this smarter based on the type of GPU
    std.Io.Dir.cwd().access(io, "/dev/dri/card0", .{}) catch return null;
    return "/dev/dri/card0";
}

const headless_mod = @import("backend/headless.zig");
const color = @import("color.zig");

test "an application reads the seat state and then receives the change through its handler" {
    const h = try headless_mod.Headless.init(std.testing.allocator, std.testing.io);
    var ctx = Context.initWithBackend(h.backend());
    defer ctx.deinit();

    // Startup value: available with no poll, which is what the first layout uses.
    const at_startup = ctx.seatCapabilities();
    try std.testing.expectEqual(true, at_startup.pointer);
    try std.testing.expectEqual(false, at_startup.touch);

    // A tablet gets docked: the state changes and the change is announced.
    const docked = event.SeatCapabilities{ .pointer = false, .keyboard = false, .touch = true };
    h.setSeatCapabilities(docked);
    try h.pushEvent(.{ .seat_capabilities = docked });

    const H = struct {
        var seen: u32 = 0;
        var last: event.SeatCapabilities = .{};
        fn on(_: *anyopaque, ev: event.Event) void {
            switch (ev) {
                .seat_capabilities => |c| {
                    seen += 1;
                    last = c;
                },
                else => {},
            }
        }
    };
    H.seen = 0;
    H.last = .{};

    var dummy: u8 = 0;
    try ctx.pump(H.on, &dummy);
    try std.testing.expectEqual(@as(u32, 1), H.seen);
    try std.testing.expectEqual(true, H.last.touch);
    try std.testing.expectEqual(false, H.last.pointer);
    try std.testing.expect(ctx.seatCapabilities().eql(docked));
}

test "context drives neutral API end to end against headless" {
    const h = try headless_mod.Headless.init(std.testing.allocator, std.testing.io);
    const outs = [_]output.Output{.{
        .id = id.OutputId.from(1),
        .name = "HEADLESS-1",
        .width = 1920,
        .height = 1080,
        .refresh_mhz = 60000,
        .hdr = .{ .supported = true, .max_nits = 1000, .bit_depth = 10 },
    }};
    h.setOutputs(&outs);

    var ctx = Context.initWithBackend(h.backend());
    defer ctx.deinit();

    const s = try ctx.createSurface(.{
        .width = 800,
        .height = 600,
        .color = color.ColorConfig.sdr(.xrgb8888),
    });
    try std.testing.expectEqual(@as(usize, 1), ctx.outputs().len);
    try std.testing.expect(ctx.outputs()[0].supportsHdr());
    try std.testing.expect(ctx.capabilities().hdr);
    try std.testing.expect(ctx.renderAvailable(s.id));
    try std.testing.expectEqual(@as(usize, 0), ctx.clients().len);

    try h.pushEvent(.{ .resized = .{
        .surface = s.id,
        .width = 1024,
        .height = 768,
    } });
    try h.pushEvent(.{ .close_requested = s.id });

    const H = struct {
        var last_w: u32 = 0;
        var closed: bool = false;
        fn on(_: *anyopaque, ev: event.Event) void {
            switch (ev) {
                .resized => |r| last_w = r.width,
                .close_requested => closed = true,
                else => {},
            }
        }
    };
    H.last_w = 0;
    H.closed = false;

    var dummy: u8 = 0;
    try ctx.run(H.on, &dummy);
    try std.testing.expectEqual(@as(u32, 1024), H.last_w);
    try std.testing.expect(H.closed);
    try std.testing.expect(!ctx.running);
}
