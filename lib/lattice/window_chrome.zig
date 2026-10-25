const id = @import("id.zig");

pub const DecorationMode = enum(u32) {
    client_side = 1,
    server_side = 2,
};

pub const ResizeEdge = enum(u32) {
    top = 1,
    bottom = 2,
    left = 4,
    top_left = 5,
    bottom_left = 6,
    right = 8,
    top_right = 9,
    bottom_right = 10,
};

pub const WindowState = packed struct {
    maximized: bool = false,
    fullscreen: bool = false,
    resizing: bool = false,
    activated: bool = false,
    tiled_left: bool = false,
    tiled_right: bool = false,
    tiled_top: bool = false,
    tiled_bottom: bool = false,
};

/// The window state that takes effect with a compositor configuration.
pub const Configure = struct {
    surface: id.SurfaceId,
    width: u32,
    height: u32,
    decoration_mode: DecorationMode,
    state: WindowState,
};

pub const Position = struct {
    x: i32,
    y: i32,
};

pub const Size = struct {
    width: u32,
    height: u32,
};

pub const Command = union(enum) {
    set_title: []const u8,
    set_app_id: []const u8,
    set_decoration_mode: DecorationMode,
    move: void,
    resize: ResizeEdge,
    set_maximized: bool,
    minimize: void,
    set_fullscreen: bool,
    show_window_menu: Position,
    set_min_size: Size,
    set_max_size: Size,
};
