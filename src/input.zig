const std = @import("std");
const zui = @import("zui");

/// Turns the bytes a terminal sends (UTF-8 text, VT key sequences, SGR
/// mouse reports and focus reports) into a frame record's events, in the
/// order they arrived. A press and release read together stay in order, so
/// zui sees a click.
///
/// ```zig
/// decoder.feed(terminal.readAvailable(&read_buffer), terminal.now());
/// ui.beginFrame(&.{ .params = .{ .now = now, .viewport = viewport }, .events = decoder.take() });
/// ```
pub const InputDecoder = struct {
    pub const event_capacity = 512;
    pub const text_capacity = 1024;

    cell_size: [2]f32 = .{ 8, 16 },
    /// Layout units scrolled per wheel notch.
    wheel_step: f32 = 48,

    quit_requested: bool = false,
    /// Events that did not fit since the last `take`.
    dropped_events: u32 = 0,

    events: [event_capacity]zui.Event = undefined,
    event_count: usize = 0,
    text: [text_capacity]u8 = undefined,
    text_length: usize = 0,
    /// When the bytes being fed arrived.
    arrived_at: zui.Instant = .zero,
    /// ESC before a key: the next key is pressed with Alt.
    alt_pending: bool = false,
    incomplete_sequence: [32]u8 = undefined,
    incomplete_sequence_length: usize = 0,

    /// The events fed since the last `take`. They point into the decoder,
    /// so they stay valid until the next `feed`; `beginFrame` copies them.
    pub fn take(self: *InputDecoder) []const zui.Event {
        const events = self.events[0..self.event_count];
        self.event_count = 0;
        self.text_length = 0;
        self.dropped_events = 0;
        return events;
    }

    pub fn feed(self: *InputDecoder, bytes: []const u8, arrived_at: zui.Instant) void {
        self.arrived_at = arrived_at;
        var joined: [4096 + 32]u8 = undefined;
        var remaining = bytes;
        if (self.incomplete_sequence_length > 0) {
            const prefix = self.incomplete_sequence[0..self.incomplete_sequence_length];
            const take_length = @min(bytes.len, joined.len - prefix.len);
            @memcpy(joined[0..prefix.len], prefix);
            @memcpy(joined[prefix.len..][0..take_length], bytes[0..take_length]);
            remaining = joined[0 .. prefix.len + take_length];
            self.incomplete_sequence_length = 0;
        }
        while (remaining.len > 0) {
            const consumed = self.decodeOne(remaining) orelse {
                const kept = @min(remaining.len, self.incomplete_sequence.len);
                @memcpy(self.incomplete_sequence[0..kept], remaining[0..kept]);
                self.incomplete_sequence_length = kept;
                return;
            };
            remaining = remaining[consumed..];
        }
    }

    /// Decodes the event at the start of `bytes` and returns its length,
    /// or null when `bytes` ends partway through it.
    fn decodeOne(self: *InputDecoder, bytes: []const u8) ?usize {
        const first = bytes[0];
        switch (first) {
            0x1B => return self.decodeEscape(bytes),
            '\t' => self.pushKey(.tab, .{}),
            '\r', '\n' => self.pushKey(.enter, .{}),
            0x7F, 0x08 => self.pushKey(.backspace, .{}),
            0x00 => self.pushKey(.space, .{ .control = true }),
            0x01...0x07, 0x0B, 0x0C, 0x0E...0x1A => {
                if (first == 0x03 or first == 0x11) self.quit_requested = true;
                self.pushKey(letterKey(first - 0x01), .{ .control = true });
            },
            0x1C...0x1F => {},
            else => {
                const length = std.unicode.utf8ByteSequenceLength(first) catch return 1;
                if (bytes.len < length) return null;
                self.pushTyped(bytes[0..length]);
                return length;
            },
        }
        return 1;
    }

    /// A lone ESC at the end of a read is the Escape key: terminals send a
    /// whole sequence in one write, so a sequence never ends a read early
    /// in practice.
    fn decodeEscape(self: *InputDecoder, bytes: []const u8) ?usize {
        if (bytes.len == 1) {
            self.pushKey(.escape, .{});
            return 1;
        }
        switch (bytes[1]) {
            '[' => return self.decodeControlSequence(bytes),
            'O' => {
                if (bytes.len < 3) return null;
                if (keyForFinalByte(bytes[2])) |key| self.pushKey(key, .{});
                return 3;
            },
            0x1B => {
                self.pushKey(.escape, .{});
                return 1;
            },
            else => {
                self.alt_pending = true;
                return 1;
            },
        }
    }

    fn decodeControlSequence(self: *InputDecoder, bytes: []const u8) ?usize {
        var end: usize = 2;
        while (end < bytes.len and (bytes[end] < 0x40 or bytes[end] > 0x7E)) end += 1;
        if (end == bytes.len) return if (bytes.len >= self.incomplete_sequence.len) bytes.len else null;
        const parameters = bytes[2..end];
        const final_byte = bytes[end];
        const length = end + 1;

        if (parameters.len > 0 and parameters[0] == '<') {
            self.decodeMouseReport(parameters[1..], final_byte);
            return length;
        }
        if (parameters.len == 0 and (final_byte == 'I' or final_byte == 'O')) {
            self.push(.{ .environment = .{ .window_focused = final_byte == 'I' } });
            return length;
        }

        var numbers: [4]u32 = @splat(0);
        const number_count = parseParameters(parameters, &numbers);
        const modifiers: zui.Modifiers = if (number_count >= 2) modifiersFromParameter(numbers[1]) else .{};

        if (final_byte == 'Z') {
            self.pushKey(.tab, .{ .shift = true });
        } else if (final_byte == '~') {
            const key: ?zui.Key = switch (numbers[0]) {
                1, 7 => .home,
                2 => .insert,
                3 => .delete,
                4, 8 => .end,
                5 => .page_up,
                6 => .page_down,
                else => null,
            };
            if (key) |pressed| self.pushKey(pressed, modifiers);
        } else if (keyForFinalByte(final_byte)) |key| {
            self.pushKey(key, modifiers);
        }
        return length;
    }

    /// SGR mouse reports: `ESC [ < button ; column ; row M` for a press or
    /// motion, `m` for a release. Columns and rows count from 1.
    fn decodeMouseReport(self: *InputDecoder, parameters: []const u8, final_byte: u8) void {
        var numbers: [3]u32 = @splat(0);
        if (parseParameters(parameters, &numbers) < 3) return;
        const button_code = numbers[0];
        const position: [2]f32 = .{
            (@as(f32, @floatFromInt(numbers[1] -| 1)) + 0.5) * self.cell_size[0],
            (@as(f32, @floatFromInt(numbers[2] -| 1)) + 0.5) * self.cell_size[1],
        };
        const pointer: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = position, .at = self.arrived_at };

        const is_wheel = button_code & 64 != 0;
        const is_motion = button_code & 32 != 0;
        if (is_wheel) {
            const delta: [2]f32 = switch (button_code & 3) {
                0 => .{ 0, -self.wheel_step },
                1 => .{ 0, self.wheel_step },
                2 => .{ -self.wheel_step, 0 },
                else => .{ self.wheel_step, 0 },
            };
            self.push(.{ .wheel = .{ .position = position, .delta = delta, .at = self.arrived_at } });
            return;
        }
        if (is_motion) {
            self.push(.{ .pointer_move = .{ .pointer = pointer } });
            return;
        }
        const button: zui.Button = switch (button_code & 3) {
            0 => .primary,
            1 => .middle,
            2 => .secondary,
            else => return,
        };
        const press: zui.PointerButton = .{ .pointer = pointer, .button = button };
        self.push(if (final_byte == 'M') .{ .pointer_down = press } else .{ .pointer_up = press });
    }

    fn pushKey(self: *InputDecoder, key: zui.Key, modifiers: zui.Modifiers) void {
        var held = modifiers;
        held.alt = held.alt or self.alt_pending;
        self.alt_pending = false;
        self.push(.{ .key_down = .{ .key = key, .modifiers = held, .at = self.arrived_at } });
    }

    /// A typed character is text, and also a key when it names one, so
    /// shortcuts such as Alt+S can be matched.
    fn pushTyped(self: *InputDecoder, bytes: []const u8) void {
        if (bytes.len == 1) {
            const byte = bytes[0];
            switch (byte) {
                'a'...'z' => self.pushKey(letterKey(byte - 'a'), .{}),
                'A'...'Z' => self.pushKey(letterKey(byte - 'A'), .{ .shift = true }),
                '0'...'9' => self.pushKey(digitKey(byte - '0'), .{}),
                ' ' => self.pushKey(.space, .{}),
                else => {},
            }
        }
        self.alt_pending = false;
        self.pushText(bytes);
    }

    /// Text typed in a row joins the previous text event.
    fn pushText(self: *InputDecoder, bytes: []const u8) void {
        if (self.text_length + bytes.len > self.text.len) {
            self.dropped_events += 1;
            return;
        }
        const start = self.text_length;
        @memcpy(self.text[start..][0..bytes.len], bytes);
        self.text_length += bytes.len;
        if (self.event_count > 0) {
            const last = &self.events[self.event_count - 1];
            if (last.* == .text and @intFromPtr(last.text.ptr) + last.text.len == @intFromPtr(&self.text[start])) {
                last.text = self.text[start - last.text.len .. self.text_length];
                return;
            }
        }
        self.push(.{ .text = self.text[start..self.text_length] });
    }

    fn push(self: *InputDecoder, event: zui.Event) void {
        if (self.event_count == self.events.len) {
            self.dropped_events += 1;
            return;
        }
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
};

