//! Server-side wp_viewporter support for hosted Wayland clients.
const wl = @import("wayland");
const vp = @import("viewporter");

const Object = wl.Object;
const CompositorOpaque = opaque {};

pub const Ctx = struct {
    compositor: *CompositorOpaque = undefined,
    viewporter_impl: vp.WpViewporter.Implementation,
    viewport_impl: vp.WpViewport.Implementation,
};

pub fn makeCtx() Ctx {
    return .{
        .viewporter_impl = .{ .destroy = destroyViewporter, .get_viewport = getViewport },
        .viewport_impl = .{ .destroy = destroyViewport, .set_source = setSource, .set_destination = setDestination },
    };
}

pub fn registerGlobal(display: *wl.Display, ctx: *Ctx) !void {
    _ = try display.globalCreate(&vp.WpViewporter.interface, 1, bind, ctx);
}

fn compositor(ctx: *Ctx) *@import("../compositor.zig").Compositor {
    return @ptrCast(@alignCast(ctx.compositor));
}

fn bind(client: *wl.server_client.Client, data: ?*anyopaque, version: u32, id: u32) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    const resource = Object.create(client, &vp.WpViewporter.interface, @min(version, 1), id) catch return;
    vp.WpViewporter.setImplementation(resource, &ctx.viewporter_impl, ctx, null);
}

fn destroyViewporter(_: ?*anyopaque, resource: *Object) void {
    resource.destroy();
}

fn getViewport(data: ?*anyopaque, resource: *Object, id: u32, surface: *Object) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    const entry = compositor(ctx).findSurface(surface.client, surface.id) orelse return;
    if (entry.viewport_res != null) {
        resource.postError(@backingInt(vp.WpViewporter.Error.viewport_exists), "surface already has a viewport", .{});
        return;
    }
    const viewport = Object.create(resource.client, &vp.WpViewport.interface, 1, id) catch return;
    vp.WpViewport.setImplementation(viewport, &ctx.viewport_impl, ctx, viewportDestroyed);
    entry.viewport_res = viewport;
}

fn entryForViewport(ctx: *Ctx, resource: *Object) ?*@import("../compositor.zig").HostedEntry {
    for (compositor(ctx).surface_entries.items) |*entry| {
        if (entry.viewport_res == resource) return entry;
    }
    return null;
}

fn destroyViewport(data: ?*anyopaque, resource: *Object) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    if (entryForViewport(ctx, resource)) |entry| entry.clearViewport();
    resource.destroy();
}

fn viewportDestroyed(resource: *Object) void {
    const ctx: *Ctx = @ptrCast(@alignCast(resource.user_data orelse return));
    if (entryForViewport(ctx, resource)) |entry| entry.viewport_res = null;
}

fn setSource(data: ?*anyopaque, resource: *Object, x: wl.Fixed, y: wl.Fixed, width: wl.Fixed, height: wl.Fixed) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    const entry = entryForViewport(ctx, resource) orelse {
        resource.postError(@backingInt(vp.WpViewport.Error.no_surface), "viewport surface no longer exists", .{});
        return;
    };
    if (x.raw == -256 and y.raw == -256 and width.raw == -256 and height.raw == -256) {
        entry.viewport_pending_source = null;
    } else if (x.raw < 0 or y.raw < 0 or width.raw <= 0 or height.raw <= 0) {
        resource.postError(@backingInt(vp.WpViewport.Error.bad_value), "invalid viewport source", .{});
    } else {
        entry.viewport_pending_source = .{ .x = x.toDouble(), .y = y.toDouble(), .width = width.toDouble(), .height = height.toDouble() };
    }
}

fn setDestination(data: ?*anyopaque, resource: *Object, width: i32, height: i32) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    const entry = entryForViewport(ctx, resource) orelse {
        resource.postError(@backingInt(vp.WpViewport.Error.no_surface), "viewport surface no longer exists", .{});
        return;
    };
    if (width == -1 and height == -1) {
        entry.viewport_pending_destination = null;
    } else if (width <= 0 or height <= 0) {
        resource.postError(@backingInt(vp.WpViewport.Error.bad_value), "invalid viewport destination", .{});
    } else {
        entry.viewport_pending_destination = .{ .width = @intCast(width), .height = @intCast(height) };
    }
}
