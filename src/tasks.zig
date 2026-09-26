//! Pure text operations on `tasks.md` / `done.md`, kept free of I/O so they
//! can be unit tested. Every allocation goes through a caller-provided arena.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Priority = enum {
    broken,
    high,
    medium,
    low,

    pub const all = [_]Priority{ .broken, .high, .medium, .low };

    pub fn letter(p: Priority) u8 {
        return switch (p) {
            .broken => 'B',
            .high => 'H',
            .medium => 'M',
            .low => 'L',
        };
    }

    pub fn fromLetter(c: u8) ?Priority {
        return switch (std.ascii.toUpper(c)) {
            'B' => .broken,
            'H' => .high,
            'M' => .medium,
            'L' => .low,
            else => null,
        };
    }

    /// "h" / "high" (any case) -> .high, etc.
    pub fn parse(s: []const u8) ?Priority {
        if (s.len == 1) return fromLetter(s[0]);
        for (all) |p| {
            if (std.ascii.eqlIgnoreCase(s, @tagName(p))) return p;
        }
        return null;
    }

    pub fn name(p: Priority) []const u8 {
        return @tagName(p);
    }

    /// Section header in both files ("## high"; "## high priority" also matches).
    pub fn header(p: Priority) []const u8 {
        return switch (p) {
            .broken => "## broken",
            .high => "## high",
            .medium => "## medium",
            .low => "## low",
        };
    }

    /// New sections for `broken` go above `high`.
    pub fn headerBefore(p: Priority) ?[]const u8 {
        return if (p == .broken) "## high" else null;
    }
};

pub const Id = struct {
    priority: Priority,
    num: u32,

    /// "h5", "H005" -> H005. Fails for anything else.
    pub fn parse(raw: []const u8) ?Id {
        if (raw.len < 2) return null;
        const priority = Priority.fromLetter(raw[0]) orelse return null;
        for (raw[1..]) |c| if (!std.ascii.isDigit(c)) return null;
        const num = std.fmt.parseInt(u32, raw[1..], 10) catch return null;
        return .{ .priority = priority, .num = num };
    }

    pub fn eql(a: Id, b: Id) bool {
        return a.priority == b.priority and a.num == b.num;
    }

    pub fn format(id: Id, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{c}{d:0>3}", .{ id.priority.letter(), id.num });
    }

    fn key(id: Id) u64 {
        return (@as(u64, id.priority.letter()) << 32) | id.num;
    }
};

pub const TaskLine = struct {
    id: Id,
    done: bool,
    /// Everything after the closing backtick of the id.
    rest: []const u8,

    /// The task name without the " | **...**" decoration.
    pub fn title(t: TaskLine) []const u8 {
        var s = mem.trim(u8, t.rest, " \t");
        if (mem.startsWith(u8, s, "|")) s = mem.trim(u8, s[1..], " \t");
        if (mem.startsWith(u8, s, "**")) s = s[2..];
        if (mem.endsWith(u8, s, "**")) s = s[0 .. s.len - 2];
        return mem.trim(u8, s, " \t");
    }
};

/// Parses "- [ ] `H005` | **name**" (or "- [x] ...").
pub fn parseTaskLine(line: []const u8) ?TaskLine {
    if (!mem.startsWith(u8, line, "- [") or line.len < 8) return null;
    const done = switch (line[3]) {
        ' ' => false,
        'x', 'X' => true,
        else => return null,
    };
    if (!mem.startsWith(u8, line[4..], "] `")) return null;
    const end = mem.indexOfScalarPos(u8, line, 7, '`') orelse return null;
    const text = line[7..end];
    if (text.len < 2 or mem.indexOfScalar(u8, "BHML", text[0]) == null) return null;
    const id = Id.parse(text) orelse return null;
    return .{ .id = id, .done = done, .rest = line[end + 1 ..] };
}

pub const Doc = std.ArrayList([]const u8);