fn letterKey(offset: u8) zui.Key {
    return @enumFromInt(@intFromEnum(zui.Key.a) + offset);
}

fn digitKey(offset: u8) zui.Key {
    return @enumFromInt(@intFromEnum(zui.Key.digit_0) + offset);
}

fn keyForFinalByte(final_byte: u8) ?zui.Key {
    return switch (final_byte) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'P' => .f1,
        'Q' => .f2,
        'R' => .f3,
        'S' => .f4,
        else => null,
    };
}

/// xterm encodes held modifiers as `1 + bits`: 1 shift, 2 alt, 4 control.
fn modifiersFromParameter(parameter: u32) zui.Modifiers {
    const bits = parameter -| 1;
    return .{ .shift = bits & 1 != 0, .alt = bits & 2 != 0, .control = bits & 4 != 0 };
}

/// Parses `12;34;5` into `numbers` and returns how many were present.
fn parseParameters(parameters: []const u8, numbers: []u32) usize {
    var count: usize = 0;
    var fields = std.mem.splitScalar(u8, parameters, ';');
    while (fields.next()) |field| {
        if (count == numbers.len) break;
        numbers[count] = std.fmt.parseInt(u32, field, 10) catch 0;
        count += 1;
    }
    return count;
}

const testing = std.testing;
const Tag = std.meta.Tag(zui.Event);

