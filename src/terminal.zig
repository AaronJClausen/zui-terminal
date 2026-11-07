const std = @import("std");
const builtin = @import("builtin");
const zui = @import("zui");
const screen = @import("screen.zig");

const is_windows = builtin.os.tag == .windows;
const windows = std.os.windows;
const posix = std.posix;

/// The terminal in raw mode on the alternate screen, with mouse reporting.
/// `leave` restores everything `enter` changed.
pub const Terminal = struct {
    io: std.Io,
    stdin: std.Io.File,
    stdout: std.Io.File,
    saved: SavedState,
    wake_signal: WakeSignal,
    /// Left over from a UTF-16 surrogate pair split across console records.
    pending_high_surrogate: ?u16 = null,

    pub fn enter(io: std.Io) !Terminal {
        var self: Terminal = .{
            .io = io,
            .stdin = .stdin(),
            .stdout = .stdout(),
            .saved = undefined,
            .wake_signal = undefined,
        };
        if (is_windows) {
            try self.enterWindows();
        } else {
            try self.enterPosix();
        }
        try self.stdout.writeStreamingAll(io, screen.enter_sequence);
        return self;
    }

    pub fn leave(self: *Terminal) void {
        self.stdout.writeStreamingAll(self.io, screen.leave_sequence) catch {};
        if (is_windows) {
            _ = SetConsoleMode(self.stdin.handle, self.saved.input_mode);
            _ = SetConsoleMode(self.stdout.handle, self.saved.output_mode);
            _ = SetConsoleOutputCP(self.saved.output_code_page);
        } else {
            posix.tcsetattr(self.stdin.handle, .FLUSH, self.saved.termios) catch {};
            _ = posix.system.close(self.wake_signal.read_end);
            _ = posix.system.close(self.wake_signal.write_end);
        }
    }

    /// Columns and rows of the visible window.
    pub fn size(self: *Terminal) [2]u16 {
        const fallback: [2]u16 = .{ 80, 24 };
        if (is_windows) {
            var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (GetConsoleScreenBufferInfo(self.stdout.handle, &info) == .FALSE) return fallback;
            return .{ @intCast(info.srWindow.Right - info.srWindow.Left + 1), @intCast(info.srWindow.Bottom - info.srWindow.Top + 1) };
        }
        var window_size: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const result = self.io.operate(.{ .device_io_control = .{ .file = self.stdout, .code = posix.T.IOCGWINSZ, .arg = &window_size } }) catch return fallback;
        if (result.device_io_control < 0 or window_size.col == 0) return fallback;
        return .{ window_size.col, window_size.row };
    }

    /// What a `Renderer` draws into: the terminal at its current size.
    pub fn surface(self: *Terminal) zui.Surface {
        const columns, const rows = self.size();
        return .{ .terminal = .{ .columns = columns, .rows = rows } };
    }

    /// The host's monotonic clock, for frame records.
    pub fn now(self: *const Terminal) zui.Instant {
        return .fromTimestamp(std.Io.Timestamp.now(self.io, .awake));
    }

    /// Ends a `wait` from any thread, so what a producer published gets
    /// drawn. Sticky: a wake while the loop is not waiting ends its next one.
    pub fn waker(self: *Terminal) zui.Waker {
        return .{ .context = &self.wake_signal, .wakeFn = WakeSignal.wake };
    }

    /// Sleeps as `next` says: not at all, until its instant, or until input,
    /// a resize or a wake.
    pub fn wait(self: *Terminal, next: zui.NextFrame) void {
        const timeout_milliseconds: ?u32 = switch (next) {
            .immediately => return,
            .at => |deadline| millisecondsUntil(self.now(), deadline),
            .on_event => null,
        };
        if (is_windows) {
            // A resize queues a console input record too, which ends the wait.
            _ = WaitForSingleObject(self.stdin.handle, timeout_milliseconds orelse infinite_wait);
            return;
        }
        // SIGWINCH does not wake `poll`, so the wait wakes now and then to
        // look for a resize, and keeps waiting when there was none.
        const resize_check_milliseconds: u32 = 250;
        const size_before = self.size();
        var remaining = timeout_milliseconds;
        while (true) {
            const slice = @min(remaining orelse resize_check_milliseconds, resize_check_milliseconds);
            var descriptors = [_]posix.pollfd{
                .{ .fd = self.stdin.handle, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_signal.read_end, .events = posix.POLL.IN, .revents = 0 },
            };
            const ready = posix.poll(&descriptors, @intCast(slice)) catch return;
            if (descriptors[1].revents & posix.POLL.IN != 0) {
                var drained: [64]u8 = undefined;
                _ = posix.read(self.wake_signal.read_end, &drained) catch {};
            }
            if (ready != 0) return;
            if (remaining) |*left| {
                left.* -= slice;
                if (left.* == 0) return;
            }
            const size_now = self.size();
            if (size_now[0] != size_before[0] or size_now[1] != size_before[1]) return;
        }
    }

    /// The bytes available right now, without blocking.
    pub fn readAvailable(self: *Terminal, buffer: []u8) []const u8 {
        if (is_windows) return self.readConsoleRecords(buffer);
        var descriptors = [_]posix.pollfd{.{ .fd = self.stdin.handle, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&descriptors, 0) catch return buffer[0..0];
        if (ready == 0) return buffer[0..0];
        const length = posix.read(self.stdin.handle, buffer) catch return buffer[0..0];
        return buffer[0..length];
    }

    fn enterWindows(self: *Terminal) !void {
        var input_mode: windows.DWORD = 0;
        var output_mode: windows.DWORD = 0;
        if (GetConsoleMode(self.stdin.handle, &input_mode) == .FALSE) return error.NotATerminal;
        if (GetConsoleMode(self.stdout.handle, &output_mode) == .FALSE) return error.NotATerminal;
        self.saved = .{ .input_mode = input_mode, .output_mode = output_mode, .output_code_page = GetConsoleOutputCP() };
        // ENABLE_EXTENDED_FLAGS without ENABLE_QUICK_EDIT_MODE stops a click
        // from starting a text selection instead of reaching the app.
        const raw_input = ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS | ENABLE_VIRTUAL_TERMINAL_INPUT;
        const vt_output = ENABLE_PROCESSED_OUTPUT | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN;
        if (SetConsoleMode(self.stdin.handle, raw_input) == .FALSE) return error.VirtualTerminalInputUnsupported;
        if (SetConsoleMode(self.stdout.handle, vt_output) == .FALSE) return error.VirtualTerminalOutputUnsupported;
        _ = SetConsoleOutputCP(utf8_code_page);
        self.wake_signal = .{ .console_input = self.stdin.handle };
    }

    fn enterPosix(self: *Terminal) !void {
        const original = try posix.tcgetattr(self.stdin.handle);
        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.ISTRIP = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(self.stdin.handle, .FLUSH, raw);
        self.saved = .{ .termios = original };

        var pipe_ends: [2]posix.fd_t = undefined;
        if (posix.errno(posix.system.pipe(&pipe_ends)) != .SUCCESS) {
            posix.tcsetattr(self.stdin.handle, .FLUSH, original) catch {};
            return error.PipeFailed;
        }
        self.wake_signal = .{ .read_end = pipe_ends[0], .write_end = pipe_ends[1] };
    }

    /// With ENABLE_VIRTUAL_TERMINAL_INPUT, keys and mouse reports arrive as
    /// the same VT sequences a POSIX terminal sends, carried one UTF-16 unit
    /// per key record. Records are only read once counted, so this never
    /// blocks.
    fn readConsoleRecords(self: *Terminal, buffer: []u8) []const u8 {
        var available: windows.DWORD = 0;
        if (GetNumberOfConsoleInputEvents(self.stdin.handle, &available) == .FALSE or available == 0) return buffer[0..0];
        var records: [128]INPUT_RECORD = undefined;
        var record_count: windows.DWORD = 0;
        const requested: windows.DWORD = @min(available, records.len);
        if (ReadConsoleInputW(self.stdin.handle, &records, requested, &record_count) == .FALSE) return buffer[0..0];

        var length: usize = 0;
        for (records[0..record_count]) |record| {
            if (record.EventType != KEY_EVENT) continue;
            const key = record.Event.KeyEvent;
            if (key.bKeyDown == .FALSE or key.uChar == 0) continue;
            for (0..@max(key.wRepeatCount, 1)) |_| {
                if (buffer.len - length < 4) return buffer[0..length];
                length += self.encodeUtf16Unit(key.uChar, buffer[length..]);
            }
        }
        return buffer[0..length];
    }

    fn encodeUtf16Unit(self: *Terminal, unit: u16, destination: []u8) usize {
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            self.pending_high_surrogate = unit;
            return 0;
        }
        const codepoint: u21 = if (std.unicode.utf16IsLowSurrogate(unit)) blk: {
            const high = self.pending_high_surrogate orelse return 0;
            self.pending_high_surrogate = null;
            break :blk std.unicode.utf16DecodeSurrogatePair(&.{ high, unit }) catch return 0;
        } else unit;
        return std.unicode.utf8Encode(codepoint, destination) catch 0;
    }
};

