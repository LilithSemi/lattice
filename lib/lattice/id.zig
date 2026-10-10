const std = @import("std");

pub const SurfaceId = enum(u32) {
    _,
    pub fn from(v: u32) SurfaceId {
        return @fromBackingInt(@intCast(v));
    }
    pub fn value(self: SurfaceId) u32 {
        return @backingInt(self);
    }
};

pub const OutputId = enum(u32) {
    _,
    pub fn from(v: u32) OutputId {
        return @fromBackingInt(@intCast(v));
    }
    pub fn value(self: OutputId) u32 {
        return @backingInt(self);
    }
};

test "ids round-trip" {
    try std.testing.expectEqual(@as(u32, 7), SurfaceId.from(7).value());
    try std.testing.expectEqual(@as(u32, 3), OutputId.from(3).value());
    try std.testing.expect(SurfaceId.from(1) != SurfaceId.from(2));
}
