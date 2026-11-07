# zui-terminal

A terminal backend for [zui](https://github.com/AaronJClausen/zui): it
decodes keys, mouse reports and focus reports into the events of zui's
frame records, measures text in cells through zui's text contract, and
paints zui's render commands as 24-bit-color cells. It has no dependencies
besides zui.

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

Layout stays in pixel-like units: a cell is `Text.cell_size` units (8×16
by default), so a UI written for a pixel renderer still lays out
sensibly. A cell is painted when its center lies inside a command's
bounds.

| zui | terminal |
|---|---|
| `rectangle` | cell backgrounds; translucent colors blend over what is below |
| `border` | box drawing (`┌─┐`, or `╭─╮` with a corner radius); `[` `]` on a one-row box |
| `text` | one glyph per code point, one line per command; letter spacing moves each glyph to the nearest cell |
| `image`, `custom` | `RenderOptions` hooks that paint cells directly |
| `clip_begin` / `clip_end` | a stack of cell rectangles |
| pointer | SGR mouse reports as `pointer_move`, `pointer_down` and `pointer_up`, in the order they arrived |
| wheel | SGR wheel reports, `InputDecoder.wheel_step` units per notch |
| keys | navigation, function and editing keys; letters and digits also as keys, so Ctrl+S and Alt+S are chords |
| focus | focus reports (`CSI I` / `CSI O`) as the environment's `window_focused` |

What a terminal cannot do:
- **One font, one size.** `Text.zuiMeasure` ignores both: every code
  point is one cell, plus the letter spacing after it. Wide characters
  (CJK, most emoji) take two cells on screen but are measured as one.
- **Borders never overwrite glyphs.** zui draws borders after their
  children, so a border cell that already holds text keeps it.
- **No cursor shapes or IME window.** The frame's host requests are not
  applied.

## Use it in your application

```zig
const zui_terminal = @import("zui_terminal");
const zui = zui_terminal.zui;
const Ui = zui.Context(zui_terminal.config(.{}));

var terminal = try zui_terminal.Terminal.enter(io);
defer terminal.leave();
var text: zui_terminal.Text = .{};
var ui = try Ui.init(gpa, io, &text);
var screen: zui_terminal.Screen = .{};
var decoder: zui_terminal.InputDecoder = .{};

while (!decoder.quit_requested) {
    const size = terminal.size();
    ui.beginFrame(&.{ .params = .{ .now = terminal.now(), .viewport = viewportFor(size) }, .events = decoder.take() });
    // ... declare your UI ...
    const frame = ui.endFrame();
    zui_terminal.render(Ui.RenderCommand, try screen.begin(gpa, size, background), text.cell_size, frame.commands(), .{});
    try screen.present(stdout);
    ui.release(frame);
    terminal.wait(ui.nextFrame());
    decoder.feed(terminal.readAvailable(&read_buffer), terminal.now());
}
```

`terminal.wait` sleeps as `nextFrame` says: not at all, until a
requested instant, or until input, a resize or a wake, so an idle UI uses
no CPU. `terminal.waker()` is a `zui.Waker` for sources' producers: on
Windows it writes a console input record, elsewhere it writes to a pipe,
and either way a wake that arrives before the wait still ends it. On
Linux and macOS a resize does not wake `poll`, so an idle wait looks at
the size every 250 ms and runs a frame only when it changed.

## License

MIT; see [LICENSE](LICENSE).
