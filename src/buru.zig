//! buru: a small task tracker for `private/tasks.md` and `private/done.md`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mem = std.mem;

const build_options = @import("build_options");
const tasks = @import("tasks.zig");
const tui = @import("tui.zig");
const Priority = tasks.Priority;
const Id = tasks.Id;
const Doc = tasks.Doc;

const usage =
    \\usage: buru                  add a task (interactive)
    \\       buru h|m|l|b          add a high/medium/low/broken task (skips the menu)
    \\       buru done ID...       move task(s) to done.md
    \\       buru reopen ID...     move task(s) back to tasks.md
    \\       buru edit ID          edit an open task
    \\       buru move ID [h|m|l|b]  change a task's priority (new id)
    \\       buru status           show the progress bars
    \\       buru init             create private/tasks.md here
    \\       buru completions fish print fish completions
    \\       buru --version        print the version
    \\
;

const green = "\x1b[32m";
const yellow = "\x1b[33m";
const red = "\x1b[31m";
const magenta = "\x1b[35m";
const blue = "\x1b[34m";
const bold = tui.bold;
const dim = tui.dim;
const reset = tui.reset;

const Error = error{ Reported, Cancelled };

const Ctx = struct {
    io: Io,
    a: Allocator,
    out: *Io.Writer,
    err: *Io.Writer,
    color: bool,
    tty: *tui.Tty,

    fn sty(c: *const Ctx, code: []const u8) []const u8 {
        return if (c.color) code else "";
    }

    /// Prints an error line to stderr (keeping it ordered after stdout).
    fn warn(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        c.out.flush() catch {};
        c.err.print(fmt ++ "\n", args) catch {};
        c.err.flush() catch {};
    }

    fn fail(c: *Ctx, comptime fmt: []const u8, args: anytype) Error {
        c.warn(fmt, args);
        return error.Reported;
    }

    fn readLine(c: *Ctx, prompt: []const u8, initial: []const u8) ![]const u8 {
        const line = (try c.tty.readLine(c.a, prompt, initial)) orelse return error.Cancelled;
        return mem.trim(u8, line, " \t");
    }

    fn exists(c: *Ctx, path: []const u8) bool {
        Io.Dir.cwd().access(c.io, path, .{}) catch return false;
        return true;
    }

    fn readFile(c: *Ctx, path: []const u8) !?[]u8 {
        return Io.Dir.cwd().readFileAlloc(c.io, path, c.a, .limited(16 << 20)) catch |e| switch (e) {
            error.FileNotFound => null,
            else => e,
        };
    }

    fn writeFile(c: *Ctx, path: []const u8, data: []const u8) !void {
        try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = data });
    }
};

// --- project files ------------------------------------------------------------

