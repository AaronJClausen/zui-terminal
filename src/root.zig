const std = @import("std");

/// The zui this backend is built against; import it from here so the
/// application and the backend always agree on zui's types.
pub const zui = @import("zui");
pub const zui_widgets = @import("zui_widgets");
pub const zui_reflect = @import("zui_reflect");

const cells = @import("cells.zig");
pub const Cell = cells.Cell;
pub const CellBuffer = cells.CellBuffer;
pub const CellRect = cells.CellRect;
pub const RenderOptions = cells.RenderOptions;
pub const render = cells.render;

pub const Screen = @import("screen.zig").Screen;
pub const InputDecoder = @import("input.zig").InputDecoder;

const terminal = @import("terminal.zig");
pub const Terminal = terminal.Terminal;
pub const Waker = terminal.Waker;

/// Layout units per terminal cell. Layout stays in pixel-like units so that
/// UIs written for pixel renderers lay out sensibly in a terminal too.
pub const default_cell_size: [2]f32 = .{ 8, 16 };

/// Every glyph is one cell wide and one cell tall, whatever the font or
/// size: a terminal has one font, at one size.
pub const Platform = struct {
    cell_size: [2]f32 = default_cell_size,
    waker: ?*const Waker = null,

    pub fn measureText(self: *Platform, text: []const u8, _: u16, _: f32) [2]f32 {
        return .{ @as(f32, @floatFromInt(codepointCount(text))) * self.cell_size[0], self.cell_size[1] };
    }

    pub fn wake(self: *Platform) void {
        if (self.waker) |waker| waker.wake();
    }
};

pub fn codepointCount(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        const is_continuation_byte = byte & 0xC0 == 0x80;
        if (!is_continuation_byte) count += 1;
    }
    return count;
}

test "measurement is additive and ignores the font size" {
    var platform: Platform = .{};
    const one = platform.measureText("one", 0, 16);
    const space = platform.measureText(" ", 0, 16);
    const two = platform.measureText("two", 0, 40);
    try std.testing.expectEqual(platform.measureText("one two", 0, 16)[0], one[0] + space[0] + two[0]);
    try std.testing.expectEqual(@as(f32, 16), two[1]);
}

test "measurement counts code points, not bytes" {
    var platform: Platform = .{};
    try std.testing.expectEqual(@as(f32, 4 * 8), platform.measureText("café", 0, 16)[0]);
}

test {
    std.testing.refAllDecls(@This());
    _ = cells;
    _ = @import("screen.zig");
    _ = @import("input.zig");
}
