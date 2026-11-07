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
pub const Terminal = @import("terminal.zig").Terminal;

/// Layout units per terminal cell. Layout stays in pixel-like units so that
/// UIs written for pixel renderers lay out sensibly in a terminal too.
pub const default_cell_size: [2]f32 = .{ 8, 16 };

/// A `zui.Config` measuring text in cells; override any field:
/// `zui.Context(zui_terminal.config(.{ .limits = .{ .max_elements = 8192 } }))`.
pub fn config(overrides: zui.Config) zui.Config {
    var result = overrides;
    result.Text = Text;
    return result;
}

/// The text contract of a terminal, which has one font at one size: every
/// code point is one cell wide, plus the letter spacing after it, and one
/// cell tall.
pub const Text = struct {
    cell_size: [2]f32 = default_cell_size,

    pub fn zuiMeasure(self: *Text, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(codepointCount(run))) * (self.cell_size[0] + key.letter_spacing), self.cell_size[1] };
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

fn measure(text: *Text, run: []const u8, size: f32, letter_spacing: f32) [2]f32 {
    return text.zuiMeasure(run, .{ .font = 0, .size = size, .letter_spacing = letter_spacing });
}

test "measurement is additive and ignores the font size" {
    var text: Text = .{};
    const one = measure(&text, "one", 16, 0);
    const space = measure(&text, " ", 16, 0);
    const two = measure(&text, "two", 40, 0);
    try std.testing.expectEqual(measure(&text, "one two", 16, 0)[0], one[0] + space[0] + two[0]);
    try std.testing.expectEqual(@as(f32, 16), two[1]);
}

test "letter spacing follows every code point, so measurement stays additive" {
    var text: Text = .{};
    try std.testing.expectEqual(@as(f32, 4 * 8), measure(&text, "café", 16, 0)[0]);
    try std.testing.expectEqual(@as(f32, 4 * 16), measure(&text, "café", 16, 8)[0]);
    try std.testing.expectEqual(measure(&text, "ab", 16, 8)[0], measure(&text, "a", 16, 8)[0] + measure(&text, "b", 16, 8)[0]);
}

test {
    std.testing.refAllDecls(@This());
    _ = cells;
    _ = @import("screen.zig");
    _ = @import("input.zig");
    _ = @import("terminal.zig");
}
