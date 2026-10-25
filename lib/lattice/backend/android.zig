//! Android display backend.
//!
//! The Activity and SurfaceView live in the embedding application. Their JNI
//! bridge converts a Java Surface to an ANativeWindow and transfers that
//! reference to this backend. Android may destroy and recreate the native
//! window while the logical Lattice surface remains alive, so attachment is
//! deliberately separate from createSurface().
const std = @import("std");
const builtin = @import("builtin");
const id = @import("../id.zig");
const color = @import("../color.zig");
const surface = @import("../surface.zig");
const output = @import("../output.zig");
const event = @import("../event.zig");
const text_input = @import("../text_input.zig");
const backend_mod = @import("../backend.zig");
const prism = @import("prism");

extern "android" fn ANativeWindow_release(window: *anyopaque) callconv(.c) void;

pub const Android = struct {
    gpa: std.mem.Allocator,
    device: prism.Device,
    context: prism.Context,
    next_id: u32 = 1,
    surfaces: std.ArrayListUnmanaged(Entry) = .empty,
    events: std.ArrayListUnmanaged(QueuedEvent) = .empty,
    text_input_handler: ?TextInputHandler = null,

    pub const TextInputHandler = struct {
        ctx: *anyopaque,
        set: *const fn (ctx: *anyopaque, surface_id: id.SurfaceId, state: ?text_input.State) void,
    };

    const QueuedEvent = struct {
        value: event.Event,
        owned_text: ?[]u8 = null,

        fn deinit(self: QueuedEvent, gpa: std.mem.Allocator) void {
            if (self.owned_text) |text| gpa.free(text);
        }
    };

    const Entry = struct {
        value: surface.Surface,
        native_window: ?*anyopaque = null,
        prism_surface: ?*prism.Surface = null,
        target: ?*prism.Resource = null,
        width: u32 = 0,
        height: u32 = 0,
        density: f32 = 1,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !*Android {
        const selected = prism.drivers.createBestDevice(gpa, io) orelse return error.NoWorkingDriver;
        errdefer selected.device.deinit();
        if (!selected.device.caps().present) return error.PresentationUnsupported;
        const context = try selected.device.createContext();
        errdefer context.deinit();

        const self = try gpa.create(Android);
        self.* = .{
            .gpa = gpa,
            .device = selected.device,
            .context = context,
        };
        return self;
    }

    pub fn backend(self: *Android) backend_mod.Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Installs the embedding layer's virtual-keyboard hook. The state and its
    /// strings are borrowed for the callback only.
    pub fn setTextInputHandler(self: *Android, handler: ?TextInputHandler) void {
        self.text_input_handler = handler;
    }

    /// Attach an acquired ANativeWindow reference to a logical surface.
    /// Ownership transfers to this backend, including when attachment fails.
    pub fn attachNativeWindow(self: *Android, surface_id: id.SurfaceId, window: *anyopaque, width: u32, height: u32, density: f32) !void {
        errdefer releaseNativeWindow(window);
        if (width == 0 or height == 0) return error.InvalidSurfaceSize;
        const entry = self.find(surface_id) orelse return error.NoSurface;

        self.detachEntry(entry);
        entry.native_window = window;
        errdefer entry.native_window = null;
        entry.prism_surface = try self.device.createSurface(window);
        errdefer {
            self.device.destroySurface(entry.prism_surface.?);
            entry.prism_surface = null;
        }
        entry.target = try createTarget(self.device, width, height);
        errdefer {
            self.device.destroyResource(entry.target.?);
            entry.target = null;
        }
        entry.width = width;
        entry.height = height;
        entry.density = validDensity(density);
        entry.value.desc.width = width;
        entry.value.desc.height = height;

        try self.queue(.{ .resized = .{ .surface = surface_id, .width = width, .height = height } });
        try self.queue(.{ .scale_changed = .{ .surface = surface_id, .scale = entry.density } });
        try self.queue(.{ .redraw_requested = surface_id });
    }

    pub fn detachNativeWindow(self: *Android, surface_id: id.SurfaceId) void {
        const entry = self.find(surface_id) orelse return;
        self.detachEntry(entry);
    }

    pub fn resize(self: *Android, surface_id: id.SurfaceId, width: u32, height: u32, density: f32) !void {
        if (width == 0 or height == 0) return;
        const entry = self.find(surface_id) orelse return error.NoSurface;
        const scale = validDensity(density);
        const size_changed = width != entry.width or height != entry.height;
        const scale_changed = scale != entry.density;
        if (size_changed and entry.native_window != null) {
            const replacement = try createTarget(self.device, width, height);
            if (entry.target) |old| self.device.destroyResource(old);
            entry.target = replacement;
            entry.width = width;
            entry.height = height;
            entry.value.desc.width = width;
            entry.value.desc.height = height;
            try self.queue(.{ .resized = .{ .surface = surface_id, .width = width, .height = height } });
        }
        if (scale_changed) {
            entry.density = scale;
            try self.queue(.{ .scale_changed = .{ .surface = surface_id, .scale = scale } });
        }
        if (size_changed or scale_changed) try self.queue(.{ .redraw_requested = surface_id });
    }

    pub fn touchDown(self: *Android, surface_id: id.SurfaceId, pointer_id: u32, x: f64, y: f64) !void {
        if (self.find(surface_id) == null) return error.NoSurface;
        try self.queue(.{ .input = .{ .touch_down = .{ .surface = surface_id, .id = pointer_id, .x = x, .y = y } } });
    }

    pub fn touchMove(self: *Android, surface_id: id.SurfaceId, pointer_id: u32, x: f64, y: f64) !void {
        if (self.find(surface_id) == null) return error.NoSurface;
        try self.queue(.{ .input = .{ .touch_motion = .{ .surface = surface_id, .id = pointer_id, .x = x, .y = y } } });
    }

    pub fn touchUp(self: *Android, surface_id: id.SurfaceId, pointer_id: u32, x: f64, y: f64) !void {
        if (self.find(surface_id) == null) return error.NoSurface;
        try self.queue(.{ .input = .{ .touch_up = .{ .surface = surface_id, .id = pointer_id, .x = x, .y = y } } });
    }

    pub fn touchCancel(self: *Android, surface_id: id.SurfaceId, pointer_id: u32, x: f64, y: f64) !void {
        if (self.find(surface_id) == null) return error.NoSurface;
        try self.queue(.{ .input = .{ .touch_cancel = .{ .surface = surface_id, .id = pointer_id, .x = x, .y = y } } });
    }

    pub fn scroll(self: *Android, surface_id: id.SurfaceId, horizontal: f64, vertical: f64) !void {
        if (self.find(surface_id) == null) return error.NoSurface;
        try self.queue(.{ .input = .{ .pointer_axis = .{
            .surface = surface_id,
            .horizontal = horizontal,
            .vertical = vertical,
        } } });
    }

    pub fn key(self: *Android, surface_id: id.SurfaceId, key_event: event.KeyEvent) !void {
        if (self.find(surface_id) == null) return error.NoSurface;
        try self.queue(.{ .input = .{ .key = key_event } });
    }

    /// Queue final UTF-8 text from an input method. The backend owns a copy
    /// until the next pump has delivered the event.
    pub fn commitText(self: *Android, surface_id: id.SurfaceId, text: []const u8) !void {
        if (self.find(surface_id) == null) return error.NoSurface;
        try self.queueText(surface_id, text, .commit);
    }

    pub fn preeditText(self: *Android, surface_id: id.SurfaceId, text: []const u8, selection: ?text_input.Range) !void {
        if (self.find(surface_id) == null) return error.NoSurface;
        const owned = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned);
        try self.events.append(self.gpa, .{ .value = .{ .text_input = .{
            .surface = surface_id,
            .event = .{ .preedit = .{ .text = owned, .selection = selection } },
        } }, .owned_text = owned });
    }

    pub fn finishPreedit(self: *Android, surface_id: id.SurfaceId) !void {
        if (self.find(surface_id) == null) return error.NoSurface;
        try self.queue(.{ .text_input = .{ .surface = surface_id, .event = .{ .finish_preedit = {} } } });
    }

    pub fn deleteSurrounding(self: *Android, surface_id: id.SurfaceId, before_bytes: u32, after_bytes: u32) !void {
        if (self.find(surface_id) == null) return error.NoSurface;
        try self.queue(.{ .text_input = .{ .surface = surface_id, .event = .{ .delete_surrounding = .{
            .before_bytes = before_bytes,
            .after_bytes = after_bytes,
        } } } });
    }

    pub fn inputAction(self: *Android, surface_id: id.SurfaceId, action: text_input.Action) !void {
        if (self.find(surface_id) == null) return error.NoSurface;
        try self.queue(.{ .text_input = .{ .surface = surface_id, .event = .{ .action = action } } });
    }

    fn queue(self: *Android, value: event.Event) !void {
        try self.events.append(self.gpa, .{ .value = value });
    }

    fn queueText(self: *Android, surface_id: id.SurfaceId, text: []const u8, comptime tag: std.meta.Tag(text_input.Event)) !void {
        const owned = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned);
        const input_event: text_input.Event = @unionInit(text_input.Event, @tagName(tag), owned);
        try self.events.append(self.gpa, .{ .value = .{ .text_input = .{ .surface = surface_id, .event = input_event } }, .owned_text = owned });
    }

    fn find(self: *Android, surface_id: id.SurfaceId) ?*Entry {
        for (self.surfaces.items) |*entry| {
            if (entry.value.id == surface_id) return entry;
        }
        return null;
    }

    fn detachEntry(self: *Android, entry: *Entry) void {
        if (entry.target) |target| self.device.destroyResource(target);
        entry.target = null;
        if (entry.prism_surface) |prism_surface| self.device.destroySurface(prism_surface);
        entry.prism_surface = null;
        if (entry.native_window) |window| releaseNativeWindow(window);
        entry.native_window = null;
        entry.width = 0;
        entry.height = 0;
    }

    fn cast(ptr: *anyopaque) *Android {
        return @ptrCast(@alignCast(ptr));
    }

    fn createSurfaceVtable(ptr: *anyopaque, desc: surface.SurfaceDesc) anyerror!surface.Surface {
        const self = cast(ptr);
        const value = surface.Surface{ .id = id.SurfaceId.from(self.next_id), .desc = desc };
        self.next_id += 1;
        try self.surfaces.append(self.gpa, .{ .value = value });
        return value;
    }

    fn destroySurfaceVtable(ptr: *anyopaque, surface_id: id.SurfaceId) void {
        const self = cast(ptr);
        for (self.surfaces.items, 0..) |*entry, index| {
            if (entry.value.id != surface_id) continue;
            self.detachEntry(entry);
            _ = self.surfaces.orderedRemove(index);
            return;
        }
    }

    fn surfaceRenderTarget(ptr: *anyopaque, surface_id: id.SurfaceId) anyerror!surface.RenderTarget {
        const self = cast(ptr);
        const entry = self.find(surface_id) orelse return error.NoSurface;
        return .{
            .context = &self.context,
            .target = entry.target orelse return error.SurfaceUnavailable,
            .width = entry.width,
            .height = entry.height,
            .format = .xrgb8888,
        };
    }

    fn commitFrame(ptr: *anyopaque, surface_id: id.SurfaceId) anyerror!void {
        const self = cast(ptr);
        const entry = self.find(surface_id) orelse return error.NoSurface;
        try self.context.present(
            entry.prism_surface orelse return error.SurfaceUnavailable,
            entry.target orelse return error.SurfaceUnavailable,
        );
    }

    fn renderAvailable(ptr: *anyopaque, surface_id: id.SurfaceId) bool {
        const entry = cast(ptr).find(surface_id) orelse return false;
        return entry.prism_surface != null and entry.target != null;
    }

    fn enumerateOutputs(_: *anyopaque) []const output.Output {
        return &.{};
    }

    fn capabilities(_: *anyopaque) backend_mod.Capabilities {
        return .{ .hdr = false, .formats = &.{.xrgb8888} };
    }

    fn seatCapabilities(_: *anyopaque) event.SeatCapabilities {
        return .{ .pointer = false, .keyboard = false, .touch = true };
    }

    fn pump(ptr: *anyopaque, _: ?u32, sink: backend_mod.EventSink, sink_ctx: *anyopaque) anyerror!void {
        const self = cast(ptr);
        for (self.events.items) |queued| {
            sink(sink_ctx, queued.value);
            queued.deinit(self.gpa);
        }
        self.events.clearRetainingCapacity();
    }

    fn wakeup(_: *anyopaque) void {}

    fn fd(_: *anyopaque) ?std.posix.fd_t {
        return null;
    }

    fn renderDevice(ptr: *anyopaque) ?*prism.Device {
        return &cast(ptr).device;
    }

    fn applyPointerConstraint(_: *anyopaque, _: backend_mod.PointerConstraintReq) void {}

    fn setTextInputVtable(ptr: *anyopaque, surface_id: id.SurfaceId, state: ?text_input.State) anyerror!void {
        const self = cast(ptr);
        if (self.find(surface_id) == null) return error.NoSurface;
        if (self.text_input_handler) |handler| handler.set(handler.ctx, surface_id, state);
    }

    fn deinitVtable(ptr: *anyopaque) void {
        const self = cast(ptr);
        for (self.surfaces.items) |*entry| self.detachEntry(entry);
        self.context.deinit();
        self.device.deinit();
        self.surfaces.deinit(self.gpa);
        for (self.events.items) |queued| queued.deinit(self.gpa);
        self.events.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    const vtable = backend_mod.VTable{
        .createSurface = createSurfaceVtable,
        .destroySurface = destroySurfaceVtable,
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
        .setTextInput = setTextInputVtable,
        .deinit = deinitVtable,
    };
};