fn millisecondsUntil(now: zui.Instant, deadline: zui.Instant) u32 {
    const nanoseconds = deadline.nanoseconds -| now.nanoseconds;
    return std.math.lossyCast(u32, nanoseconds / std.time.ns_per_ms + @intFromBool(nanoseconds % std.time.ns_per_ms != 0));
}

const WakeSignal = if (is_windows) struct {
    console_input: windows.HANDLE,

    fn wake(context: *anyopaque) void {
        const self: *const @This() = @ptrCast(@alignCast(context));
        // Any record signals the console handle; a focus record is ignored
        // by `readAvailable`.
        const record: INPUT_RECORD = .{ .EventType = FOCUS_EVENT, .Event = .{ .padding = @splat(0) } };
        var written: windows.DWORD = 0;
        _ = WriteConsoleInputW(self.console_input, &.{record}, 1, &written);
    }
} else struct {
    read_end: posix.fd_t,
    write_end: posix.fd_t,

    fn wake(context: *anyopaque) void {
        const self: *const @This() = @ptrCast(@alignCast(context));
        _ = posix.system.write(self.write_end, "w", 1);
    }
};

const SavedState = if (is_windows) struct {
    input_mode: windows.DWORD,
    output_mode: windows.DWORD,
    output_code_page: windows.UINT,
} else struct {
    termios: posix.termios,
};