const Project = struct {
    dir: []const u8,
    tasks_path: []const u8,
    done_path: []const u8,
    tasks: Doc,
    tasks_orig: []const u8,
    done: ?Doc,
    done_orig: []const u8 = "",

    /// Finds the private/ folder holding tasks.md, searching upwards.
    fn find(c: *Ctx) ![]const u8 {
        const cwd = try std.process.currentPathAlloc(c.io, c.a);
        var d: []const u8 = cwd;
        while (true) {
            if (mem.eql(u8, std.fs.path.basename(d), "private") and
                c.exists(try std.fs.path.join(c.a, &.{ d, "tasks.md" }))) return d;
            const p = try std.fs.path.join(c.a, &.{ d, "private" });
            if (c.exists(try std.fs.path.join(c.a, &.{ p, "tasks.md" }))) return p;
            d = std.fs.path.dirname(d) orelse break;
        }
        return c.fail("no private/tasks.md found; run `buru init` in the project root", .{});
    }

    fn open(c: *Ctx) !Project {
        return load(c, try find(c));
    }

    fn load(c: *Ctx, dir: []const u8) !Project {
        var p: Project = .{
            .dir = dir,
            .tasks_path = try std.fs.path.join(c.a, &.{ dir, "tasks.md" }),
            .done_path = try std.fs.path.join(c.a, &.{ dir, "done.md" }),
            .tasks = undefined,
            .tasks_orig = undefined,
            .done = null,
        };
        p.tasks_orig = (try c.readFile(p.tasks_path)) orelse "";
        p.tasks = try tasks.splitLines(c.a, p.tasks_orig);
        if (try c.readFile(p.done_path)) |text| {
            p.done_orig = text;
            p.done = try tasks.splitLines(c.a, text);
        }
        // record the current highest ids before anything moves around
        _ = try tasks.refresh(c.a, &p.tasks, p.doneDoc());
        return p;
    }

    fn doneDoc(p: *Project) ?*Doc {
        return if (p.done) |*d| d else null;
    }

    fn doneLines(p: *const Project) ?[]const []const u8 {
        return if (p.done) |d| d.items else null;
    }

    fn stats(p: *const Project, c: *Ctx) !tasks.Stats {
        return tasks.scan(c.a, p.tasks.items, p.doneLines());
    }

    fn ensureDone(p: *Project, c: *Ctx) !*Doc {
        if (p.done == null) {
            p.done = try tasks.splitLines(c.a, tasks.done_skeleton);
            try c.out.print("{s}created done.md{s}\n", .{ c.sty(green), c.sty(reset) });
        }
        return &p.done.?;
    }

    /// Redraws the progress block and writes whichever files changed.
    fn save(p: *Project, c: *Ctx) !tasks.Stats {
        const s = try tasks.refresh(c.a, &p.tasks, p.doneDoc());
        const t = try tasks.joinLines(c.a, p.tasks.items);
        if (!mem.eql(u8, t, p.tasks_orig)) try c.writeFile(p.tasks_path, t);
        if (p.done) |d| {
            const text = try tasks.joinLines(c.a, d.items);
            if (!mem.eql(u8, text, p.done_orig)) try c.writeFile(p.done_path, text);
        }
        return s;
    }
};

// --- commands -----------------------------------------------------------------

const pick_order = [_]Priority{ .high, .medium, .low, .broken };

fn pickPriority(c: *Ctx, title: []const u8, exclude: ?Priority) !Priority {
    var opts: [4]Priority = undefined;
    var names: [4][]const u8 = undefined;
    var n: usize = 0;
    for (pick_order) |p| {
        if (p == exclude) continue;
        opts[n] = p;
        names[n] = p.name();
        n += 1;
    }
    const i = (try c.tty.pick(title, names[0..n])) orelse return error.Cancelled;
    return opts[i];
}

/// "h5, M002 x" -> ids, with notes for unknown or invalid entries.
fn parseRelated(c: *Ctx, p: *const Project, input: []const u8) ![]Id {
    var ids: std.ArrayList(Id) = .empty;
    var it = mem.tokenizeAny(u8, input, " ,\t");
    while (it.next()) |raw| {
        const id = Id.parse(raw) orelse {
            c.warn("  ignoring '{s}' (not a task id)", .{raw});
            continue;
        };
        try ids.append(c.a, id);
        const known = tasks.contains(p.tasks.items, id) or
            (if (p.done) |d| tasks.contains(d.items, id) else false);
        if (!known) try c.out.print("{s}  note: {f} not found (added anyway){s}\n", .{ c.sty(yellow), id, c.sty(reset) });
    }
    return ids.items;
}

fn readPoints(c: *Ctx, points: *std.ArrayList([]const u8), header: []const u8) !void {
    try c.out.print("{s}{s}{s}\n", .{ c.sty(dim), header, c.sty(reset) });
    while (true) {
        const point = try c.readLine("  - ", "");
        if (point.len == 0) break;
        try points.append(c.a, point);
    }
}