fn expectTags(expected: []const Tag, events: []const zui.Event) !void {
    try testing.expectEqual(expected.len, events.len);
    for (expected, events) |tag, event| try testing.expectEqual(tag, std.meta.activeTag(event));
}

fn chordOf(event: zui.Event) zui.Chord {
    return .{ .key = event.key_down.key, .modifiers = event.key_down.modifiers };
}

test "keys, text and shift-tab, in order" {
    var decoder: InputDecoder = .{};
    decoder.feed("hé\x1b[A\x1b[Z\x1b[3~\r", .fromNanoseconds(5));
    const events = decoder.take();
    try expectTags(&.{ .key_down, .text, .key_down, .key_down, .key_down, .key_down }, events);
    try testing.expectEqual(zui.Key.h, events[0].key_down.key);
    try testing.expectEqualStrings("hé", events[1].text);
    try testing.expectEqual(zui.Key.up, events[2].key_down.key);
    try testing.expectEqual(zui.Chord{ .key = .tab, .modifiers = .{ .shift = true } }, chordOf(events[3]));
    try testing.expectEqual(zui.Key.delete, events[4].key_down.key);
    try testing.expectEqual(zui.Key.enter, events[5].key_down.key);
    try testing.expectEqual(@as(u64, 5), events[5].key_down.at.nanoseconds);
}

test "control and alt make chords" {
    var decoder: InputDecoder = .{};
    decoder.feed("\x13\x1bs", .zero);
    const events = decoder.take();
    try expectTags(&.{ .key_down, .key_down, .text }, events);
    try testing.expectEqual(zui.Chord{ .key = .s, .modifiers = .{ .control = true } }, chordOf(events[0]));
    try testing.expectEqual(zui.Chord{ .key = .s, .modifiers = .{ .alt = true } }, chordOf(events[1]));
    try testing.expect(!decoder.quit_requested);
    decoder.feed("\x11", .zero);
    try testing.expect(decoder.quit_requested);
}

test "a lone escape is the Escape key" {
    var decoder: InputDecoder = .{};
    decoder.feed("\x1b", .zero);
    try testing.expectEqual(zui.Key.escape, decoder.take()[0].key_down.key);
}

test "a sequence split across reads is joined" {
    var decoder: InputDecoder = .{};
    decoder.feed("\x1b[<0;5", .zero);
    decoder.feed(";3M", .zero);
    const events = decoder.take();
    try expectTags(&.{.pointer_down}, events);
    try testing.expectEqual([2]f32{ 4.5 * 8, 2.5 * 16 }, events[0].pointer_down.pointer.position);
    try testing.expectEqual(zui.Button.primary, events[0].pointer_down.button);
}

test "a click that arrives whole stays a press and a release in order" {
    var decoder: InputDecoder = .{};
    decoder.feed("\x1b[<35;2;2M\x1b[<0;1;1M\x1b[<0;1;1m", .zero);
    try expectTags(&.{ .pointer_move, .pointer_down, .pointer_up }, decoder.take());
}

test "the wheel scrolls toward the end when rolled down" {
    var decoder: InputDecoder = .{};
    decoder.feed("\x1b[<65;1;1M", .zero);
    try testing.expectEqual([2]f32{ 0, 48 }, decoder.take()[0].wheel.delta);
}

test "focus reports change the environment" {
    var decoder: InputDecoder = .{};
    decoder.feed("\x1b[O\x1b[I", .zero);
    const events = decoder.take();
    try testing.expect(!events[0].environment.window_focused);
    try testing.expect(events[1].environment.window_focused);
}

test "events that do not fit are counted" {
    var decoder: InputDecoder = .{};
    for (0..InputDecoder.event_capacity + 3) |_| decoder.feed("\x1b[A", .zero);
    try testing.expectEqual(@as(u32, 3), decoder.dropped_events);
    try testing.expectEqual(@as(usize, InputDecoder.event_capacity), decoder.take().len);
}
