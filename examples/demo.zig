const std = @import("std");
const zui_terminal = @import("zui_terminal");
const zui = zui_terminal.zui;
const showcase_module = @import("showcase.zig");

const Ui = zui.Context(.{}, zui_terminal.Platform);
const Showcase = showcase_module.Showcase(Ui);

/// One cell is 8×16 layout units, so these keep controls on whole cells.
const metrics: showcase_module.Metrics = .{
    .toolbar_height = 48,
    .sidebar_width = 160,
    .row_height = 16,
    .padding = 16,
    .gap = 16,
    .dialog_width = 400,
    .corner_radius = 1,
};

fn newShowcase() Showcase {
    return .{
        .title = "zui + terminal",
        .metrics = metrics,
        .widgets = .{ .theme = .{
            .corner_radius = 0,
            .control_height = 16,
            .horizontal_padding = 8,
            .gap = 8,
            .checkbox_size = 16,
            .slider_thumb_size = .{ 8, 16 },
            .track_thickness = 16,
            .label_width = 112,
        } },
    };
}

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    for (arguments[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--dump")) return dumpFrame(init);
        std.debug.print("unknown argument \"{s}\"; expected --dump\n", .{argument});
        return error.UnknownArgument;
    }

    var terminal = try zui_terminal.Terminal.enter(init.io);
    defer terminal.leave();

    var platform: zui_terminal.Platform = .{ .waker = &terminal.waker };
    var ui = try Ui.init(init.gpa, init.io, &platform);
    defer ui.deinit(init.gpa);
    var showcase = newShowcase();

    var screen: zui_terminal.Screen = .{};
    defer screen.deinit(init.gpa);
    var decoder: zui_terminal.InputDecoder = .{ .cell_size = platform.cell_size };
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var read_buffer: [4096]u8 = undefined;
    var previous_frame_start = std.Io.Timestamp.now(init.io, .awake);

    while (!decoder.quit_requested) {
        const frame_start = std.Io.Timestamp.now(init.io, .awake);
        const dt_seconds: f32 = @floatCast(@as(f64, @floatFromInt(previous_frame_start.durationTo(frame_start).nanoseconds)) / std.time.ns_per_s);
        previous_frame_start = frame_start;

        const size = terminal.size();
        ui.beginFrame(decoder.take(viewportFor(size, platform.cell_size), dt_seconds));
        showcase.declare(&ui);
        const frame = ui.endFrame() catch ui.lastFrame();
        defer ui.release(frame);

        const cells = try screen.begin(init.gpa, size, showcase.palette.background);
        zui_terminal.render(Ui.RenderCommand, cells, platform.cell_size, frame.commands(), .{});
        try screen.present(&stdout_writer.interface);

        terminal.waitForInput(if (ui.needsFrame() or decoder.hasUndeliveredInput()) .next_frame else .idle);
        decoder.feed(terminal.readAvailable(&read_buffer));
    }
}

fn viewportFor(size: [2]u16, cell_size: [2]f32) [2]f32 {
    return .{ @as(f32, @floatFromInt(size[0])) * cell_size[0], @as(f32, @floatFromInt(size[1])) * cell_size[1] };
}

/// Renders three frames at 100×30 without a terminal, with the pointer on
/// "Hover me" so the tooltip shows, and prints the glyphs.
fn dumpFrame(init: std.process.Init) !void {
    const size: [2]u16 = .{ 100, 30 };
    var platform: zui_terminal.Platform = .{};
    var ui = try Ui.init(init.gpa, init.io, &platform);
    defer ui.deinit(init.gpa);
    var showcase = newShowcase();
    var cells: zui_terminal.CellBuffer = .{};
    defer cells.deinit(init.gpa);
    try cells.resize(init.gpa, size[0], size[1]);

    for (0..3) |_| {
        const hover_target = if (ui.rectOf(Showcase.ids.hover_me)) |rect| [2]f32{ rect.x + rect.width / 2, rect.y + rect.height / 2 } else null;
        ui.beginFrame(.{ .viewport = viewportFor(size, platform.cell_size), .pointer = hover_target });
        showcase.declare(&ui);
        const frame = ui.endFrame() catch ui.lastFrame();
        defer ui.release(frame);
        cells.fill(.{ .foreground = showcase.palette.background, .background = showcase.palette.background });
        zui_terminal.render(Ui.RenderCommand, &cells, platform.cell_size, frame.commands(), .{});
    }

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try cells.writeGlyphs(&stdout_writer.interface);
    try stdout_writer.interface.flush();
}
