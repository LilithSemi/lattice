//! Server-side wp_fractional_scale_manager_v1 support.
const wl = @import("wayland");
const fs = @import("fractional_scale");

const Object = wl.Object;
const CompositorOpaque = opaque {};

pub const Ctx = struct {
    compositor: *CompositorOpaque = undefined,
    manager_impl: fs.WpFractionalScaleManagerV1.Implementation,
    scale_impl: fs.WpFractionalScaleV1.Implementation,
};

pub fn makeCtx() Ctx {
    return .{
        .manager_impl = .{ .destroy = destroyManager, .get_fractional_scale = getFractionalScale },
        .scale_impl = .{ .destroy = destroyScale },
    };
}

pub fn registerGlobal(display: *wl.Display, ctx: *Ctx) !void {
    _ = try display.globalCreate(&fs.WpFractionalScaleManagerV1.interface, 1, bind, ctx);
}

fn compositor(ctx: *Ctx) *@import("../compositor.zig").Compositor {
    return @ptrCast(@alignCast(ctx.compositor));
}

fn bind(client: *wl.server_client.Client, data: ?*anyopaque, version: u32, id: u32) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    const resource = Object.create(client, &fs.WpFractionalScaleManagerV1.interface, @min(version, 1), id) catch return;
    fs.WpFractionalScaleManagerV1.setImplementation(resource, &ctx.manager_impl, ctx, null);
}

fn destroyManager(_: ?*anyopaque, resource: *Object) void {
    resource.destroy();
}

fn getFractionalScale(data: ?*anyopaque, resource: *Object, id: u32, surface: *Object) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    const entry = compositor(ctx).findSurface(surface.client, surface.id) orelse return;
    if (entry.fractional_scale_res != null) {
        resource.postError(@backingInt(fs.WpFractionalScaleManagerV1.Error.fractional_scale_exists), "surface already has fractional-scale state", .{});
        return;
    }
    const scale = Object.create(resource.client, &fs.WpFractionalScaleV1.interface, 1, id) catch return;
    fs.WpFractionalScaleV1.setImplementation(scale, &ctx.scale_impl, ctx, scaleDestroyed);
    entry.fractional_scale_res = scale;
    // 120 / 120 = 1.0. Clients combine this with wp_viewporter when needed.
    fs.WpFractionalScaleV1.sendPreferredScale(scale, 120);
}

fn entryForScale(ctx: *Ctx, resource: *Object) ?*@import("../compositor.zig").HostedEntry {
    for (compositor(ctx).surface_entries.items) |*entry| {
        if (entry.fractional_scale_res == resource) return entry;
    }
    return null;
}

fn destroyScale(data: ?*anyopaque, resource: *Object) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    if (entryForScale(ctx, resource)) |entry| entry.fractional_scale_res = null;
    resource.destroy();
}

fn scaleDestroyed(resource: *Object) void {
    const ctx: *Ctx = @ptrCast(@alignCast(resource.user_data orelse return));
    if (entryForScale(ctx, resource)) |entry| entry.fractional_scale_res = null;
}
