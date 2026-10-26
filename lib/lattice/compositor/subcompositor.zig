//! Minimal but functional wl_subcompositor implementation.
const wl = @import("wayland");
const wlp = @import("wayland_protocol");

const Object = wl.Object;
const CompositorOpaque = opaque {};

pub const Ctx = struct {
    compositor: *CompositorOpaque = undefined,
    manager_impl: wlp.WlSubcompositor.Implementation,
    subsurface_impl: wlp.WlSubsurface.Implementation,
};

pub fn makeCtx() Ctx {
    return .{
        .manager_impl = .{ .destroy = destroyManager, .get_subsurface = getSubsurface },
        .subsurface_impl = .{
            .destroy = destroySubsurface,
            .set_position = setPosition,
            .place_above = placeAbove,
            .place_below = placeBelow,
            .set_sync = setSync,
            .set_desync = setDesync,
        },
    };
}

pub fn registerGlobal(display: *wl.Display, ctx: *Ctx) !void {
    _ = try display.globalCreate(&wlp.WlSubcompositor.interface, 1, bind, ctx);
}

fn compositor(ctx: *Ctx) *@import("../compositor.zig").Compositor {
    return @ptrCast(@alignCast(ctx.compositor));
}

fn bind(client: *wl.server_client.Client, data: ?*anyopaque, version: u32, id: u32) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    const resource = Object.create(client, &wlp.WlSubcompositor.interface, @min(version, 1), id) catch return;
    wlp.WlSubcompositor.setImplementation(resource, &ctx.manager_impl, ctx, null);
}

fn destroyManager(_: ?*anyopaque, resource: *Object) void {
    resource.destroy();
}

fn getSubsurface(data: ?*anyopaque, resource: *Object, id: u32, surface: *Object, parent: *Object) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    const comp = compositor(ctx);
    const child = comp.findSurface(surface.client, surface.id) orelse return;
    const parent_entry = comp.findSurface(parent.client, parent.id) orelse return;
    if (child.subsurface_res != null or child.state.role != .none) {
        resource.postError(@backingInt(wlp.WlSubcompositor.Error.bad_surface), "surface already has a role", .{});
        return;
    }
    if (surface == parent) {
        resource.postError(@backingInt(wlp.WlSubcompositor.Error.bad_parent), "surface cannot parent itself", .{});
        return;
    }
    const subsurface = Object.create(resource.client, &wlp.WlSubsurface.interface, 1, id) catch return;
    wlp.WlSubsurface.setImplementation(subsurface, &ctx.subsurface_impl, ctx, subsurfaceDestroyed);
    child.subsurface_res = subsurface;
    child.surface.parent = parent_entry.surface.id;
    child.surface.above_parent = true;
}

fn entryFor(ctx: *Ctx, resource: *Object) ?*@import("../compositor.zig").HostedEntry {
    for (compositor(ctx).surface_entries.items) |*entry| {
        if (entry.subsurface_res == resource) return entry;
    }
    return null;
}

fn destroySubsurface(data: ?*anyopaque, resource: *Object) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    if (entryFor(ctx, resource)) |entry| entry.clearSubsurface();
    resource.destroy();
}

fn subsurfaceDestroyed(resource: *Object) void {
    const ctx: *Ctx = @ptrCast(@alignCast(resource.user_data orelse return));
    if (entryFor(ctx, resource)) |entry| entry.clearSubsurface();
}

fn setPosition(data: ?*anyopaque, resource: *Object, x: i32, y: i32) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    if (entryFor(ctx, resource)) |entry| {
        entry.surface.offset_x = x;
        entry.surface.offset_y = y;
        entry.needs_committed_event = true;
    }
}

fn placeAbove(data: ?*anyopaque, resource: *Object, sibling: *Object) void {
    _ = sibling;
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    if (entryFor(ctx, resource)) |entry| entry.surface.above_parent = true;
}

fn placeBelow(data: ?*anyopaque, resource: *Object, sibling: *Object) void {
    _ = sibling;
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    if (entryFor(ctx, resource)) |entry| entry.surface.above_parent = false;
}

fn setSync(data: ?*anyopaque, resource: *Object) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    if (entryFor(ctx, resource)) |entry| entry.subsurface_sync = true;
}

fn setDesync(data: ?*anyopaque, resource: *Object) void {
    const ctx: *Ctx = @ptrCast(@alignCast(data.?));
    if (entryFor(ctx, resource)) |entry| entry.subsurface_sync = false;
}
