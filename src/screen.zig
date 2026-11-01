const std = @import("std");
const zui = @import("zui");
const cells = @import("cells.zig");
const Cell = cells.Cell;
const CellBuffer = cells.CellBuffer;

/// Alternate screen, hidden cursor, no autowrap (so the bottom-right cell
/// can be written without scrolling), and SGR mouse reports for every motion.
pub const enter_sequence = "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?1003h\x1b[?1006h";
pub const leave_sequence = "\x1b[?1006l\x1b[?1003l\x1b[?7h\x1b[0m\x1b[?25h\x1b[?1049l";
const begin_synchronized_update = "\x1b[?2026h";
const end_synchronized_update = "\x1b[?2026l";

/// Double-buffered cells. Each `present` writes only the cells that changed
/// since the previous one.
pub const Screen = struct {
    back: CellBuffer = .{},
    front: CellBuffer = .{},
    needs_full_redraw: bool = true,

    pub fn deinit(self: *Screen, gpa: std.mem.Allocator) void {
        self.back.deinit(gpa);
        self.front.deinit(gpa);
    }

    /// The buffer to render the next frame into, cleared to `background`.
    pub fn begin(self: *Screen, gpa: std.mem.Allocator, size: [2]u16, background: zui.Color) !*CellBuffer {
        if (size[0] != self.back.columns or size[1] != self.back.rows) {
            try self.back.resize(gpa, size[0], size[1]);
            try self.front.resize(gpa, size[0], size[1]);
            self.needs_full_redraw = true;
        }
        self.back.fill(.{ .foreground = background, .background = background });
        return &self.back;
    }

    pub fn present(self: *Screen, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(begin_synchronized_update);
        var cursor: ?[2]usize = null;
        var foreground: ?zui.Color = null;
        var background: ?zui.Color = null;
        for (0..self.back.rows) |row| {
            for (0..self.back.columns) |column| {
                const index = row * self.back.columns + column;
                const cell = self.back.cells[index];
                if (!self.needs_full_redraw and cell.eql(self.front.cells[index])) continue;

                if (cursor == null or cursor.?[0] != column or cursor.?[1] != row) try writer.print("\x1b[{d};{d}H", .{ row + 1, column + 1 });
                if (foreground == null or !foreground.?.eql(cell.foreground)) try writer.print("\x1b[38;2;{d};{d};{d}m", .{ cell.foreground.r, cell.foreground.g, cell.foreground.b });
                if (background == null or !background.?.eql(cell.background)) try writer.print("\x1b[48;2;{d};{d};{d}m", .{ cell.background.r, cell.background.g, cell.background.b });
                try writeCodepoint(writer, cell.codepoint);
                cursor = .{ column + 1, row };
                foreground = cell.foreground;
                background = cell.background;
            }
        }
        try writer.writeAll(end_synchronized_update);
        try writer.flush();
        @memcpy(self.front.cells, self.back.cells);
        self.needs_full_redraw = false;
    }
};

fn writeCodepoint(writer: *std.Io.Writer, codepoint: u21) std.Io.Writer.Error!void {
    var bytes: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &bytes) catch return writer.writeByte('?');
    try writer.writeAll(bytes[0..length]);
}

test "only changed cells are written after the first present" {
    var screen: Screen = .{};
    defer screen.deinit(std.testing.allocator);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    _ = try screen.begin(std.testing.allocator, .{ 3, 1 }, .black);
    try screen.present(&output.writer);
    output.clearRetainingCapacity();

    const buffer = try screen.begin(std.testing.allocator, .{ 3, 1 }, .black);
    buffer.at(2, 0).codepoint = 'x';
    try screen.present(&output.writer);
    try std.testing.expectEqualStrings(begin_synchronized_update ++ "\x1b[1;3H\x1b[38;2;0;0;0m\x1b[48;2;0;0;0mx" ++ end_synchronized_update, output.written());
}
