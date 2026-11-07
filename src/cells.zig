const std = @import("std");
const zui = @import("zui");

pub const Cell = struct {
    codepoint: u21 = ' ',
    foreground: zui.Color = .white,
    background: zui.Color = .black,

    pub fn eql(self: Cell, other: Cell) bool {
        return self.codepoint == other.codepoint and self.foreground.eql(other.foreground) and self.background.eql(other.background);
    }

    fn isBlankOrBoxDrawing(self: Cell) bool {
        return self.codepoint == ' ' or (self.codepoint >= 0x2500 and self.codepoint <= 0x257F);
    }
};

/// A half-open range of cells: `left..right` columns, `top..bottom` rows.
pub const CellRect = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    /// A cell is covered when its center lies inside `rect`.
    pub fn fromLayout(rect: zui.Rect, cell_size: [2]f32) CellRect {
        return .{
            .left = roundToCell(rect.x / cell_size[0]),
            .top = roundToCell(rect.y / cell_size[1]),
            .right = roundToCell((rect.x + rect.width) / cell_size[0]),
            .bottom = roundToCell((rect.y + rect.height) / cell_size[1]),
        };
    }

    pub fn intersect(self: CellRect, other: CellRect) CellRect {
        return .{
            .left = @max(self.left, other.left),
            .top = @max(self.top, other.top),
            .right = @min(self.right, other.right),
            .bottom = @min(self.bottom, other.bottom),
        };
    }

    pub fn isEmpty(self: CellRect) bool {
        return self.right <= self.left or self.bottom <= self.top;
    }

    pub fn contains(self: CellRect, column: i32, row: i32) bool {
        return column >= self.left and column < self.right and row >= self.top and row < self.bottom;
    }
};

fn roundToCell(value: f32) i32 {
    const limit: f32 = std.math.maxInt(i16);
    return @intFromFloat(@round(std.math.clamp(value, -limit, limit)));
}

pub const CellBuffer = struct {
    columns: u16 = 0,
    rows: u16 = 0,
    cells: []Cell = &.{},

    pub fn deinit(self: *CellBuffer, gpa: std.mem.Allocator) void {
        gpa.free(self.cells);
        self.* = .{};
    }

    pub fn resize(self: *CellBuffer, gpa: std.mem.Allocator, columns: u16, rows: u16) !void {
        const count = @as(usize, columns) * rows;
        if (count != self.cells.len) self.cells = try gpa.realloc(self.cells, count);
        self.columns = columns;
        self.rows = rows;
    }

    pub fn fill(self: *CellBuffer, cell: Cell) void {
        @memset(self.cells, cell);
    }

    pub fn bounds(self: *const CellBuffer) CellRect {
        return .{ .right = self.columns, .bottom = self.rows };
    }

    /// `column` and `row` must lie inside `bounds()`.
    pub fn at(self: *CellBuffer, column: i32, row: i32) *Cell {
        return &self.cells[@as(usize, @intCast(row)) * self.columns + @as(usize, @intCast(column))];
    }

    /// The glyphs alone, one line per row, for snapshots and logs.
    pub fn writeGlyphs(self: *const CellBuffer, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (0..self.rows) |row| {
            for (self.cells[row * self.columns ..][0..self.columns]) |cell| {
                var bytes: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(cell.codepoint, &bytes) catch {
                    try writer.writeByte('?');
                    continue;
                };
                try writer.writeAll(bytes[0..length]);
            }
            try writer.writeByte('\n');
        }
    }
};

/// Paints one frame's commands into `buffer`, in order. Present the buffer
/// with `Screen.present`. A terminal draws only the base commands, so this
/// `switch` names those five and nothing else.
pub fn render(buffer: *CellBuffer, cell_size: [2]f32, commands: anytype) void {
    var clips: ClipStack = .{ .whole_buffer = buffer.bounds() };
    for (commands) |command| {
        const area = CellRect.fromLayout(command.bounds, cell_size);
        switch (command.payload) {
            .rectangle => |rectangle| fillRectangle(buffer, area.intersect(clips.current()), rectangle.color),
            .border => |border| drawBorder(buffer, area, clips.current(), border.color, border.widths, border.corner_radius),
            .text => |text| drawText(buffer, area, clips.current(), text.content, text.style.color, (cell_size[0] + text.style.letter_spacing) / cell_size[0]),
            .clip_begin => |clip| clips.push(CellRect.fromLayout(clip, cell_size)),
            .clip_end => clips.pop(),
        }
    }
}

fn blend(below: zui.Color, above: zui.Color) zui.Color {
    if (above.a == 255) return above;
    return below.mix(.{ .r = above.r, .g = above.g, .b = above.b }, @as(f32, @floatFromInt(above.a)) / 255);
}

fn fillRectangle(buffer: *CellBuffer, area: CellRect, color: zui.Color) void {
    if (area.isEmpty()) return;
    var row = area.top;
    while (row < area.bottom) : (row += 1) {
        var column = area.left;
        while (column < area.right) : (column += 1) {
            const cell = buffer.at(column, row);
            cell.background = blend(cell.background, color);
            if (color.a == 255) {
                cell.codepoint = ' ';
            } else {
                cell.foreground = blend(cell.foreground, color);
            }
        }
    }
}

