//! A renderer-agnostic UI shared by the backends' demos, so the same frame
//! can be compared across renderers. Keep this file identical in every
//! backend repository until it moves into a shared package.

const std = @import("std");
const zui = @import("zui");
const zui_widgets = @import("zui_widgets");

pub const Palette = struct {
    background: zui.Color = .rgb(0x16161c),
    panel: zui.Color = .rgb(0x20202a),
    sidebar: zui.Color = .rgb(0x1a1a22),
    text: zui.Color = .rgb(0xe8e8f0),
    muted_text: zui.Color = .rgb(0x9a9aae),
    accent: zui.Color = .rgb(0x5b8cff),
    border: zui.Color = .rgb(0x34344a),
    highlight: zui.Color = .rgb(0xffc65c),
    hovered_row: zui.Color = .rgb(0x3a3a50),
    overlay: zui.Color = .rgba(0x00000099),
};

/// Sizes in layout units. A pixel renderer and a cell renderer need
/// different values for the same UI to read well.
pub const Metrics = struct {
    toolbar_height: f32 = 56,
    sidebar_width: f32 = 260,
    row_height: f32 = 36,
    padding: f32 = 16,
    gap: f32 = 12,
    title_size: f32 = 32,
    body_size: f32 = 18,
    dialog_width: f32 = 420,
    corner_radius: f32 = 6,
};