pub fn splitLines(a: Allocator, text: []const u8) !Doc {
    var doc: Doc = .empty;
    const body = if (mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    if (text.len == 0) return doc;
    var it = mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| try doc.append(a, line);
    return doc;
}

pub fn joinLines(a: Allocator, lines: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    for (lines) |line| {
        try out.writer.writeAll(line);
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn isBlank(line: []const u8) bool {
    for (line) |c| if (!std.ascii.isWhitespace(c)) return false;
    return true;
}

/// An indented, non-empty line: part of the task above it.
fn isContinuation(line: []const u8) bool {
    if (line.len == 0 or (line[0] != ' ' and line[0] != '\t')) return false;
    for (line) |c| if (c != ' ' and c != '\t') return true;
    return false;
}

fn normHeader(s: []const u8) []const u8 {
    var t = mem.trimEnd(u8, s, " \t\r");
    if (mem.endsWith(u8, t, " priority")) t = t[0 .. t.len - " priority".len];
    return mem.trimEnd(u8, t, " \t\r");
}

fn findHeader(lines: []const []const u8, header: []const u8) ?usize {
    const want = normHeader(header);
    for (lines, 0..) |line, i| {
        if (mem.eql(u8, normHeader(line), want)) return i;
    }
    return null;
}

pub const Want = enum { open, done, any };

pub fn contains(lines: []const []const u8, id: Id) bool {
    for (lines) |line| {
        if (parseTaskLine(line)) |t| if (t.id.eql(id)) return true;
    }
    return false;
}

/// Line range of task `id` plus its indented lines: `lines[start..end]`.
pub const Span = struct { start: usize, end: usize };

pub fn findBlock(lines: []const []const u8, id: Id, want: Want) ?Span {
    const s = for (lines, 0..) |line, i| {
        const t = parseTaskLine(line) orelse continue;
        const state_ok = switch (want) {
            .open => !t.done,
            .done => t.done,
            .any => true,
        };
        if (t.id.eql(id) and state_ok) break i;
    } else return null;
    var e = s + 1;
    while (e < lines.len and isContinuation(lines[e])) e += 1;
    return .{ .start = s, .end = e };
}

/// Removes task `id` (plus its indented lines) from `doc` and returns that
/// block, with its checkbox set to `new_mark` when given. Null if not found.
pub fn extract(a: Allocator, doc: *Doc, id: Id, want: Want, new_mark: ?u8) !?[][]const u8 {
    const lines = doc.items;
    const span = findBlock(lines, id, want) orelse return null;
    const s = span.start;
    const e = span.end - 1;

    const block = try a.dupe([]const u8, lines[s .. e + 1]);
    if (new_mark) |m| {
        const first = try a.dupe(u8, block[0]);
        first[3] = m;
        block[0] = first;
    }

    // drop the doubled-up blank line the removal would leave behind
    var cut_end = e;
    if (s > 0 and lines[s - 1].len == 0 and e + 1 < lines.len and lines[e + 1].len == 0) cut_end += 1;
    try doc.replaceRange(a, s, cut_end - s + 1, &.{});
    return block;
}

/// Appends `block` to the end of section `header`, creating the section if
/// missing (before `before` when that exists, otherwise at the end).
pub fn insert(a: Allocator, doc: *Doc, header: []const u8, before: ?[]const u8, block: []const []const u8) !void {
    const lines = doc.items;
    const n = lines.len;
    var out: Doc = .empty;

    if (findHeader(lines, header)) |h| {
        var e = h + 1;
        while (e < n and !mem.startsWith(u8, lines[e], "#")) e += 1;
        var s = h + 1;
        while (s < e and isBlank(lines[s])) s += 1;
        var p = e;
        while (p > s and isBlank(lines[p - 1])) p -= 1;

        try out.appendSlice(a, lines[0 .. h + 1]);
        try out.append(a, "");
        try out.appendSlice(a, lines[s..p]);
        try out.appendSlice(a, block);
        if (e < n) {
            try out.append(a, "");
            try out.appendSlice(a, lines[e..]);
        }
    } else if (if (before) |b| findHeader(lines, b) else null) |b| {
        try out.appendSlice(a, lines[0..b]);
        try out.appendSlice(a, &.{ header, "" });
        try out.appendSlice(a, block);
        try out.append(a, "");
        try out.appendSlice(a, lines[b..]);
    } else {
        try out.appendSlice(a, lines);
        if (n > 0 and lines[n - 1].len != 0) try out.append(a, "");
        try out.appendSlice(a, &.{ header, "" });
        try out.appendSlice(a, block);
    }
    doc.* = out;
}

/// The editable parts of a task block.
pub const Fields = struct {
    name: []const u8,
    related: []const []const u8,
    has_related: bool,
    points: []const []const u8,
};

pub fn parseBlock(a: Allocator, block: []const []const u8) !Fields {
    const t = parseTaskLine(block[0]).?;
    var related: std.ArrayList([]const u8) = .empty;
    var points: std.ArrayList([]const u8) = .empty;
    var has_related = false;
    for (block[1..]) |line| {
        if (isRelatedLine(line)) {
            has_related = true;
            related.clearRetainingCapacity();
            try collectIds(a, line, &related);
        } else {
            var p = mem.trimStart(u8, line, " \t");
            if (mem.startsWith(u8, p, "- ")) p = p[2..];
            try points.append(a, p);
        }
    }
    return .{
        .name = t.title(),
        .related = related.items,
        .has_related = has_related,
        .points = points.items,
    };
}

/// Builds "- [ ] `ID` | **name**", an optional "Related task(s)" line and
/// the description points.
pub fn buildBlock(a: Allocator, indent: []const u8, id: Id, name: []const u8, related: []const Id, points: []const []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, try std.fmt.allocPrint(a, "- [ ] `{f}` | **{s}**", .{ id, name }));
    if (related.len > 0) {
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.print("{s}- **Related task{s}:** [ ", .{ indent, if (related.len > 1) "s" else "" });
        for (related, 0..) |r, i| try w.writer.print("{s}`{f}`", .{ if (i > 0) ", " else "", r });
        try w.writer.writeAll(" ]");
        try out.append(a, try w.toOwnedSlice());
    }
    for (points) |p| try out.append(a, try std.fmt.allocPrint(a, "{s}- {s}", .{ indent, p }));
    return out.toOwnedSlice(a);
}

/// Replaces the id in a task's first line ("`H004`" -> "`B003`").
pub fn renameInBlock(a: Allocator, block: [][]const u8, old: Id, new: Id) !void {
    const old_s = try std.fmt.allocPrint(a, "`{f}`", .{old});
    const new_s = try std.fmt.allocPrint(a, "`{f}`", .{new});
    const first = block[0];
    const i = mem.indexOf(u8, first, old_s) orelse return;
    block[0] = try mem.concat(a, u8, &.{ first[0..i], new_s, first[i + old_s.len ..] });
}

/// Points every "Related task" reference to `old` at `new` instead.
pub fn renameRefs(a: Allocator, doc: *Doc, old: Id, new: Id) !void {
    const old_s = try std.fmt.allocPrint(a, "`{f}`", .{old});
    const new_s = try std.fmt.allocPrint(a, "`{f}`", .{new});
    for (doc.items) |*line| {
        if (isRelatedLine(line.*)) line.* = try mem.replaceOwned(u8, a, line.*, old_s, new_s);
    }
}

/// Indentation used by existing description points (default 4 spaces).
pub fn detectIndent(lines: []const []const u8) []const u8 {
    for (lines) |line| {
        var i: usize = 0;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i > 0 and mem.startsWith(u8, line[i..], "- ")) return line[0..i];
    }
    return "    ";
}

// --- progress block, "Related task" links and the id counter ---------------

pub const marker_start = "<!-- task:progress -->";
pub const marker_end = "<!-- /task:progress -->";
const last_ids_prefix = "<!-- task:last-ids ";

pub const Stats = struct {
    open: [4]u32 = @splat(0),
    done: [4]u32 = @splat(0),
    /// Highest number ever used per priority (files + stored counter).
    last: [4]u32 = @splat(0),

    pub fn totalOpen(s: Stats) u32 {
        var t: u32 = 0;
        for (s.open) |v| t += v;
        return t;
    }

    pub fn totalDone(s: Stats) u32 {
        var t: u32 = 0;
        for (s.done) |v| t += v;
        return t;
    }

    pub fn nextId(s: Stats, p: Priority) Id {
        return .{ .priority = p, .num = s.last[@backingInt(p)] + 1 };
    }
};

pub const Loc = enum { tasks, done };
const Where = std.AutoHashMapUnmanaged(u64, Loc);

fn scanInto(a: Allocator, lines: []const []const u8, loc: Loc, stats: *Stats, where: *Where) !void {
    for (lines) |line| {
        if (loc == .tasks and mem.startsWith(u8, line, last_ids_prefix)) {
            var it = mem.tokenizeScalar(u8, line[last_ids_prefix.len..], ' ');
            while (it.next()) |tok| {
                if (tok.len < 3 or tok[1] != '=') continue;
                const p = Priority.fromLetter(tok[0]) orelse continue;
                const n = std.fmt.parseInt(u32, tok[2..], 10) catch continue;
                const i = @backingInt(p);
                stats.last[i] = @max(stats.last[i], n);
            }
        }
        const t = parseTaskLine(line) orelse continue;
        const i = @backingInt(t.id.priority);
        try where.put(a, t.id.key(), loc);
        stats.last[i] = @max(stats.last[i], t.id.num);
        if (t.done) stats.done[i] += 1 else stats.open[i] += 1;
    }
}

pub fn scan(a: Allocator, tasks: []const []const u8, done: ?[]const []const u8) !Stats {
    var stats: Stats = .{};
    var where: Where = .empty;
    try scanInto(a, tasks, .tasks, &stats, &where);
    if (done) |d| try scanInto(a, d, .done, &stats, &where);
    return stats;
}

pub const bar_width = 20;

/// Number of filled cells in a `bar_width` bar.
pub fn barFill(d: u32, t: u32) usize {
    if (t == 0) return 0;
    return @intCast((@as(u64, d) * bar_width * 2 + t) / (2 * @as(u64, t)));
}

pub fn percent(d: u32, t: u32) u32 {
    if (t == 0) return 0;
    return @intCast((@as(u64, d) * 200 + t) / (2 * @as(u64, t)));
}

fn bar(a: Allocator, d: u32, t: u32) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const f = barFill(d, t);
    for (0..bar_width) |i| try out.writer.writeAll(if (i < f) "█" else "░");
    return out.toOwnedSlice();
}