const utf8_code_page = 65001;
const infinite_wait: windows.DWORD = 0xFFFFFFFF;
const ENABLE_PROCESSED_OUTPUT = 0x0001;
const DISABLE_NEWLINE_AUTO_RETURN = 0x0008;
const ENABLE_WINDOW_INPUT = 0x0008;
const ENABLE_EXTENDED_FLAGS = 0x0080;
const ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
const KEY_EVENT = 0x0001;
const FOCUS_EVENT = 0x0010;

const KEY_EVENT_RECORD = extern struct {
    bKeyDown: windows.BOOL,
    wRepeatCount: windows.WORD,
    wVirtualKeyCode: windows.WORD,
    wVirtualScanCode: windows.WORD,
    uChar: u16,
    dwControlKeyState: windows.DWORD,
};

const INPUT_RECORD = extern struct {
    EventType: windows.WORD,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        padding: [16]u8,
    },
};

const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: windows.COORD,
    dwCursorPosition: windows.COORD,
    wAttributes: windows.WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: windows.COORD,
};

extern "kernel32" fn GetConsoleMode(console: windows.HANDLE, mode: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleMode(console: windows.HANDLE, mode: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) windows.UINT;
extern "kernel32" fn SetConsoleOutputCP(code_page: windows.UINT) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(console: windows.HANDLE, info: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetNumberOfConsoleInputEvents(console: windows.HANDLE, count: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ReadConsoleInputW(console: windows.HANDLE, records: [*]INPUT_RECORD, length: windows.DWORD, read: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteConsoleInputW(console: windows.HANDLE, records: [*]const INPUT_RECORD, length: windows.DWORD, written: *windows.DWORD) callconv(.winapi) windows.BOOL;

test "a deadline rounds up to whole milliseconds" {
    const now: zui.Instant = .fromNanoseconds(1_000_000);
    try std.testing.expectEqual(@as(u32, 0), millisecondsUntil(now, .fromNanoseconds(10)));
    try std.testing.expectEqual(@as(u32, 2), millisecondsUntil(now, now.addNanoseconds(1_500_000)));
}

test "console records match the Windows layout" {
    try std.testing.expectEqual(16, @sizeOf(KEY_EVENT_RECORD));
    try std.testing.expectEqual(20, @sizeOf(INPUT_RECORD));
}
