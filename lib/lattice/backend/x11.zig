//! X11 client backend. Lattice owns the event connection and native window;
//! Prism wraps that XID on a private connection for software/GPU presentation.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const prism = @import("prism");
const x11 = @import("x11");
const xproto = @import("xproto");

const backend_mod = @import("../backend.zig");
const color = @import("../color.zig");
const event = @import("../event.zig");
const id = @import("../id.zig");
const options = @import("../options.zig");
const output = @import("../output.zig");
const surface = @import("../surface.zig");

const event_structure_notify: u32 = 1 << 17;
const atom_atom: u32 = 4;
const atom_string: u32 = 31;
const atom_wm_name: u32 = 39;
const atom_wm_class: u32 = 67;

fn internAtom(client: *x11.Client, gpa: std.mem.Allocator, name: []const u8) !u32 {
    const cookie = try xproto.intern_atom(client, gpa, false, name);
    var xe: x11.wire.XError = undefined;
    var reply = try client.awaitReply(@TypeOf(cookie).ReplyType, cookie, &xe);
    defer reply.deinit();
    return xproto.decodeInternAtomReply(reply.bytes).atom;
}

const Window = struct {
    id: id.SurfaceId,
    xid: u32,
    desc: surface.SurfaceDesc,
    foreign: prism.platform.x11.ForeignWindow,
    hal: *prism.Surface,
    target: *prism.Resource,
    width: u32,
    height: u32,
    redraw_pending: bool = true,
};

