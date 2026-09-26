//! Minimal interactive prompts: a single-choice picker and a line editor.
//! When stdin is not a terminal, both fall back to reading plain lines so
//! buru can be scripted (`printf 'name\n\n' | buru h`).

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Tty = struct {
    out: *Io.Writer,
    /// Used only when stdin is not a terminal.
    lines: *Io.Reader,
    interactive: bool,
    color: bool,
    orig: ?posix.termios = null,

    const fd = posix.STDIN_FILENO;

    fn enterRaw(t: *Tty) !void {
        const orig = try posix.tcgetattr(fd);
        var raw = orig;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        try posix.tcsetattr(fd, .FLUSH, raw);
        t.orig = orig;
    }

    fn leaveRaw(t: *Tty) void {
        if (t.orig) |orig| posix.tcsetattr(fd, .FLUSH, orig) catch {};
        t.orig = null;
    }

    fn sty(t: *const Tty, code: []const u8) []const u8 {
        return if (t.color) code else "";
    }

    /// Reads one line, starting from `initial` (ignored when not
    /// interactive). Returns null when cancelled (Esc, Ctrl-C, Ctrl-D on an
    /// empty line) or at end of input.
    pub fn readLine(t: *Tty, a: Allocator, prompt: []const u8, initial: []const u8) !?[]const u8 {
        if (!t.interactive) {
            try t.out.print("{s}{s}{s}", .{ t.sty(cyan), prompt, t.sty(reset) });
            try t.out.flush();
            const line = (t.lines.takeDelimiter('\n') catch |e| switch (e) {
                error.StreamTooLong => return error.StreamTooLong,
                else => return null,
            }) orelse return null;
            try t.out.writeByte('\n');
            return try a.dupe(u8, std.mem.trimEnd(u8, line, "\r"));
        }

        try t.enterRaw();
        defer t.leaveRaw();

        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(a, initial);
        var cur: usize = buf.items.len; // byte offset of the cursor
        while (true) {
            // redraw: prompt, text, then move back to the cursor
            try t.out.print("\r{s}{s}{s}{s}\x1b[K", .{ t.sty(cyan), prompt, t.sty(reset), buf.items });
            const back = codepoints(buf.items[cur..]);
            if (back > 0) try t.out.print("\x1b[{d}D", .{back});
            try t.out.flush();

            var chunk: [64]u8 = undefined;
            const n = posix.read(fd, &chunk) catch return null;
            if (n == 0) return null;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const c = chunk[i];
                switch (c) {
                    '\r', '\n' => {
                        try t.out.writeAll("\r\n");
                        try t.out.flush();
                        return try buf.toOwnedSlice(a);
                    },
                    3 => return t.cancelLine(), // Ctrl-C
                    4 => { // Ctrl-D
                        if (buf.items.len == 0) return t.cancelLine();
                        if (cur < buf.items.len) buf.replaceRangeAssumeCapacity(cur, charLen(buf.items[cur..]), &.{});
                    },
                    1 => cur = 0, // Ctrl-A
                    5 => cur = buf.items.len, // Ctrl-E
                    21 => { // Ctrl-U
                        buf.replaceRangeAssumeCapacity(0, cur, &.{});
                        cur = 0;
                    },
                    23 => { // Ctrl-W
                        var s = cur;
                        while (s > 0 and buf.items[s - 1] == ' ') s -= 1;
                        while (s > 0 and buf.items[s - 1] != ' ') s -= 1;
                        buf.replaceRangeAssumeCapacity(s, cur - s, &.{});
                        cur = s;
                    },
                    127, 8 => if (cur > 0) { // Backspace
                        const s = prevChar(buf.items, cur);
                        buf.replaceRangeAssumeCapacity(s, cur - s, &.{});
                        cur = s;
                    },
                    27 => { // Esc, or the start of an escape sequence
                        if (i + 1 >= n) return t.cancelLine();
                        if (chunk[i + 1] != '[' and chunk[i + 1] != 'O') {
                            i += 1;
                            continue;
                        }
                        var j = i + 2;
                        while (j < n and !std.ascii.isAlphabetic(chunk[j]) and chunk[j] != '~') j += 1;
                        if (j >= n) break;
                        switch (chunk[j]) {
                            'C' => if (cur < buf.items.len) {
                                cur += charLen(buf.items[cur..]);
                            },
                            'D' => if (cur > 0) {
                                cur = prevChar(buf.items, cur);
                            },
                            'H' => cur = 0,
                            'F' => cur = buf.items.len,
                            '~' => if (chunk[i + 2] == '3' and cur < buf.items.len) { // Delete
                                buf.replaceRangeAssumeCapacity(cur, charLen(buf.items[cur..]), &.{});
                            },
                            else => {},
                        }
                        i = j;
                    },
                    else => if (c >= 32) {
                        try buf.insert(a, cur, c);
                        cur += 1;
                    },
                }
            }
        }
    }

    fn cancelLine(t: *Tty) ?[]const u8 {
        t.out.writeAll("\r\n") catch {};
        t.out.flush() catch {};
        return null;
    }

    /// Lets the user choose one of `options`; the first letter of each option
    /// selects it directly. Returns the chosen index, or null if cancelled.
    pub fn pick(t: *Tty, title: []const u8, options: []const []const u8) !?usize {
        if (!t.interactive) {
            const a = std.heap.page_allocator;
            const line = (try t.readLine(a, title, "")) orelse return null;
            defer a.free(line);
            const want = std.mem.trim(u8, line, " \t");
            for (options, 0..) |opt, i| {
                if (std.ascii.eqlIgnoreCase(want, opt) or
                    (want.len == 1 and std.ascii.toLower(want[0]) == opt[0])) return i;
            }
            return null;
        }

        try t.enterRaw();
        defer t.leaveRaw();
        try t.out.writeAll("\x1b[?25l"); // hide cursor
        defer {
            t.out.writeAll("\x1b[?25h") catch {};
            t.out.flush() catch {};
        }

        var sel: usize = 0;
        var drawn = false;
        const result: ?usize = loop: while (true) {
            if (drawn) try t.out.print("\x1b[{d}A", .{options.len + 1});
            drawn = true;
            try t.out.print("\r{s}{s}{s} {s}(↑/↓ or first letter, enter to pick, esc to cancel){s}\x1b[K\r\n", .{
                t.sty(cyan), title, t.sty(reset), t.sty(dim), t.sty(reset),
            });
            for (options, 0..) |opt, i| {
                if (i == sel) {
                    try t.out.print("\r  {s}❯ {s}{s}\x1b[K\r\n", .{ t.sty(bold), opt, t.sty(reset) });
                } else {
                    try t.out.print("\r    {s}\x1b[K\r\n", .{opt});
                }
            }
            try t.out.flush();

            var chunk: [16]u8 = undefined;
            const n = posix.read(fd, &chunk) catch break :loop null;
            if (n == 0) break :loop null;
            switch (chunk[0]) {
                '\r', '\n' => break :loop sel,
                3, 'q' => break :loop null,
                'k', 16 => sel = (sel + options.len - 1) % options.len,
                'j', 14 => sel = (sel + 1) % options.len,
                27 => {
                    if (n < 3) break :loop null;
                    switch (chunk[2]) {
                        'A' => sel = (sel + options.len - 1) % options.len,
                        'B' => sel = (sel + 1) % options.len,
                        else => {},
                    }
                },
                else => |c| for (options, 0..) |opt, i| {
                    if (std.ascii.toLower(c) == opt[0]) break :loop i;
                },
            }
        };

        // collapse the menu into a single summary line
        try t.out.print("\x1b[{d}A\r\x1b[J", .{options.len + 1});
        if (result) |i| try t.out.print("{s}{s}: {s}{s}\n", .{ t.sty(dim), title, options[i], t.sty(reset) });
        return result;
    }
};

pub const cyan = "\x1b[36m";
pub const dim = "\x1b[90m";
pub const bold = "\x1b[1m";
pub const reset = "\x1b[0m";

fn isCont(c: u8) bool {
    return c & 0xC0 == 0x80;
}

fn codepoints(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (!isCont(c)) n += 1;
    }
    return n;
}

fn charLen(s: []const u8) usize {
    var i: usize = 1;
    while (i < s.len and isCont(s[i])) i += 1;
    return i;
}

fn prevChar(s: []const u8, cur: usize) usize {
    var i = cur - 1;
    while (i > 0 and isCont(s[i])) i -= 1;
    return i;
}