fn isRelatedLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i == 0) return false;
    var rest = line[i..];
    const lead = "- **Related task";
    if (!mem.startsWith(u8, rest, lead)) return false;
    rest = rest[lead.len..];
    if (mem.startsWith(u8, rest, "(s)")) rest = rest[3..] else if (mem.startsWith(u8, rest, "s")) rest = rest[1..];
    return mem.startsWith(u8, rest, ":**");
}

/// Appends every "`H005`"-style id in `line` (without backticks) to `ids`.
fn collectIds(a: Allocator, line: []const u8, ids: *std.ArrayList([]const u8)) !void {
    var j: usize = 0;
    while (j < line.len) {
        if (line[j] == '`' and j + 2 < line.len and mem.indexOfScalar(u8, "BHML", line[j + 1]) != null) {
            var k = j + 2;
            while (k < line.len and std.ascii.isDigit(line[k])) k += 1;
            if (k > j + 2 and k < line.len and line[k] == '`') {
                try ids.append(a, line[j + 1 .. k]);
                j = k + 1;
                continue;
            }
        }
        j += 1;
    }
}

/// Rebuilds a "Related task" line so each id links to the file it lives in.
fn relink(a: Allocator, line: []const u8, where: *const Where) ![]const u8 {
    var i: usize = 0;
    while (line[i] == ' ' or line[i] == '\t') i += 1;
    const pre = line[0 .. i + 2]; // indentation + "- "

    var ids: std.ArrayList([]const u8) = .empty;
    try collectIds(a, line, &ids);
    if (ids.items.len == 0) return line;

    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{s}**Related task{s}:** [ ", .{ pre, if (ids.items.len > 1) "s" else "" });
    for (ids.items, 0..) |text, n| {
        if (n > 0) try w.writeAll(", ");
        const loc = if (Id.parse(text)) |id| where.get(id.key()) else null;
        if (loc) |l| {
            try w.print("[`{s}`]({s}.md)", .{ text, @tagName(l) });
        } else {
            try w.print("`{s}`", .{text});
        }
    }
    try w.writeAll(" ]");
    return out.toOwnedSlice();
}

/// Replaces (or inserts after the title) the managed block, drops stale id
/// counters and relinks "Related task" lines.
fn emit(a: Allocator, lines: []const []const u8, block: []const []const u8, where: *const Where) !Doc {
    var m: ?usize = null;
    var t: ?usize = null;
    for (lines, 0..) |line, i| {
        if (m == null and mem.eql(u8, line, marker_start)) m = i;
        if (t == null and mem.startsWith(u8, line, "# ")) t = i;
    }

    var out: Doc = .empty;
    if (m == null and t == null) {
        try out.appendSlice(a, block);
        try out.append(a, "");
    }
    var skip = false;
    for (lines, 0..) |line, i| {
        if (i == m) {
            skip = true;
            try out.appendSlice(a, block);
            continue;
        }
        if (skip) {
            if (mem.eql(u8, line, marker_end)) skip = false;
            continue;
        }
        if (mem.startsWith(u8, line, last_ids_prefix)) continue;
        try out.append(a, if (isRelatedLine(line)) try relink(a, line, where) else line);
        if (m == null and i == t) {
            try out.append(a, "");
            try out.appendSlice(a, block);
        }
    }
    return out;
}

/// Redraws the progress block in both files, relinks related ids and
/// records the highest id numbers. Returns the task counts.
pub fn refresh(a: Allocator, tasks: *Doc, done: ?*Doc) !Stats {
    var stats: Stats = .{};
    var where: Where = .empty;
    try scanInto(a, tasks.items, .tasks, &stats, &where);
    if (done) |d| try scanInto(a, d.items, .done, &stats, &where);

    const od = stats.totalOpen();
    const dd = stats.totalDone();

    var p: Doc = .empty;
    try p.appendSlice(a, &.{ marker_start, "```text" });
    try p.append(a, try std.fmt.allocPrint(a, "{s:<9} {s}  {d:>3}%  ({d}/{d} done)", .{
        "progress", try bar(a, dd, od + dd), percent(dd, od + dd), dd, od + dd,
    }));
    try p.append(a, "");
    for (Priority.all) |pr| {
        const i = @backingInt(pr);
        try p.append(a, try std.fmt.allocPrint(a, "{s:<9} {s}  {d:>3} done  {d:>3} open", .{
            pr.name(), try bar(a, stats.done[i], stats.done[i] + stats.open[i]), stats.done[i], stats.open[i],
        }));
    }
    try p.append(a, "```");
    if (done != null) try p.appendSlice(a, &.{ "", "[done tasks →](done.md)" });
    try p.append(a, marker_end);
    try p.append(a, try std.fmt.allocPrint(a, last_ids_prefix ++ "B={d} H={d} M={d} L={d} -->", .{
        stats.last[0], stats.last[1], stats.last[2], stats.last[3],
    }));
    tasks.* = try emit(a, tasks.items, p.items, &where);

    if (done) |d| {
        const q = [_][]const u8{
            marker_start,
            try std.fmt.allocPrint(a, "[← open tasks](tasks.md) · {d} completed", .{dd}),
            marker_end,
        };
        d.* = try emit(a, d.items, &q, &where);
    }
    return stats;
}

pub const tasks_skeleton =
    \\# tasks
    \\
    \\## broken
    \\
    \\## high
    \\
    \\## medium
    \\
    \\## low
    \\
;

pub const done_skeleton =
    \\# completed tasks
    \\
    \\## broken
    \\
    \\## high
    \\
    \\## medium
    \\
    \\## low
    \\
;

// --- tests ------------------------------------------------------------------

const testing = std.testing;

test "Id parse and format" {
    const id = Id.parse("h5").?;
    try testing.expectEqual(Priority.high, id.priority);
    try testing.expectEqual(@as(u32, 5), id.num);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("H005", try std.fmt.bufPrint(&buf, "{f}", .{id}));
    try testing.expect(Id.parse("x9") == null);
    try testing.expect(Id.parse("H") == null);
    try testing.expect(Id.parse("H1a") == null);
}

test "parseTaskLine" {
    const t = parseTaskLine("- [x] `M002` | **Conditional display**").?;
    try testing.expect(t.done);
    try testing.expectEqualStrings("Conditional display", t.title());
    try testing.expect(parseTaskLine("- [ ] `h002` | x") == null);
    try testing.expect(parseTaskLine("    - point") == null);
}

fn roundTrip(a: Allocator, text: []const u8, f: anytype) ![]u8 {
    var doc = try splitLines(a, text);
    try f(a, &doc);
    return joinLines(a, doc.items);
}

test "insert into empty and populated sections" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try splitLines(a, tasks_skeleton);
    try insert(a, &doc, "## high", null, &.{ "- [ ] `H001` | **a**", "    - x" });
    try insert(a, &doc, "## high", null, &.{"- [ ] `H002` | **b**"});
    try insert(a, &doc, "## low", null, &.{"- [ ] `L001` | **c**"});
    try testing.expectEqualStrings(
        \\# tasks
        \\
        \\## broken
        \\
        \\## high
        \\
        \\- [ ] `H001` | **a**
        \\    - x
        \\- [ ] `H002` | **b**
        \\
        \\## medium
        \\
        \\## low
        \\
        \\- [ ] `L001` | **c**
        \\
    , try joinLines(a, doc.items));
}