const BoxGlyphs = struct {
    horizontal: u21 = '─',
    vertical: u21 = '│',
    top_left: u21,
    top_right: u21,
    bottom_left: u21,
    bottom_right: u21,

    const square: BoxGlyphs = .{ .top_left = '┌', .top_right = '┐', .bottom_left = '└', .bottom_right = '┘' };
    const rounded: BoxGlyphs = .{ .top_left = '╭', .top_right = '╮', .bottom_left = '╰', .bottom_right = '╯' };
};

/// zui emits borders after their element's children, so a border that
/// overwrote glyphs would hide the content it surrounds. Border glyphs only
/// go where the cell is blank or already holds box drawing.
fn drawBorder(buffer: *CellBuffer, area: CellRect, clip: CellRect, color: zui.Color, widths: zui.Edges, radius: zui.CornerRadius) void {
    if (area.isEmpty()) return;
    const is_rounded = radius.top_left > 0 or radius.top_right > 0 or radius.bottom_left > 0 or radius.bottom_right > 0;
    const glyphs: BoxGlyphs = if (is_rounded) .rounded else .square;
    const last_column = area.right - 1;
    const last_row = area.bottom - 1;
    const has_top = widths.top > 0;
    const has_bottom = widths.bottom > 0;
    const has_left = widths.left > 0;
    const has_right = widths.right > 0;

    const is_single_row = area.bottom - area.top == 1;
    if (is_single_row) {
        if (has_left) putBorderGlyph(buffer, clip, area.left, area.top, '[', color);
        if (has_right) putBorderGlyph(buffer, clip, last_column, area.top, ']', color);
        return;
    }

    var column = area.left;
    while (column <= last_column) : (column += 1) {
        if (has_top) putBorderGlyph(buffer, clip, column, area.top, glyphs.horizontal, color);
        if (has_bottom) putBorderGlyph(buffer, clip, column, last_row, glyphs.horizontal, color);
    }
    var row = area.top;
    while (row <= last_row) : (row += 1) {
        if (has_left) putBorderGlyph(buffer, clip, area.left, row, glyphs.vertical, color);
        if (has_right) putBorderGlyph(buffer, clip, last_column, row, glyphs.vertical, color);
    }
    if (has_top and has_left) putBorderGlyph(buffer, clip, area.left, area.top, glyphs.top_left, color);
    if (has_top and has_right) putBorderGlyph(buffer, clip, last_column, area.top, glyphs.top_right, color);
    if (has_bottom and has_left) putBorderGlyph(buffer, clip, area.left, last_row, glyphs.bottom_left, color);
    if (has_bottom and has_right) putBorderGlyph(buffer, clip, last_column, last_row, glyphs.bottom_right, color);
}

fn putBorderGlyph(buffer: *CellBuffer, clip: CellRect, column: i32, row: i32, glyph: u21, color: zui.Color) void {
    if (!clip.contains(column, row)) return;
    const cell = buffer.at(column, row);
    if (!cell.isBlankOrBoxDrawing()) return;
    cell.codepoint = glyph;
    cell.foreground = blend(cell.background, color);
}

/// zui wraps text itself and emits one command per line, so a line starts
/// at its bounds and never needs wrapping here. Letter spacing moves each
/// glyph to the cell nearest where it would start.
fn drawText(buffer: *CellBuffer, area: CellRect, clip: CellRect, content: []const u8, color: zui.Color, glyph_pitch_in_cells: f32) void {
    const row = area.top;
    var glyph_index: usize = 0;
    var codepoints = (std.unicode.Utf8View.init(content) catch return drawInvalidUtf8(buffer, area, clip, content.len, color, glyph_pitch_in_cells)).iterator();
    while (codepoints.nextCodepoint()) |codepoint| : (glyph_index += 1) {
        const column = glyphColumn(area, glyph_index, glyph_pitch_in_cells);
        if (column >= clip.right) return;
        if (!clip.contains(column, row)) continue;
        const cell = buffer.at(column, row);
        cell.codepoint = if (codepoint < 0x20 or codepoint == 0x7F) ' ' else codepoint;
        cell.foreground = blend(cell.background, color);
    }
}

fn drawInvalidUtf8(buffer: *CellBuffer, area: CellRect, clip: CellRect, length: usize, color: zui.Color, glyph_pitch_in_cells: f32) void {
    for (0..length) |glyph_index| {
        const column = glyphColumn(area, glyph_index, glyph_pitch_in_cells);
        if (clip.contains(column, area.top)) {
            const cell = buffer.at(column, area.top);
            cell.codepoint = std.unicode.replacement_character;
            cell.foreground = blend(cell.background, color);
        }
    }
}

fn glyphColumn(area: CellRect, glyph_index: usize, glyph_pitch_in_cells: f32) i32 {
    return area.left + roundToCell(@as(f32, @floatFromInt(glyph_index)) * glyph_pitch_in_cells);
}