fn cmdAdd(c: *Ctx, given: ?Priority) !void {
    var p = try Project.open(c);

    const priority = if (given) |g| blk: {
        try c.out.print("{s}priority: {s}{s}\n", .{ c.sty(dim), g.name(), c.sty(reset) });
        break :blk g;
    } else try pickPriority(c, "priority", null);

    const name = try c.readLine("name > ", "");
    if (name.len == 0) return c.fail("no name given, aborting", .{});

    var related: []Id = &.{};
    if (priority == .broken) {
        related = try parseRelated(c, &p, try c.readLine("related task(s), e.g. H005 M002 (empty for none) > ", ""));
    }

    var points: std.ArrayList([]const u8) = .empty;
    try readPoints(c, &points, "description points (empty line to finish)");

    const id = (try p.stats(c)).nextId(priority);
    const block = try tasks.buildBlock(c.a, tasks.detectIndent(p.tasks.items), id, name, related, points.items);
    try tasks.insert(c.a, &p.tasks, priority.header(), priority.headerBefore(), block);
    _ = try p.save(c);

    try c.out.print("{s}added {s}{f}{s} | {s}\n", .{ c.sty(green), c.sty(bold), id, c.sty(reset), name });
}

const MoveMode = enum { done, reopen };

/// Moves tasks between tasks.md and done.md. Returns false if any failed.
fn cmdMove(c: *Ctx, mode: MoveMode, raws: []const []const u8) !bool {
    if (raws.len == 0) return c.fail("usage: buru {s} ID...", .{@tagName(mode)});
    var p = try Project.open(c);
    if (mode == .reopen and p.done == null) return c.fail("no done.md yet, nothing to reopen", .{});

    var ok = true;
    for (raws) |raw| {
        const id = Id.parse(raw) orelse {
            c.warn("bad id: {s}", .{raw});
            ok = false;
            continue;
        };
        const src: *Doc = if (mode == .done) &p.tasks else &p.done.?;
        const dst_lines: ?[]const []const u8 = if (mode == .done) p.doneLines() else p.tasks.items;

        if (dst_lines) |lines| if (tasks.contains(lines, id)) {
            c.warn("{f} is already {s}", .{ id, if (mode == .done) "completed" else "open" });
            ok = false;
            continue;
        };

        const block = (try tasks.extract(c.a, src, id, if (mode == .done) .open else .done, if (mode == .done) 'x' else ' ')) orelse {
            c.warn("no {s} task {f}", .{ if (mode == .done) "open" else "completed", id });
            ok = false;
            continue;
        };
        const dst: *Doc = if (mode == .done) try p.ensureDone(c) else &p.tasks;
        try tasks.insert(c.a, dst, id.priority.header(), id.priority.headerBefore(), block);
        try c.out.print("{s}{s} {s}{f}{s}\n", .{
            c.sty(green), if (mode == .done) "completed" else "reopened", c.sty(bold), id, c.sty(reset),
        });
    }
    _ = try p.save(c);
    return ok;
}

fn cmdRepri(c: *Ctx, raw: ?[]const u8, target: ?[]const u8) !void {
    const r = raw orelse return c.fail("usage: buru move ID [h|m|l|b]", .{});
    const id = Id.parse(r) orelse return c.fail("bad id: {s}", .{r});
    var p = try Project.open(c);

    // the task can be open (tasks.md) or completed (done.md)
    const doc: *Doc = if (tasks.contains(p.tasks.items, id))
        &p.tasks
    else if (p.done != null and tasks.contains(p.done.?.items, id))
        &p.done.?
    else
        return c.fail("no task {f}", .{id});

    const priority = if (target) |t|
        Priority.parse(t) orelse return c.fail("bad priority: {s} (use h, m, l or b)", .{t})
    else
        try pickPriority(c, try std.fmt.allocPrint(c.a, "move {f} to", .{id}), id.priority);
    if (priority == id.priority) return c.fail("{f} is already {s}", .{ id, priority.name() });

    const new = (try p.stats(c)).nextId(priority);
    const block = (try tasks.extract(c.a, doc, id, .any, null)).?;
    try tasks.renameInBlock(c.a, block, id, new);
    try tasks.insert(c.a, doc, priority.header(), priority.headerBefore(), block);
    try tasks.renameRefs(c.a, &p.tasks, id, new);
    if (p.doneDoc()) |d| try tasks.renameRefs(c.a, d, id, new);
    _ = try p.save(c);

    try c.out.print("{s}moved {s}{f}{s}{s} → {s}{f}{s} ({s})\n", .{
        c.sty(green), c.sty(bold), id, c.sty(reset), c.sty(green), c.sty(bold), new, c.sty(reset), priority.name(),
    });
}