pub fn Showcase(comptime Ui: type) type {
    return struct {
        const Self = @This();

        pub const ids = zui.ids(.{ "toolbar", "new", "open", "save", "about", "sidebar", "content", "tooltips", "volume", "hover_me", "dialog_close" });

        title: []const u8,
        palette: Palette = .{},
        metrics: Metrics = .{},
        widgets: zui_widgets.Widgets(Ui),

        clicks: u32 = 0,
        last_action: []const u8 = "nothing yet",
        selected_row: ?usize = 2,
        show_tooltips: bool = true,
        volume: f32 = 0.6,
        about_open: bool = false,

        pub fn declare(self: *Self, ui: *Ui) void {
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both }, .background = self.palette.background });
            defer ui.close();
            self.toolbar(ui);
            {
                ui.open(.{ .layout = .{ .sizing = .grow_both } });
                defer ui.close();
                self.sidebar(ui);
                self.mainPanel(ui);
            }
            self.aboutDialog(ui);
        }

        fn body(self: *const Self, ui: *Ui, content: []const u8, color: zui.Color) void {
            ui.text(content, .{ .size = self.metrics.body_size, .color = color });
        }

        fn toolbar(self: *Self, ui: *Ui) void {
            ui.open(.{
                .id = ids.toolbar,
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(self.metrics.toolbar_height) }, .padding = .symmetric(self.metrics.padding, 0), .child_gap = self.metrics.gap, .child_alignment = .{ .y = .center } },
                .background = self.palette.panel,
                .border = .{ .color = self.palette.border, .widths = .{ .bottom = 1 } },
            });
            defer ui.close();

            const actions = .{ .{ ids.new, "New" }, .{ ids.open, "Open" }, .{ ids.save, "Save" } };
            inline for (actions) |action| {
                if (self.widgets.button(ui, action[0], action[1], .{})) {
                    self.clicks += 1;
                    self.last_action = action[1];
                }
            }
            ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
            if (self.widgets.button(ui, ids.about, "About", .{})) self.about_open = true;
        }

        fn sidebar(self: *Self, ui: *Ui) void {
            ui.open(.{
                .id = ids.sidebar,
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(self.metrics.sidebar_width), .height = .grow } },
                .background = self.palette.sidebar,
                .scroll = .{},
            });
            defer ui.close();

            var name_buffer: [32]u8 = undefined;
            for (0..40) |index| {
                const id: zui.Id = .indexed("row", index);
                const state = ui.widgetState(id);
                ui.open(.{
                    .id = id,
                    .focusable = true,
                    .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(self.metrics.row_height) }, .padding = .symmetric(self.metrics.padding, 0), .child_alignment = .{ .y = .center } },
                    .background = if (self.selected_row == index) self.palette.accent else if (state == .hovered or state == .pressed) self.palette.hovered_row else null,
                    .border = if (ui.focused(id)) .{ .color = self.palette.highlight, .widths = .all(1) } else null,
                });
                const name = std.fmt.bufPrint(&name_buffer, "Document {d}", .{index + 1}) catch "Document";
                self.body(ui, name, self.palette.text);
                ui.close();
                if (ui.clicked(id)) {
                    self.selected_row = index;
                    self.last_action = "selected a document";
                }
            }
        }

        fn mainPanel(self: *Self, ui: *Ui) void {
            ui.open(.{
                .id = ids.content,
                .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(self.metrics.padding), .child_gap = self.metrics.gap },
            });
            defer ui.close();

            ui.text(self.title, .{ .size = self.metrics.title_size, .color = self.palette.text });
            self.body(ui, "This window is laid out by zui and drawn by the backend named above. The same declaration code runs on every renderer, so differences between them are the renderer's. Resize to watch this paragraph re-wrap, scroll the list with the wheel, and press Tab to move focus.", self.palette.muted_text);

            _ = self.widgets.checkbox(ui, ids.tooltips, "Show tooltips", &self.show_tooltips, .{});
            self.widgets.labeledRow(ui, "Volume");
            _ = self.widgets.slider(ui, ids.volume, &self.volume, .{ .step = 0.05 });
            ui.close();

            {
                ui.open(.{ .id = ids.hover_me, .interactive = true, .layout = .{ .padding = .symmetric(self.metrics.padding, self.metrics.padding / 2) }, .background = self.widgets.theme.control.get(ui.widgetState(ids.hover_me)), .corner_radius = .all(self.metrics.corner_radius) });
                defer ui.close();
                self.body(ui, "Hover me", self.palette.text);
                if (ui.hovered(ids.hover_me) and self.show_tooltips) {
                    ui.open(.{
                        .floating = .{ .anchor = .top_left, .attach_point = .bottom_left, .offset = .{ 0, self.metrics.gap / 2 } },
                        .layout = .{ .padding = .symmetric(self.metrics.padding / 2, self.metrics.padding / 4) },
                        .background = self.palette.highlight,
                        .corner_radius = .all(self.metrics.corner_radius),
                    });
                    self.body(ui, "A floating tooltip", self.palette.background);
                    ui.close();
                }
            }

            var status_buffer: [128]u8 = undefined;
            const selected_number = if (self.selected_row) |index| index + 1 else 0;
            const status = std.fmt.bufPrint(&status_buffer, "Clicks: {d}   Last action: {s}   Selected: document {d}   Volume: {d:.2}", .{ self.clicks, self.last_action, selected_number, self.volume }) catch "";
            self.body(ui, status, self.palette.muted_text);
        }

        fn aboutDialog(self: *Self, ui: *Ui) void {
            if (!self.about_open) return;
            if (ui.keyPressed(.escape)) self.about_open = false;

            ui.open(.{
                .interactive = true,
                .floating = .{ .attach_to = .root, .z = 10 },
                .layout = .{ .sizing = .grow_both, .child_alignment = .{ .x = .center, .y = .center } },
                .background = self.palette.overlay,
            });
            defer ui.close();
            ui.open(.{
                .focus_scope = true,
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(self.metrics.dialog_width) }, .padding = .all(self.metrics.padding), .child_gap = self.metrics.gap },
                .background = self.palette.panel,
                .corner_radius = .all(self.metrics.corner_radius),
                .border = .{ .color = self.palette.border, .widths = .all(1) },
            });
            defer ui.close();
            ui.text("About", .{ .size = self.metrics.title_size, .color = self.palette.text });
            self.body(ui, "This dialog floats in its own layer and keeps Tab focus inside it. Press Escape or Close.", self.palette.muted_text);
            if (self.widgets.button(ui, ids.dialog_close, "Close", .{})) self.about_open = false;
        }
    };
}
