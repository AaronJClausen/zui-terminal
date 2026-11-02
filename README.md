# zui-terminal

A terminal backend for [zui](https://github.com/AaronJClausen/zui): it
reads keys and mouse reports from the terminal into `zui.Input`, measures
text in cells, and paints zui's render commands as 24-bit-color cells. It
has no dependencies besides zui.

## Requirements

- Zig **0.16.0**
- zui, fetched automatically
- A terminal with VT sequences, 24-bit color and SGR mouse reports:
  Windows Terminal, the Windows 10+ console, or any xterm-compatible
  terminal on Linux and macOS

## Run the demo

```sh
zig build demo           # interactive; Ctrl+C or Ctrl+Q quits
zig build demo -- --dump # render offscreen at 100×30 and print the glyphs
```

The demo runs `examples/showcase.zig`, the same UI as the zui-sokol demo,
so the two renderers can be compared.

## Developing against a local zui

`build.zig.zon` pins zui to a commit. To build against a zui working copy
instead, without editing it:

```sh
zig build test --fork=../zui
```

To move the pin, push the zui change and run
`zig fetch --save=zui git+https://github.com/AaronJClausen/zui#<commit>`.

## How zui maps onto cells

Layout stays in pixel-like units: a cell is `Platform.cell_size` units
(8×16 by default), so a UI written for a pixel renderer still lays out
sensibly. A cell is painted when its center lies inside a command's
bounds.

| zui | terminal |
|---|---|
| `rectangle` | cell backgrounds; translucent colors blend over what is below |
| `border` | box drawing (`┌─┐`, or `╭─╮` with a corner radius); `[` `]` on a one-row box |
| `text` | one glyph per code point, one line per command |
| `image`, `custom` | `RenderOptions` hooks that paint cells directly |
| `clip_begin` / `clip_end` | a stack of cell rectangles |
| wheel | SGR wheel reports, `InputDecoder.wheel_step` units per notch |

What a terminal cannot do:
- **One font, one size.** `measureText` ignores both: every code point is
  one cell. Wide characters (CJK, most emoji) take two cells on screen but
  are measured as one.
- **Borders never overwrite glyphs.** zui draws borders after their
  children, so a border cell that already holds text keeps it.
- **Clicks can arrive whole.** A press and release read together are
  spread over two frames, so zui still sees the press.

## Use it in your application

```zig
const zui_terminal = @import("zui_terminal");
const zui = zui_terminal.zui;
const Ui = zui.Context(.{}, zui_terminal.Platform);

var terminal = try zui_terminal.Terminal.enter(io);
defer terminal.leave();
var platform: zui_terminal.Platform = .{ .waker = &terminal.waker };
var ui = try Ui.init(gpa, io, &platform);
var screen: zui_terminal.Screen = .{};
var decoder: zui_terminal.InputDecoder = .{};

while (!decoder.quit_requested) {
    const size = terminal.size();
    ui.beginFrame(decoder.take(viewport_for(size), dt_seconds));
    // ... declare your UI ...
    const frame = ui.endFrame() catch ui.lastFrame();
    zui_terminal.render(Ui.RenderCommand, try screen.begin(gpa, size, background), platform.cell_size, frame.commands(), .{});
    try screen.present(stdout);
    ui.release(frame);
    terminal.waitForInput(if (ui.needsFrame() or decoder.hasUndeliveredInput()) .next_frame else .idle);
    decoder.feed(terminal.readAvailable(&read_buffer));
}
```

`Platform.wake` ends an idle wait from a task thread: on Windows by
writing a console input record, elsewhere through a pipe. On Linux and
macOS an idle wait also times out every 250 ms to notice resizes.

## License

MIT; see [LICENSE](LICENSE).
