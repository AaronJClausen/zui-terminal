const std = @import("std");
const zui = @import("zui");

/// Turns the bytes a terminal sends (UTF-8 text, VT key sequences and SGR
/// mouse reports) into one `zui.Input` per frame.
///
/// ```zig
/// decoder.feed(terminal.readAvailable(&read_buffer));
/// ui.beginFrame(decoder.take(viewport, dt_seconds));
/// ```
pub const InputDecoder = struct {
    cell_size: [2]f32 = .{ 8, 16 },
    /// Layout units scrolled per wheel notch.
    wheel_step: f32 = 48,

    pointer: ?[2]f32 = null,
    held_buttons: std.EnumSet(zui.Button) = .initEmpty(),
    quit_requested: bool = false,

    buttons_pressed_this_frame: std.EnumSet(zui.Button) = .initEmpty(),
    releases_for_next_frame: std.EnumSet(zui.Button) = .initEmpty(),
    has_undelivered_input: bool = false,
    keys: [zui.max_keys_per_frame]zui.Key = undefined,
    key_count: usize = 0,
    text: [zui.max_text_input_bytes]u8 = undefined,
    text_length: usize = 0,
    wheel: [2]f32 = .{ 0, 0 },
    modifiers: zui.Modifiers = .{},
    incomplete_sequence: [32]u8 = undefined,
    incomplete_sequence_length: usize = 0,

    /// This frame's input. Its slices point into the decoder, which must
    /// stay alive and unfed until `beginFrame` returns.
    pub fn take(self: *InputDecoder, viewport: [2]f32, dt_seconds: f32) zui.Input {
        const input: zui.Input = .{
            .viewport = viewport,
            .dt_seconds = dt_seconds,
            .pointer = self.pointer,
            .buttons = self.held_buttons,
            .wheel = self.wheel,
            .keys_pressed = self.keys[0..self.key_count],
            .modifiers = self.modifiers,
            .text_input = self.text[0..self.text_length],
        };
        self.held_buttons = self.held_buttons.differenceWith(self.releases_for_next_frame);
        self.has_undelivered_input = self.releases_for_next_frame.count() > 0;
        self.releases_for_next_frame = .initEmpty();
        self.buttons_pressed_this_frame = .initEmpty();
        self.key_count = 0;
        self.text_length = 0;
        self.wheel = .{ 0, 0 };
        self.modifiers = .{};
        return input;
    }

    /// True when the next frame must run even without new bytes, because a
    /// click arrived whole and its release was held back for one frame.
    pub fn hasUndeliveredInput(self: *const InputDecoder) bool {
        return self.has_undelivered_input;
    }

    pub fn feed(self: *InputDecoder, bytes: []const u8) void {
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
            0x03, 0x11 => self.quit_requested = true,
            '\t' => self.pushKey(.tab),
            '\r', '\n' => self.pushKey(.enter),
            0x7F, 0x08 => self.pushKey(.backspace),
            ' ' => {
                self.pushKey(.space);
                self.pushText(" ");
            },
            0x00...0x02, 0x04...0x07, 0x0B, 0x0C, 0x0E...0x10, 0x12...0x1A, 0x1C...0x1F => {},
            else => {
                const length = std.unicode.utf8ByteSequenceLength(first) catch return 1;
                if (bytes.len < length) return null;
                self.pushText(bytes[0..length]);
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
            self.pushKey(.escape);
            return 1;
        }
        switch (bytes[1]) {
            '[' => return self.decodeControlSequence(bytes),
            'O' => {
                if (bytes.len < 3) return null;
                if (keyForFinalByte(bytes[2])) |key| self.pushKey(key);
                return 3;
            },
            0x1B => {
                self.pushKey(.escape);
                return 1;
            },
            else => {
                self.modifiers.alt = true;
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

        var numbers: [4]u32 = @splat(0);
        const number_count = parseParameters(parameters, &numbers);
        if (number_count >= 2) self.applyModifierParameter(numbers[1]);

        if (final_byte == 'Z') {
            self.modifiers.shift = true;
            self.pushKey(.tab);
        } else if (final_byte == '~') {
            const key: ?zui.Key = switch (numbers[0]) {
                1, 7 => .home,
                3 => .delete,
                4, 8 => .end,
                5 => .page_up,
                6 => .page_down,
                else => null,
            };
            if (key) |pressed| self.pushKey(pressed);
        } else if (keyForFinalByte(final_byte)) |key| {
            self.pushKey(key);
        }
        return length;
    }

    /// SGR mouse reports: `ESC [ < button ; column ; row M` for a press or
    /// motion, `m` for a release. Columns and rows count from 1.
    fn decodeMouseReport(self: *InputDecoder, parameters: []const u8, final_byte: u8) void {
        var numbers: [3]u32 = @splat(0);
        if (parseParameters(parameters, &numbers) < 3) return;
        const button_code = numbers[0];
        self.pointer = .{
            (@as(f32, @floatFromInt(numbers[1] -| 1)) + 0.5) * self.cell_size[0],
            (@as(f32, @floatFromInt(numbers[2] -| 1)) + 0.5) * self.cell_size[1],
        };
        self.modifiers.shift = self.modifiers.shift or button_code & 4 != 0;
        self.modifiers.alt = self.modifiers.alt or button_code & 8 != 0;
        self.modifiers.control = self.modifiers.control or button_code & 16 != 0;

        const is_wheel = button_code & 64 != 0;
        const is_motion = button_code & 32 != 0;
        if (is_wheel) {
            switch (button_code & 3) {
                0 => self.wheel[1] -= self.wheel_step,
                1 => self.wheel[1] += self.wheel_step,
                2 => self.wheel[0] -= self.wheel_step,
                else => self.wheel[0] += self.wheel_step,
            }
            return;
        }
        if (is_motion) return;

        const button: zui.Button = switch (button_code & 3) {
            0 => .primary,
            1 => .middle,
            2 => .secondary,
            else => return,
        };
        if (final_byte == 'M') {
            self.held_buttons.insert(button);
            self.buttons_pressed_this_frame.insert(button);
        } else if (self.buttons_pressed_this_frame.contains(button)) {
            self.releases_for_next_frame.insert(button);
        } else {
            self.held_buttons.remove(button);
        }
    }

    /// xterm encodes held modifiers as `1 + bits`: 1 shift, 2 alt, 4 control.
    fn applyModifierParameter(self: *InputDecoder, parameter: u32) void {
        const bits = parameter -| 1;
        self.modifiers.shift = self.modifiers.shift or bits & 1 != 0;
        self.modifiers.alt = self.modifiers.alt or bits & 2 != 0;
        self.modifiers.control = self.modifiers.control or bits & 4 != 0;
    }

    fn pushKey(self: *InputDecoder, key: zui.Key) void {
        if (self.key_count == self.keys.len) return;
        self.keys[self.key_count] = key;
        self.key_count += 1;
    }

    fn pushText(self: *InputDecoder, bytes: []const u8) void {
        if (self.text_length + bytes.len > self.text.len) return;
        @memcpy(self.text[self.text_length..][0..bytes.len], bytes);
        self.text_length += bytes.len;
    }
};

fn keyForFinalByte(final_byte: u8) ?zui.Key {
    return switch (final_byte) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        else => null,
    };
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

test "keys, text and shift-tab" {
    var decoder: InputDecoder = .{};
    decoder.feed("hé\x1b[A\x1b[Z\x1b[3~\r");
    const input = decoder.take(.{ 80, 24 }, 0);
    try testing.expectEqualStrings("hé", input.text_input);
    try testing.expectEqualSlices(zui.Key, &.{ .up, .tab, .delete, .enter }, input.keys_pressed);
    try testing.expect(input.modifiers.shift);
}

test "a lone escape is the Escape key" {
    var decoder: InputDecoder = .{};
    decoder.feed("\x1b");
    try testing.expectEqualSlices(zui.Key, &.{.escape}, decoder.take(.{ 80, 24 }, 0).keys_pressed);
}

test "a sequence split across reads is joined" {
    var decoder: InputDecoder = .{};
    decoder.feed("\x1b[<0;5");
    decoder.feed(";3M");
    const input = decoder.take(.{ 80, 24 }, 0);
    try testing.expectEqual([2]f32{ 4.5 * 8, 2.5 * 16 }, input.pointer.?);
    try testing.expect(input.buttons.contains(.primary));
}

test "a click that arrives whole is spread over two frames" {
    var decoder: InputDecoder = .{};
    decoder.feed("\x1b[<0;1;1M\x1b[<0;1;1m");
    try testing.expect(decoder.take(.{ 80, 24 }, 0).buttons.contains(.primary));
    try testing.expect(decoder.hasUndeliveredInput());
    try testing.expect(!decoder.take(.{ 80, 24 }, 0).buttons.contains(.primary));
    try testing.expect(!decoder.hasUndeliveredInput());
}

test "the wheel scrolls toward the end when rolled down" {
    var decoder: InputDecoder = .{};
    decoder.feed("\x1b[<65;1;1M");
    try testing.expectEqual([2]f32{ 0, 48 }, decoder.take(.{ 80, 24 }, 0).wheel);
}
