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
pub const render = cells.render;

pub const Screen = @import("screen.zig").Screen;
pub const InputDecoder = @import("input.zig").InputDecoder;
pub const Terminal = @import("terminal.zig").Terminal;

/// Layout units per terminal cell. Layout stays in pixel-like units so that
/// UIs written for pixel renderers lay out sensibly in a terminal too.
pub const default_cell_size: [2]f32 = .{ 8, 16 };

/// A `zui.Config` for `Renderer`: text measured in cells, and only the
/// base commands, which are all a terminal draws. Override any other field:
/// `zui.Context(zui_terminal.config(.{ .limits = .{ .max_elements = 8192 } }))`.
pub fn config(overrides: zui.Config) zui.Config {
    comptime zui.checkRenderer(Renderer);
    var result = overrides;
    result.Text = Text;
    result.commands = .initEmpty();
    result.ImageHandle = void;
    result.CustomData = void;
    result.MaterialHandle = void;
    return result;
}

/// The renderer contract for a terminal: paints each frame into `screen`'s
/// cells and writes what changed to `output`. Its surface is `.terminal`,
/// which carries the terminal's size in cells.
///
/// ```zig
/// var renderer: zui_terminal.Renderer = .{ .gpa = gpa, .screen = &screen, .output = stdout };
/// const frame = ui.endFrame();
/// try renderer.zuiSubmit(terminal.surface(), frame);
/// ui.release(frame);
/// ```
pub const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.terminal);

    gpa: std.mem.Allocator,
    screen: *Screen,
    output: *std.Io.Writer,
    /// `Text.cell_size`.
    cell_size: [2]f32 = default_cell_size,
    /// The color of cells no command paints.
    background: zui.Color = .black,

    pub fn zuiSubmit(self: *Renderer, surface: zui.Surface, frame: anytype) !void {
        const size: [2]u16 = switch (surface) {
            .terminal => |cells_on_screen| .{ cells_on_screen.columns, cells_on_screen.rows },
            else => return error.UnsupportedSurface,
        };
        render(try self.screen.begin(self.gpa, size, self.background), self.cell_size, frame.commands());
        try self.screen.present(self.output);
    }
};

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

test "the renderer draws the base commands only, into a terminal" {
    const Ui = zui.Context(config(.{ .limits = .{ .max_elements = 8 }, .ImageHandle = u32 }));
    try std.testing.expectEqual(5, @typeInfo(Ui.RenderCommand.Payload).@"union".fields.len);
    var text: Text = .{};
    var ui = try Ui.init(std.testing.allocator, std.testing.io, &text);
    defer ui.deinit(std.testing.allocator);
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 32, 16 } } });
    ui.text("zui", .{ .color = .white });
    const frame = ui.endFrame();
    defer ui.release(frame);

    var screen: Screen = .{};
    defer screen.deinit(std.testing.allocator);
    var written: [256]u8 = undefined;
    var output: std.Io.Writer = .fixed(&written);
    var renderer: Renderer = .{ .gpa = std.testing.allocator, .screen = &screen, .output = &output };
    try std.testing.expectError(error.UnsupportedSurface, renderer.zuiSubmit(.library, frame));
    try renderer.zuiSubmit(.{ .terminal = .{ .columns = 4, .rows = 1 } }, frame);
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "zui") != null);
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
