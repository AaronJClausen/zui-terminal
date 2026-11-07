const std = @import("std");
const zui_terminal = @import("zui_terminal");
const zui = zui_terminal.zui;
const zui_testing = @import("zui_testing");

/// Draws into a `Screen` it never shows, and reads each pixel back as the
/// cell that covers it: a cell holding a glyph shows its foreground, an
/// empty one its background.
const ScreenHarness = struct {
    pub const config = zui_terminal.config(.{});

    screen: zui_terminal.Screen = .{},
    discarded: std.Io.Writer.Discarding,
    drawn: zui_terminal.Renderer,
    text_contract: zui_terminal.Text = .{},

    fn init(self: *ScreenHarness, gpa: std.mem.Allocator, buffer: []u8) void {
        self.* = .{ .discarded = .init(buffer), .drawn = undefined };
        self.drawn = .{ .gpa = gpa, .screen = &self.screen, .output = &self.discarded.writer };
    }

    fn deinit(self: *ScreenHarness, gpa: std.mem.Allocator) void {
        self.screen.deinit(gpa);
    }

    pub fn renderer(self: *ScreenHarness) *zui_terminal.Renderer {
        return &self.drawn;
    }

    pub fn text(self: *ScreenHarness) *zui_terminal.Text {
        return &self.text_contract;
    }

    pub fn beginDraw(self: *ScreenHarness, size: [2]u32) zui.Surface {
        const cell_size = self.drawn.cell_size;
        return .{ .terminal = .{
            .columns = @intFromFloat(@as(f32, @floatFromInt(size[0])) / cell_size[0]),
            .rows = @intFromFloat(@as(f32, @floatFromInt(size[1])) / cell_size[1]),
        } };
    }

    pub fn pixel(self: *ScreenHarness, x: u32, y: u32) zui.Color {
        const cell_size = self.drawn.cell_size;
        const column: i32 = @intFromFloat(@as(f32, @floatFromInt(x)) / cell_size[0]);
        const row: i32 = @intFromFloat(@as(f32, @floatFromInt(y)) / cell_size[1]);
        const cell = self.screen.back.at(column, row);
        return if (cell.codepoint == ' ') cell.background else cell.foreground;
    }
};

test "the renderer passes zui's renderer suite" {
    var discard_buffer: [256]u8 = undefined;
    var harness: ScreenHarness = undefined;
    harness.init(std.testing.allocator, &discard_buffer);
    defer harness.deinit(std.testing.allocator);
    try zui_testing.expectRendererConforms(zui_terminal.Renderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io, .tolerance = 0 });
}