test "insert matches '## high priority' and creates missing broken section" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try splitLines(a, "# tasks\n\n## high priority\n\n- [ ] `H001` | **a**\n");
    try insert(a, &doc, "## high", null, &.{"- [ ] `H002` | **b**"});
    try insert(a, &doc, "## broken", "## high", &.{"- [ ] `B001` | **c**"});
    try testing.expectEqualStrings(
        \\# tasks
        \\
        \\## broken
        \\
        \\- [ ] `B001` | **c**
        \\
        \\## high priority
        \\
        \\- [ ] `H001` | **a**
        \\- [ ] `H002` | **b**
        \\
    , try joinLines(a, doc.items));
}

test "extract removes block and doubled blank line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try splitLines(a, "## high\n\n- [ ] `H001` | **a**\n    - x\n\n## low\n");
    const block = (try extract(a, &doc, Id.parse("H1").?, .open, 'x')).?;
    try testing.expectEqual(@as(usize, 2), block.len);
    try testing.expectEqualStrings("- [x] `H001` | **a**", block[0]);
    try testing.expectEqualStrings("## high\n\n## low\n", try joinLines(a, doc.items));
    try testing.expect((try extract(a, &doc, Id.parse("H1").?, .open, null)) == null);
}

test "refresh adds progress block, links and id counter" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tasks = try splitLines(a,
        \\# tasks
        \\
        \\## broken
        \\
        \\- [ ] `B001` | **bug**
        \\    - **Related task:** [ `H001`, `L002` ]
        \\
    );
    var done = try splitLines(a, "# completed tasks\n\n## high\n\n- [x] `H001` | **a**\n");
    const stats = try refresh(a, &tasks, &done);
    try testing.expectEqual(@as(u32, 1), stats.totalOpen());
    try testing.expectEqual(@as(u32, 1), stats.totalDone());

    const text = try joinLines(a, tasks.items);
    try testing.expect(mem.indexOf(u8, text, "    - **Related tasks:** [ [`H001`](done.md), `L002` ]") != null);
    try testing.expect(mem.indexOf(u8, text, "<!-- task:last-ids B=1 H=1 M=0 L=0 -->") != null);
    try testing.expect(mem.indexOf(u8, text, " 50%  (1/2 done)") != null);

    // idempotent
    _ = try refresh(a, &tasks, &done);
    try testing.expectEqualStrings(text, try joinLines(a, tasks.items));
    const dtext = try joinLines(a, done.items);
    try testing.expect(mem.indexOf(u8, dtext, "[← open tasks](tasks.md) · 1 completed") != null);
}