fn cmdEdit(c: *Ctx, raw: ?[]const u8) !void {
    const r = raw orelse return c.fail("usage: buru edit ID", .{});
    const id = Id.parse(r) orelse return c.fail("bad id: {s}", .{r});
    var p = try Project.open(c);

    const span = tasks.findBlock(p.tasks.items, id, .open) orelse {
        if (p.done) |d| if (tasks.contains(d.items, id))
            return c.fail("{f} is completed; reopen it first (buru reopen {f})", .{ id, id });
        return c.fail("no open task {f}", .{id});
    };
    const fields = try tasks.parseBlock(c.a, p.tasks.items[span.start..span.end]);

    try c.out.print("{s}editing {f} (clear a point to remove it){s}\n", .{ c.sty(dim), id, c.sty(reset) });
    const name = try c.readLine("name > ", fields.name);
    if (name.len == 0) return c.fail("no name given, aborting", .{});

    var related: std.ArrayList(Id) = .empty;
    if (id.priority == .broken or fields.has_related) {
        const current = try mem.join(c.a, " ", fields.related);
        try related.appendSlice(c.a, try parseRelated(c, &p, try c.readLine("related task(s) (empty for none) > ", current)));
    } else {
        for (fields.related) |t| if (Id.parse(t)) |rid| try related.append(c.a, rid);
    }

    var points: std.ArrayList([]const u8) = .empty;
    for (fields.points) |old| {
        const point = try c.readLine("  - ", old);
        if (point.len > 0) try points.append(c.a, point);
    }
    try readPoints(c, &points, "new points (empty line to finish)");

    const block = try tasks.buildBlock(c.a, tasks.detectIndent(p.tasks.items), id, name, related.items, points.items);
    try p.tasks.replaceRange(c.a, span.start, span.end - span.start, block);
    const before = p.tasks_orig;
    _ = try p.save(c);

    if (mem.eql(u8, before, try tasks.joinLines(c.a, p.tasks.items))) {
        try c.out.print("{s}no changes to {f}{s}\n", .{ c.sty(dim), id, c.sty(reset) });
    } else {
        try c.out.print("{s}edited {s}{f}{s} | {s}\n", .{ c.sty(green), c.sty(bold), id, c.sty(reset), name });
    }
}

fn cmdStatus(c: *Ctx) !void {
    var p = try Project.open(c);
    const s = try p.save(c);
    const od = s.totalOpen();
    const dd = s.totalDone();
    try printBar(c, "progress", green, dd, od + dd);
    try c.out.print("  {d:>3}%  ({d}/{d} done)\n\n", .{ tasks.percent(dd, od + dd), dd, od + dd });
    const colors = [_][]const u8{ red, magenta, yellow, blue };
    for (Priority.all, colors) |pr, col| {
        const i = @backingInt(pr);
        try printBar(c, pr.name(), col, s.done[i], s.done[i] + s.open[i]);
        try c.out.print("  {d:>3} done  {d:>3} open\n", .{ s.done[i], s.open[i] });
    }
}

fn printBar(c: *Ctx, label: []const u8, color: []const u8, d: u32, t: u32) !void {
    const f = tasks.barFill(d, t);
    try c.out.print("{s:<9} {s}", .{ label, c.sty(color) });
    for (0..tasks.bar_width) |i| {
        if (i == f) try c.out.writeAll(c.sty(dim));
        try c.out.writeAll(if (i < f) "█" else "░");
    }
    try c.out.writeAll(c.sty(reset));
}