pub const X11 = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    display_name: []const u8,
    client: x11.Client,
    screen: x11.wire.Screen,
    wm_protocols: u32,
    wm_delete_window: u32,
    wake_fd: posix.fd_t,
    device: prism.Device,
    context: prism.Context,
    next_id: u32 = 1,
    window: ?*Window = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, display_name: []const u8, environ: *const std.process.Environ.Map, opts: options.Options) !*X11 {
        var client = try x11.Client.open(gpa, io, display_name, null, environ);
        errdefer client.close();
        const screen = client.defaultScreen() orelse return error.InitializationFailed;
        const wm_protocols = try internAtom(&client, gpa, "WM_PROTOCOLS");
        const wm_delete_window = try internAtom(&client, gpa, "WM_DELETE_WINDOW");

        const selected: prism.drivers.Selected = blk: {
            if (opts.driver) |name| {
                const driver = prism.drivers.select(name, io) orelse return error.UnknownDriver;
                break :blk .{ .driver = driver, .device = try driver.createDevice(gpa, io) };
            }
            break :blk prism.drivers.createBestDevice(gpa, io) orelse return error.NoWorkingDriver;
        };
        errdefer selected.device.deinit();
        const context = try selected.device.createContext();
        errdefer context.deinit();

        const wakeup_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(wakeup_rc) != .SUCCESS) return error.EventfdFailed;
        const wake_fd: posix.fd_t = @intCast(wakeup_rc);
        errdefer _ = linux.close(wake_fd);

        const self = try gpa.create(X11);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .environ = environ,
            .display_name = display_name,
            .client = client,
            .screen = screen,
            .wm_protocols = wm_protocols,
            .wm_delete_window = wm_delete_window,
            .wake_fd = wake_fd,
            .device = selected.device,
            .context = context,
        };
        return self;
    }

    pub fn backend(self: *X11) backend_mod.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ptr: *anyopaque) *X11 {
        return @ptrCast(@alignCast(ptr));
    }

    fn findWindow(self: *X11, sid: id.SurfaceId) !*Window {
        const window = self.window orelse return error.NoSurface;
        return if (window.id == sid) window else error.NoSurface;
    }

    fn makeTarget(self: *X11, width: u32, height: u32) !*prism.Resource {
        return self.device.createResource(.{ .image = .{
            .width = width,
            .height = height,
            .format = .rgba8_unorm,
            .usage = .{ .render_target = true },
        } });
    }

    fn createSurface(ptr: *anyopaque, desc: surface.SurfaceDesc) anyerror!surface.Surface {
        const self = cast(ptr);
        if (self.window != null) return error.Unsupported;
        if (desc.color.isHdr()) return error.UnsupportedFormat;

        const width = if (desc.width != 0) desc.width else 800;
        const height = if (desc.height != 0) desc.height else 600;
        if (width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) return error.InvalidSize;

        const xid = self.client.generateId();
        _ = try xproto.create_window(&self.client, self.gpa, self.screen.root_depth, xid, self.screen.root, 0, 0, @intCast(width), @intCast(height), 0, 1, self.screen.root_visual, .{
            .background_pixel = self.screen.black_pixel,
            .border_pixel = self.screen.black_pixel,
            .event_mask = event_structure_notify,
        });
        errdefer _ = xproto.destroy_window(&self.client, xid) catch {};

        _ = try xproto.change_property(&self.client, self.gpa, 0, xid, self.wm_protocols, atom_atom, 32, 1, std.mem.asBytes(&self.wm_delete_window));
        const title = if (desc.title.len != 0) desc.title else "lattice";
        _ = try xproto.change_property(&self.client, self.gpa, 0, xid, atom_wm_name, atom_string, 8, @intCast(title.len), title);
        const wm_class = "lattice\x00Lattice\x00";
        _ = try xproto.change_property(&self.client, self.gpa, 0, xid, atom_wm_class, atom_string, 8, @intCast(wm_class.len), wm_class);
        _ = try xproto.map_window(&self.client, xid);

        const geometry_cookie = try xproto.get_geometry(&self.client, xid);
        var xe: x11.wire.XError = undefined;
        var geometry = try self.client.awaitReply(xproto.GetGeometryReply, geometry_cookie, &xe);
        geometry.deinit();

        var foreign = try prism.platform.x11.wrapWindow(self.gpa, self.io, self.display_name, self.environ, xid);
        errdefer foreign.deinit();
        const target = try self.makeTarget(width, height);
        errdefer self.device.destroyResource(target);

        const sid = id.SurfaceId.from(self.next_id);
        self.next_id += 1;
        const window = try self.gpa.create(Window);
        errdefer self.gpa.destroy(window);
        window.* = .{ .id = sid, .xid = xid, .desc = desc, .foreign = foreign, .hal = undefined, .target = target, .width = width, .height = height };
        window.hal = try self.device.createSurface(@ptrCast(&window.foreign.surface));
        self.window = window;
        return .{ .id = sid, .desc = desc };
    }

    fn destroySurface(ptr: *anyopaque, sid: id.SurfaceId) void {
        const self = cast(ptr);
        const window = self.window orelse return;
        if (window.id != sid) return;
        self.device.destroyResource(window.target);
        self.device.destroySurface(window.hal);
        window.foreign.deinit();
        _ = xproto.destroy_window(&self.client, window.xid) catch {};
        self.gpa.destroy(window);
        self.window = null;
    }

    fn surfaceRenderTarget(ptr: *anyopaque, sid: id.SurfaceId) anyerror!surface.RenderTarget {
        const self = cast(ptr);
        const window = try self.findWindow(sid);
        if (window.width == 0 or window.height == 0) return error.InvalidSize;
        return .{ .context = &self.context, .target = window.target, .width = window.width, .height = window.height, .format = .xrgb8888 };
    }

    fn commitFrame(ptr: *anyopaque, sid: id.SurfaceId) anyerror!void {
        const self = cast(ptr);
        const window = try self.findWindow(sid);
        try self.context.present(window.hal, window.target);
    }

    fn renderAvailable(ptr: *anyopaque, sid: id.SurfaceId) bool {
        _ = cast(ptr).findWindow(sid) catch return false;
        return true;
    }

    fn enumerateOutputs(_: *anyopaque) []const output.Output {
        return &.{};
    }

    fn capabilities(_: *anyopaque) backend_mod.Capabilities {
        return .{ .hdr = false, .formats = &.{.xrgb8888} };
    }

    fn seatCapabilities(_: *anyopaque) event.SeatCapabilities {
        return .{};
    }

    fn dispatchIncoming(self: *X11, incoming: x11.connection.Incoming, sink: backend_mod.EventSink, sink_ctx: *anyopaque) !void {
        const window = self.window orelse return;
        switch (incoming) {
            .err => return error.DeviceLost,
            .event => |raw| switch (xproto.decodeEvent(&raw.bytes)) {
                .configure_notify => |ev| {
                    if (ev.window != window.xid or ev.width == 0 or ev.height == 0 or (ev.width == window.width and ev.height == window.height)) return;
                    const replacement = try self.makeTarget(ev.width, ev.height);
                    self.device.destroyResource(window.target);
                    window.target = replacement;
                    window.width = ev.width;
                    window.height = ev.height;
                    sink(sink_ctx, .{ .resized = .{ .surface = window.id, .width = ev.width, .height = ev.height } });
                    window.redraw_pending = true;
                },
                .destroy_notify => |ev| if (ev.window == window.xid) sink(sink_ctx, .{ .close_requested = window.id }),
                .client_message => |ev| {
                    if (ev.window == window.xid and ev.type == self.wm_protocols and raw.bytes[1] == 32 and
                        std.mem.readInt(u32, raw.bytes[12..16], @import("builtin").cpu.arch.endian()) == self.wm_delete_window)
                        sink(sink_ctx, .{ .close_requested = window.id });
                },
                else => {},
            },
        }
    }

    fn pump(ptr: *anyopaque, timeout_ms: ?u32, sink: backend_mod.EventSink, sink_ctx: *anyopaque) anyerror!void {
        const self = cast(ptr);
        if (self.window) |window| {
            if (window.redraw_pending) {
                window.redraw_pending = false;
                sink(sink_ctx, .{ .redraw_requested = window.id });
                return;
            }
        }

        var fds = [_]posix.pollfd{
            .{ .fd = self.client.connectionFd(), .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = self.wake_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        _ = try posix.poll(&fds, if (timeout_ms) |ms| @intCast(ms) else -1);
        if (fds[1].revents & linux.POLL.IN != 0) {
            var value: u64 = 0;
            _ = linux.read(self.wake_fd, @ptrCast(&value), @sizeOf(u64));
        }
        if (fds[0].revents & linux.POLL.IN != 0) {
            while (try self.client.pollEvent()) |incoming| try self.dispatchIncoming(incoming, sink, sink_ctx);
        }
        if (self.window) |window| {
            if (window.redraw_pending) {
                window.redraw_pending = false;
                sink(sink_ctx, .{ .redraw_requested = window.id });
            }
        }
    }

    fn wakeup(ptr: *anyopaque) void {
        const value: u64 = 1;
        _ = linux.write(cast(ptr).wake_fd, @ptrCast(&value), @sizeOf(u64));
    }

    fn fd(ptr: *anyopaque) ?posix.fd_t {
        return cast(ptr).client.connectionFd();
    }

    fn renderDevice(ptr: *anyopaque) ?*prism.Device {
        return &cast(ptr).device;
    }

    fn applyPointerConstraint(_: *anyopaque, _: backend_mod.PointerConstraintReq) void {}

    fn deinitVt(ptr: *anyopaque) void {
        const self = cast(ptr);
        if (self.window) |window| destroySurface(self, window.id);
        self.context.deinit();
        self.device.deinit();
        self.client.close();
        _ = linux.close(self.wake_fd);
        self.gpa.destroy(self);
    }

    const vtable = backend_mod.VTable{
        .createSurface = createSurface,
        .destroySurface = destroySurface,
        .surfaceRenderTarget = surfaceRenderTarget,
        .commitFrame = commitFrame,
        .renderAvailable = renderAvailable,
        .enumerateOutputs = enumerateOutputs,
        .capabilities = capabilities,
        .seatCapabilities = seatCapabilities,
        .pump = pump,
        .wakeup = wakeup,
        .fd = fd,
        .renderDevice = renderDevice,
        .applyPointerConstraint = applyPointerConstraint,
        .deinit = deinitVt,
    };
};

test "X11 is an SDR presentation backend" {
    const caps = X11.capabilities(undefined);
    try std.testing.expect(!caps.hdr);
    try std.testing.expectEqualSlices(color.PixelFormat, &.{.xrgb8888}, caps.formats);
}