/// zui's clip rectangles are already intersected with every enclosing clip,
/// so `clip_end` only has to restore the enclosing one.
const ClipStack = struct {
    whole_buffer: CellRect,
    rects: [64]CellRect = undefined,
    depth: usize = 0,
    overflow: usize = 0,

    fn current(self: *const ClipStack) CellRect {
        return if (self.depth == 0) self.whole_buffer else self.rects[self.depth - 1];
    }

    fn push(self: *ClipStack, rect: CellRect) void {
        if (self.depth == self.rects.len) {
            self.overflow += 1;
            return;
        }
        self.rects[self.depth] = rect.intersect(self.whole_buffer);
        self.depth += 1;
    }

    fn pop(self: *ClipStack) void {
        if (self.overflow > 0) {
            self.overflow -= 1;
        } else if (self.depth > 0) {
            self.depth -= 1;
        }
    }
};

const testing = std.testing;
const TestUi = zui.Context(.{ .Text = @import("zui_testing").FixedMetricsText(u16) });
const TestCommand = TestUi.RenderCommand;

fn testBuffer(columns: u16, rows: u16) !CellBuffer {
    var buffer: CellBuffer = .{};
    try buffer.resize(testing.allocator, columns, rows);
    buffer.fill(.{});
    return buffer;
}

fn rowText(buffer: *CellBuffer, row: i32, output: []u8) []const u8 {
    var length: usize = 0;
    for (0..buffer.columns) |column| {
        length += std.unicode.utf8Encode(buffer.at(@intCast(column), row).codepoint, output[length..]) catch unreachable;
    }
    return output[0..length];
}

test "a cell is covered when its center is inside the rect" {
    const area = CellRect.fromLayout(.{ .x = 3, .y = 9, .width = 18, .height = 30 }, .{ 8, 16 });
    try testing.expectEqual(CellRect{ .left = 0, .top = 1, .right = 3, .bottom = 2 }, area);
}

test "text is clipped and borders do not overwrite it" {
    var buffer = try testBuffer(10, 3);
    defer buffer.deinit(testing.allocator);
    const commands = [_]TestCommand{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 80, .height = 48 }, .id = 0, .z = 0, .payload = .{ .clip_begin = .{ .x = 0, .y = 0, .width = 48, .height = 48 } } },
        .{ .bounds = .{ .x = 8, .y = 16, .width = 64, .height = 16 }, .id = 0, .z = 0, .payload = .{ .text = .{ .content = "clipped!", .style = .{}, .line = 0 } } },
        .{ .bounds = .{}, .id = 0, .z = 0, .payload = .clip_end },
        .{ .bounds = .{ .x = 0, .y = 0, .width = 80, .height = 48 }, .id = 0, .z = 0, .payload = .{ .border = .{ .color = .white, .widths = .all(1), .corner_radius = .zero } } },
    };
    render(&buffer, .{ 8, 16 }, &commands);
    var output: [64]u8 = undefined;
    try testing.expectEqualStrings("┌────────┐", rowText(&buffer, 0, &output));
    try testing.expectEqualStrings("│clipp   │", rowText(&buffer, 1, &output));
    try testing.expectEqualStrings("└────────┘", rowText(&buffer, 2, &output));
}

test "a one-row border becomes brackets" {
    var buffer = try testBuffer(4, 1);
    defer buffer.deinit(testing.allocator);
    const commands = [_]TestCommand{
        .{ .bounds = .{ .width = 32, .height = 16 }, .id = 0, .z = 0, .payload = .{ .border = .{ .color = .white, .widths = .all(1), .corner_radius = .zero } } },
    };
    render(&buffer, .{ 8, 16 }, &commands);
    var output: [16]u8 = undefined;
    try testing.expectEqualStrings("[  ]", rowText(&buffer, 0, &output));
}

test "translucent rectangles blend over what is below" {
    var buffer = try testBuffer(2, 1);
    defer buffer.deinit(testing.allocator);
    const commands = [_]TestCommand{
        .{ .bounds = .{ .width = 16, .height = 16 }, .id = 0, .z = 0, .payload = .{ .rectangle = .{ .color = .white, .corner_radius = .zero } } },
        .{ .bounds = .{ .width = 8, .height = 16 }, .id = 0, .z = 0, .payload = .{ .rectangle = .{ .color = .rgba(0x00000080), .corner_radius = .zero } } },
    };
    render(&buffer, .{ 8, 16 }, &commands);
    try testing.expect(buffer.at(0, 0).background.r < 200);
    try testing.expectEqual(@as(u8, 255), buffer.at(1, 0).background.r);
}

test "letter spacing spreads glyphs over the cells it covers" {
    var buffer = try testBuffer(6, 1);
    defer buffer.deinit(testing.allocator);
    const commands = [_]TestCommand{
        .{ .bounds = .{ .width = 48, .height = 16 }, .id = 0, .z = 0, .payload = .{ .text = .{ .content = "abc", .style = .{ .letter_spacing = 8 }, .line = 0 } } },
    };
    render(&buffer, .{ 8, 16 }, &commands);
    var output: [16]u8 = undefined;
    try testing.expectEqualStrings("a b c ", rowText(&buffer, 0, &output));
}