fn cmdInit(c: *Ctx) !void {
    const cwd = try std.process.currentPathAlloc(c.io, c.a);
    const dir = if (mem.eql(u8, std.fs.path.basename(cwd), "private"))
        try c.a.dupe(u8, cwd)
    else
        try std.fs.path.join(c.a, &.{ cwd, "private" });
    const path = try std.fs.path.join(c.a, &.{ dir, "tasks.md" });
    if (c.exists(path)) return c.fail("{s} already exists", .{path});

    try Io.Dir.cwd().createDirPath(c.io, dir);
    try c.writeFile(path, tasks.tasks_skeleton);
    var p = try Project.load(c, dir);
    _ = try p.save(c);

    const rel = if (mem.startsWith(u8, path, cwd) and path.len > cwd.len) path[cwd.len + 1 ..] else path;
    try c.out.print("{s}created {s}{s}\n", .{ c.sty(green), rel, c.sty(reset) });

    // `git check-ignore` exits 1 for a tracked-but-not-ignored path in a repo
    const res = std.process.run(c.a, c.io, .{ .argv = &.{ "git", "check-ignore", "-q", path } }) catch return;
    if (res.term == .exited and res.term.exited == 1) {
        try c.out.print("{s}note: private/ is not git-ignored (add `private/*` to .gitignore){s}\n", .{ c.sty(yellow), c.sty(reset) });
    }
}

/// Hidden helper for shell completion: "ID\tname" per line.
fn cmdCompleteIds(c: *Ctx, which: []const u8) !void {
    const dir = Project.find(c) catch return;
    var p = try Project.load(c, dir);
    const want_open = !mem.eql(u8, which, "done");
    const want_done = !mem.eql(u8, which, "open");
    const docs = [_]?[]const []const u8{ p.tasks.items, p.doneLines() };
    for (docs) |maybe| {
        const lines = maybe orelse continue;
        for (lines) |line| {
            const t = tasks.parseTaskLine(line) orelse continue;
            if ((t.done and want_done) or (!t.done and want_open)) {
                try c.out.print("{f}\t{s}\n", .{ t.id, t.title() });
            }
        }
    }
}

const fish_completions =
    \\# fish completions for buru (generated by `buru completions fish`)
    \\set -l subs done reopen edit move status init help completions h m l b
    \\
    \\complete -c buru -f
    \\complete -c buru -n "not __fish_seen_subcommand_from $subs" -a done -d 'Move task(s) to done.md'
    \\complete -c buru -n "not __fish_seen_subcommand_from $subs" -a reopen -d 'Move task(s) back to tasks.md'
    \\complete -c buru -n "not __fish_seen_subcommand_from $subs" -a edit -d 'Edit an open task'
    \\complete -c buru -n "not __fish_seen_subcommand_from $subs" -a move -d 'Change a task\'s priority'
    \\complete -c buru -n "not __fish_seen_subcommand_from $subs" -a status -d 'Show the progress bars'
    \\complete -c buru -n "not __fish_seen_subcommand_from $subs" -a init -d 'Create private/tasks.md here'
    \\complete -c buru -n "not __fish_seen_subcommand_from $subs" -a help -d 'Show usage'
    \\complete -c buru -n "not __fish_seen_subcommand_from $subs" -a completions -d 'Print shell completions'
    \\complete -c buru -n "not __fish_seen_subcommand_from $subs" -a h -d 'Add a high priority task'
    \\complete -c buru -n "not __fish_seen_subcommand_from $subs" -a m -d 'Add a medium priority task'
    \\complete -c buru -n "not __fish_seen_subcommand_from $subs" -a l -d 'Add a low priority task'
    \\complete -c buru -n "not __fish_seen_subcommand_from $subs" -a b -d 'Add a broken task'
    \\
    \\complete -c buru -n '__fish_seen_subcommand_from done edit' -a '(buru __complete open)'
    \\complete -c buru -n '__fish_seen_subcommand_from reopen' -a '(buru __complete done)'
    \\complete -c buru -n '__fish_seen_subcommand_from completions' -a fish
    \\
    \\# buru move ID PRIORITY
    \\function __buru_move_arg --argument-names n
    \\    set -l tokens (commandline -xpc)
    \\    test "$tokens[2]" = move -a (count $tokens) -eq $n
    \\end
    \\complete -c buru -n '__buru_move_arg 2' -a '(buru __complete all)'
    \\complete -c buru -n '__buru_move_arg 3' -a 'h\thigh m\tmedium l\tlow b\tbroken'
    \\
