const std = @import("std");
const zui_terminal = @import("zui_terminal");
const zui = zui_terminal.zui;
const showcase_module = @import("showcase.zig");

const Ui = zui.Context(zui_terminal.config(.{}));
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

    var text: zui_terminal.Text = .{};
    var ui = try Ui.init(init.gpa, init.io, &text);
    defer ui.deinit(init.gpa);
    var showcase = newShowcase();

    var screen: zui_terminal.Screen = .{};
    defer screen.deinit(init.gpa);
    var decoder: zui_terminal.InputDecoder = .{ .cell_size = text.cell_size };
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var renderer: zui_terminal.Renderer = .{
        .gpa = init.gpa,
        .screen = &screen,
        .output = &stdout_writer.interface,
        .cell_size = text.cell_size,
        .background = showcase.palette.background,
    };
    var read_buffer: [4096]u8 = undefined;

    while (!decoder.quit_requested) {
        const surface = terminal.surface();
        ui.beginFrame(&.{
            .params = .{ .now = terminal.now(), .viewport = viewportFor(.{ surface.terminal.columns, surface.terminal.rows }, text.cell_size) },
            .events = decoder.take(),
        });
        showcase.declare(&ui);
        const frame = ui.endFrame();
        try renderer.zuiSubmit(surface, frame);
        ui.release(frame);

        terminal.wait(ui.nextFrame());
        decoder.feed(terminal.readAvailable(&read_buffer), terminal.now());
    }
}

fn viewportFor(size: [2]u16, cell_size: [2]f32) [2]f32 {
    return .{ @as(f32, @floatFromInt(size[0])) * cell_size[0], @as(f32, @floatFromInt(size[1])) * cell_size[1] };
}

/// Renders three frames at 100×30 without a terminal, with the pointer on
/// "Hover me" so the tooltip shows, and prints the glyphs.
fn dumpFrame(init: std.process.Init) !void {
    const size: [2]u16 = .{ 100, 30 };
    var text: zui_terminal.Text = .{};
    var ui = try Ui.init(init.gpa, init.io, &text);
    defer ui.deinit(init.gpa);
    var showcase = newShowcase();
    var cells: zui_terminal.CellBuffer = .{};
    defer cells.deinit(init.gpa);
    try cells.resize(init.gpa, size[0], size[1]);

    var sampler: zui.InputSampler = .{};
    for (0..3) |frame_index| {
        const now: zui.Instant = .fromNanoseconds(frame_index * std.time.ns_per_s / 60);
        const hover_target = if (ui.rectOf(Showcase.ids.hover_me)) |rect| [2]f32{ rect.x + rect.width / 2, rect.y + rect.height / 2 } else null;
        var events: [4]zui.Event = undefined;
        ui.beginFrame(&.{
            .params = .{ .now = now, .viewport = viewportFor(size, text.cell_size) },
            .events = sampler.sample(now, .{ .pointer = hover_target }, &events),
        });
        showcase.declare(&ui);
        const frame = ui.endFrame();
        defer ui.release(frame);
        cells.fill(.{ .foreground = showcase.palette.background, .background = showcase.palette.background });
        zui_terminal.render(&cells, text.cell_size, frame.commands());
    }

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try cells.writeGlyphs(&stdout_writer.interface);
    try stdout_writer.interface.flush();
}
