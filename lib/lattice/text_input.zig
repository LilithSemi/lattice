//! Platform-neutral virtual keyboard and input-method contract.
//!
//! Text is UTF-8 and all ranges and deletion counts are byte based. A backend
//! translates its platform's native indexing convention at the boundary.
const id = @import("id.zig");

pub const Range = struct {
    start: u32 = 0,
    end: u32 = 0,
};

pub const ContentType = enum {
    text,
    multiline,
    email,
    url,
    number,
    phone,
    password,
};

pub const Capitalization = enum { none, sentences, words, characters };
pub const Action = enum { none, done, go, next, previous, search, send };

/// State supplied by an application when enabling an input method. All slices
/// are borrowed for the duration of `setTextInput` only.
pub const State = struct {
    surrounding_text: []const u8 = "",
    selection: Range = .{},
    composing: ?Range = null,
    content_type: ContentType = .text,
    capitalization: Capitalization = .sentences,
    action: Action = .none,
    autocorrect: bool = true,
};

pub const Preedit = struct {
    text: []const u8,
    selection: ?Range = null,
};

pub const DeleteSurrounding = struct {
    before_bytes: u32,
    after_bytes: u32,
};

/// Input-method events borrow backend storage and are valid only for the event
/// callback. `commit` is final text; `preedit` is replaceable composition text.
pub const Event = union(enum) {
    commit: []const u8,
    preedit: Preedit,
    finish_preedit: void,
    delete_surrounding: DeleteSurrounding,
    action: Action,
};

pub const SurfaceEvent = struct {
    surface: id.SurfaceId,
    event: Event,
};