;

fn run(c: *Ctx, args: []const []const u8) !bool {
    const cmd = if (args.len > 0) args[0] else "";
    const arg1: ?[]const u8 = if (args.len > 1) args[1] else null;
    const arg2: ?[]const u8 = if (args.len > 2) args[2] else null;

    if (cmd.len == 0) {
        try cmdAdd(c, null);
    } else if (Priority.parse(cmd)) |p| {
        try cmdAdd(c, p);
    } else if (mem.eql(u8, cmd, "done")) {
        return cmdMove(c, .done, args[1..]);
    } else if (mem.eql(u8, cmd, "reopen")) {
        return cmdMove(c, .reopen, args[1..]);
    } else if (mem.eql(u8, cmd, "edit")) {
        try cmdEdit(c, arg1);
    } else if (mem.eql(u8, cmd, "move")) {
        try cmdRepri(c, arg1, arg2);
    } else if (mem.eql(u8, cmd, "status")) {
        try cmdStatus(c);
    } else if (mem.eql(u8, cmd, "init")) {
        try cmdInit(c);
    } else if (mem.eql(u8, cmd, "completions")) {
        if (arg1 == null or !mem.eql(u8, arg1.?, "fish")) return c.fail("usage: buru completions fish", .{});
        try c.out.writeAll(fish_completions);
    } else if (mem.eql(u8, cmd, "__complete")) {
        try cmdCompleteIds(c, arg1 orelse "all");
    } else if (mem.eql(u8, cmd, "--version") or mem.eql(u8, cmd, "-V")) {
        try c.out.print("buru {s}\n", .{build_options.version});
    } else if (mem.eql(u8, cmd, "help") or mem.eql(u8, cmd, "-h") or mem.eql(u8, cmd, "--help")) {
        try c.out.writeAll(usage);
    } else {
        c.warn("{s}", .{usage[0 .. usage.len - 1]});
        return false;
    }
    return true;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);

    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var in_buf: [4096]u8 = undefined;
    var out_w = Io.File.stdout().writerStreaming(io, &out_buf);
    var err_w = Io.File.stderr().writerStreaming(io, &err_buf);
    var in_r = Io.File.stdin().readerStreaming(io, &in_buf);

    const stdout_tty = Io.File.stdout().isTty(io) catch false;
    const stdin_tty = Io.File.stdin().isTty(io) catch false;
    const no_color = if (init.environ_map.get("NO_COLOR")) |v| v.len > 0 else false;

    var tty: tui.Tty = .{
        .out = &out_w.interface,
        .lines = &in_r.interface,
        .interactive = stdin_tty and stdout_tty,
        .color = stdout_tty and !no_color,
    };
    var ctx: Ctx = .{
        .io = io,
        .a = a,
        .out = &out_w.interface,
        .err = &err_w.interface,
        .color = tty.color,
        .tty = &tty,
    };

    const ok = run(&ctx, args[1..]) catch |e| switch (e) {
        error.Reported, error.Cancelled => false,
        else => blk: {
            ctx.warn("buru: {s}", .{@errorName(e)});
            break :blk false;
        },
    };
    out_w.interface.flush() catch {};
    err_w.interface.flush() catch {};
    if (!ok) std.process.exit(1);
}

test {
    _ = tasks;
}