fn createTarget(device: prism.Device, width: u32, height: u32) !*prism.Resource {
    return device.createResource(.{ .image = .{
        .width = width,
        .height = height,
        .format = .rgba8_unorm,
        .usage = .{ .render_target = true },
    } });
}

fn validDensity(density: f32) f32 {
    return if (std.math.isFinite(density) and density > 0) density else 1;
}

fn releaseNativeWindow(window: *anyopaque) void {
    if (comptime builtin.abi.isAndroid()) ANativeWindow_release(window);
}

test "Android backend declarations compile on non-Android hosts" {
    try std.testing.refAllDecls(Android);
}

test "Android logical surfaces remain pending until a native window is attached" {
    var android = Android{
        .gpa = std.testing.allocator,
        .device = undefined,
        .context = undefined,
    };
    defer android.surfaces.deinit(std.testing.allocator);
    defer android.events.deinit(std.testing.allocator);

    const backend = android.backend();
    const logical_surface = try backend.createSurface(.{ .color = color.ColorConfig.sdr(.xrgb8888) });
    try std.testing.expect(!backend.renderAvailable(logical_surface.id));
    try android.touchDown(logical_surface.id, 7, 12, 34);
    try android.commitText(logical_surface.id, "hello");

    const Collector = struct {
        var touches: usize = 0;
        var committed: bool = false;
        fn sink(_: *anyopaque, queued: event.Event) void {
            if (queued == .input and queued.input == .touch_down) touches += 1;
            if (queued == .text_input and queued.text_input.event == .commit) {
                committed = std.mem.eql(u8, queued.text_input.event.commit, "hello");
            }
        }
    };
    Collector.touches = 0;
    Collector.committed = false;
    var sink_context: u8 = 0;
    try backend.pump(0, Collector.sink, &sink_context);
    try std.testing.expectEqual(@as(usize, 1), Collector.touches);
    try std.testing.expect(Collector.committed);
}

test "Android forwards text-input activation to its embedding hook" {
    var android = Android{
        .gpa = std.testing.allocator,
        .device = undefined,
        .context = undefined,
    };
    defer android.surfaces.deinit(std.testing.allocator);
    defer android.events.deinit(std.testing.allocator);
    const logical_surface = try android.backend().createSurface(.{ .color = color.ColorConfig.sdr(.xrgb8888) });

    const Recorder = struct {
        var enabled = false;
        fn set(_: *anyopaque, _: id.SurfaceId, state: ?text_input.State) void {
            enabled = state != null;
        }
    };
    var dummy: u8 = 0;
    android.setTextInputHandler(.{ .ctx = &dummy, .set = Recorder.set });
    try android.backend().setTextInput(logical_surface.id, .{ .content_type = .email });
    try std.testing.expect(Recorder.enabled);
    try android.backend().setTextInput(logical_surface.id, null);
    try std.testing.expect(!Recorder.enabled);
}