test "stored counter prevents id reuse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tasks = try splitLines(a, "# tasks\n<!-- task:last-ids B=0 H=7 M=0 L=0 -->\n- [ ] `H002` | **a**\n");
    const stats = try scan(a, tasks.items, null);
    try testing.expect(stats.nextId(.high).eql(.{ .priority = .high, .num = 8 }));
    try testing.expect(stats.nextId(.low).eql(.{ .priority = .low, .num = 1 }));
}

test "renameRefs only touches related lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try splitLines(a, "- [ ] `B001` | **H004 `H004`**\n    - **Related task:** [ [`H004`](tasks.md) ]\n");
    try renameRefs(a, &doc, Id.parse("H4").?, Id.parse("B3").?);
    try testing.expectEqualStrings("- [ ] `B001` | **H004 `H004`**", doc.items[0]);
    try testing.expectEqualStrings("    - **Related task:** [ [`B003`](tasks.md) ]", doc.items[1]);
}

test "parseBlock and buildBlock round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = [_][]const u8{
        "- [ ] `B002` | **Settings broken**",
        "    - **Related tasks:** [ [`L009`](done.md), [`M002`](tasks.md) ]",
        "    - first",
        "    - second",
    };
    const f = try parseBlock(a, &block);
    try testing.expectEqualStrings("Settings broken", f.name);
    try testing.expect(f.has_related);
    try testing.expectEqual(@as(usize, 2), f.related.len);
    try testing.expectEqualStrings("M002", f.related[1]);
    try testing.expectEqual(@as(usize, 2), f.points.len);

    const rebuilt = try buildBlock(a, "    ", Id.parse("B2").?, f.name, &.{ Id.parse("L9").?, Id.parse("M2").? }, f.points);
    try testing.expectEqualStrings("    - **Related tasks:** [ `L009`, `M002` ]", rebuilt[1]);
    try testing.expectEqualStrings("    - second", rebuilt[3]);
}
