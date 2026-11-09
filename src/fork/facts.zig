//! What the fork adds to the daemon. Upstream's loop.zig gets one line, marked `// [fork]`,
//! which calls `install`; everything else is here.
//!
//! The daemon already runs every byte of pty output through a terminal parser. This file sets
//! that parser's callbacks, remembers the last value of each thing a program told the terminal
//! about itself, and publishes the lot as one small text file per session. See FACTS.md for the
//! format. Readers watch the directory; nothing connects to the daemon to get this.
//!
//! Rules for this file:
//! - Mechanism only. A running daemon cannot be upgraded, so anything that is a matter of
//!   opinion (what counts as unread, what to show, how often) belongs in the reader.
//! - State, not events. The file is the whole truth, replaced atomically. A reader that misses
//!   ten changes and reads once is still right, and a slow reader can never slow the daemon.
//! - Never fail the daemon. Every error here means "no facts", silently.
//! - Imports: std, ghostty-vt and the Daemon type, so upstream refactors can't reach in.
//!
//! One daemon is one process is one session, so file-level state is the natural owner.
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Daemon = @import("../loop.zig").Daemon;
const c = std.c;

const Handler = ghostty_vt.TerminalStream.Handler;
const Report = ghostty_vt.osc.Command.ProgramStatus.Report;
const Progress = ghostty_vt.osc.Command.ProgressReport;
const Notification = ghostty_vt.StreamAction.ShowDesktopNotification;
const SemanticPrompt = ghostty_vt.SemanticPrompt;

/// Least recently updated goes first when a program reports on more things than this.
const max_records = 64;
/// The probe reply is ~80 bytes; refuse to queue it behind a backlog the shell isn't reading.
const max_reply_backlog = 64 * 1024;

/// When a fact last changed: `seq` orders changes within this daemon's life, `at` is wall-clock
/// milliseconds for people. `seq == 0` means the fact is absent.
const Stamp = struct {
    seq: u64 = 0,
    at: i64 = 0,
};

/// Program-controlled text, cut to a fixed size on a UTF-8 boundary.
fn Text(comptime max: usize) type {
    return struct {
        buf: [max]u8 = undefined,
        len: usize = 0,

        fn get(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }

        /// Returns whether the stored text changed.
        fn set(self: *@This(), s: []const u8) bool {
            var n = @min(s.len, max);
            if (n < s.len) while (n > 0 and s[n] & 0xC0 == 0x80) : (n -= 1) {};
            if (std.mem.eql(u8, self.get(), s[0..n])) return false;
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
            return true;
        }
    };
}

const Record = struct {
    id: []u8,
    body: []u8,
    /// `working` and `blocked` describe a program that is running, so they end with it.
    ends_with_program: bool,
    stamp: Stamp,
};

const State = struct {
    seq: u64 = 0,
    records: std.ArrayList(Record) = .empty,
    bell: Stamp = .{},
    bells: u64 = 0,
    mark: Stamp = .{},
    step: SemanticPrompt.Kind = .invalid,
    exit: Stamp = .{},
    code: i32 = 0,
    progress: Stamp = .{},
    progress_state: Progress.State = .remove,
    progress_value: ?u8 = null,
    title: Stamp = .{},
    title_text: Text(256) = .{},
    pwd: Stamp = .{},
    pwd_text: Text(1024) = .{},
    notify: Stamp = .{},
    notify_title: Text(128) = .{},
    notify_body: Text(512) = .{},

    fn touch(self: *State) Stamp {
        self.seq += 1;
        return .{ .seq = self.seq, .at = clock() };
    }

    /// Removing a fact is a change too, so it moves `seq` without leaving a stamp behind.
    fn forget(self: *State, stamp: *Stamp) bool {
        if (stamp.seq == 0) return false;
        stamp.* = .{};
        self.seq += 1;
        return true;
    }

    fn drop(self: *State, i: usize) void {
        const r = self.records.orderedRemove(i);
        gpa.free(r.id);
        gpa.free(r.body);
        self.seq += 1;
    }

    fn dropWhere(self: *State, ctx: anytype, comptime pred: fn (@TypeOf(ctx), Record) bool) bool {
        var any = false;
        var i = self.records.items.len;
        while (i > 0) {
            i -= 1;
            if (pred(ctx, self.records.items[i])) {
                self.drop(i);
                any = true;
            }
        }
        return any;
    }

    fn deinit(self: *State) void {
        for (self.records.items) |r| {
            gpa.free(r.id);
            gpa.free(r.body);
        }
        self.records.deinit(gpa);
        self.* = .{};
    }

    fn render(self: *const State, out: *std.ArrayList(u8), h: Head) !void {
        try out.print(gpa, "v=1 pid={d} born={d} seq={d}\n", .{ h.pid, h.born, self.seq });
        if (self.bell.seq != 0) try line(out, "bell", self.bell, "{d}", .{self.bells});
        if (self.mark.seq != 0) try line(out, "mark", self.mark, "{s}", .{@tagName(self.step)});
        if (self.exit.seq != 0) try line(out, "exit", self.exit, "{d}", .{self.code});
        if (self.progress.seq != 0) {
            if (self.progress_value) |v|
                try line(out, "progress", self.progress, "{s} {d}", .{ @tagName(self.progress_state), v })
            else
                try line(out, "progress", self.progress, "{s}", .{@tagName(self.progress_state)});
        }
        if (self.title.seq != 0) try line(out, "title", self.title, "{b64}", .{self.title_text.get()});
        if (self.pwd.seq != 0) try line(out, "pwd", self.pwd, "{s}", .{self.pwd_text.get()});
        if (self.notify.seq != 0) {
            // OSC 9 has no title. "-" keeps the column count fixed and is not valid base64.
            if (self.notify_title.len == 0)
                try line(out, "notify", self.notify, "- {b64}", .{self.notify_body.get()})
            else
                try line(out, "notify", self.notify, "{b64} {b64}", .{ self.notify_title.get(), self.notify_body.get() });
        }
        for (self.records.items) |r| try line(out, "status", r.stamp, "{s}", .{r.body});
    }
};

const Head = struct { pid: i32, born: u64 };

fn line(out: *std.ArrayList(u8), kind: []const u8, s: Stamp, comptime fmt: []const u8, args: anytype) !void {
    try out.print(gpa, "{s} {d} {d} ", .{ kind, s.seq, s.at });
    try out.print(gpa, fmt ++ "\n", args);
}

/// Where the file goes. Directory descriptors, not paths: they are checked once, at install,
/// and nothing that happens to the path afterwards can redirect a write.
const Sink = struct {
    now: c.fd_t,
    tmp: c.fd_t,
    name: [:0]const u8,
};

var gpa: std.mem.Allocator = undefined;
var state: State = .{};
var head: Head = .{ .pid = 0, .born = 0 };
var sink: ?Sink = null;
var reply_to: ?*std.ArrayList(u8) = null;
var scratch: std.ArrayList(u8) = .empty;
var name_buf: [256]u8 = undefined;
var clock: *const fn () i64 = &wallClock;

pub fn install(stream: anytype, daemon: *Daemon, alloc: std.mem.Allocator) void {
    gpa = alloc;
    head = .{ .pid = daemon.pid, .born = daemon.created_at };
    reply_to = &daemon.pty_write_buf;
    sink = openSink(daemon.cfg.socket_dir, daemon.session_name);
    hook(stream);
    publish();
}

fn hook(stream: anytype) void {
    const e = &stream.handler.effects;
    e.write_pty = &writePty;
    e.program_status = &programStatus;
    e.progress_report = &progressReport;
    e.semantic_prompt = &semanticPrompt;
    e.bell = &bell;
    e.title_changed = &titleChanged;
    e.pwd_changed = &pwdChanged;
    e.desktop_notification = &desktopNotification;
    e.reset = &reset;
}

// MARK: callbacks

/// `write_pty` carries the parser's reply to every query a program makes. The attached terminal
/// answers all the others, so only the OSC 7501 reply may through or the program would hear two
/// answers. This one the daemon owns: it is the only party that is always there, and it holds
/// the records. Queued during the read that parsed the probe, so it is ahead of any reply the
/// terminal (or the daemon's own detached fallback) gives to a query sent after it.
fn writePty(_: *Handler, data: []const u8) void {
    if (!std.mem.startsWith(u8, data, "\x1b]7501;")) return;
    const buf = reply_to orelse return;
    if (buf.items.len + data.len > max_reply_backlog) return;
    buf.appendSlice(gpa, data) catch {};
}

fn under(root: []const u8, r: Record) bool {
    if (root.len == 0) return true;
    if (!std.mem.startsWith(u8, r.id, root)) return false;
    return r.id.len == root.len or r.id[root.len] == '/';
}

fn same(id: []const u8, r: Record) bool {
    return std.mem.eql(u8, r.id, id);
}

fn endsWithProgram(_: void, r: Record) bool {
    return r.ends_with_program;
}

fn programStatus(_: *Handler, report: Report) void {
    const id = report.readOption(.id) orelse "";
    if (report.state == .clear) {
        if (state.dropWhere(id, under)) publish();
        return;
    }
    // The parser has validated the body. This is the file format defending itself.
    if (!printable(report.data)) return;
    for (state.records.items) |r| {
        if (same(id, r) and std.mem.eql(u8, r.body, report.data)) return;
    }
    const new_id = gpa.dupe(u8, id) catch return;
    const new_body = gpa.dupe(u8, report.data) catch return gpa.free(new_id);
    state.records.ensureUnusedCapacity(gpa, 1) catch {
        gpa.free(new_id);
        gpa.free(new_body);
        return;
    };
    _ = state.dropWhere(id, same);
    if (state.records.items.len >= max_records) state.drop(0);
    state.records.appendAssumeCapacity(.{
        .id = new_id,
        .body = new_body,
        .ends_with_program = report.state == .working or report.state == .blocked,
        .stamp = state.touch(),
    });
    publish();
}

fn progressReport(_: *Handler, p: Progress) void {
    // `remove` is kept, stamped, once there was something to remove: for a program that only
    // speaks OSC 9;4 it is the one sign that work finished. A `remove` out of nowhere is not.
    if (state.progress.seq == 0 and p.state == .remove) return;
    if (state.progress.seq != 0 and state.progress_state == p.state and state.progress_value == p.progress) return;
    state.progress_state = p.state;
    state.progress_value = p.progress;
    state.progress = state.touch();
    publish();
}

fn semanticPrompt(_: *Handler, p: SemanticPrompt) void {
    // Right-hand and continuation prompts are drawn mid-command-line; they start nothing.
    if (p.kind == .prompt_start and p.prompt_kind != .primary) return;
    var changed = false;
    switch (p.kind) {
        .invalid => return,
        // The shell is back, so whatever was running is not.
        .prompt_start => changed = state.dropWhere({}, endsWithProgram),
        .input_start => {},
        .output_start => changed = state.forget(&state.exit),
        .command_end => if (p.exit_code) |code| {
            state.code = code;
            state.exit = state.touch();
            changed = true;
        },
    }
    if (state.mark.seq == 0 or state.step != p.kind) {
        state.step = p.kind;
        state.mark = state.touch();
        changed = true;
    }
    if (changed) publish();
}

fn bell(_: *Handler) void {
    state.bells += 1;
    state.bell = state.touch();
    publish();
}

fn titleChanged(h: *Handler) void {
    const t = h.terminal.getTitle() orelse "";
    if (t.len == 0) {
        if (state.forget(&state.title)) publish();
        return;
    }
    if (!state.title_text.set(t) and state.title.seq != 0) return;
    state.title = state.touch();
    publish();
}

fn pwdChanged(h: *Handler) void {
    const p = h.terminal.getPwd() orelse "";
    if (p.len == 0 or p.len > state.pwd_text.buf.len or !printable(p)) {
        if (state.forget(&state.pwd)) publish();
        return;
    }
    if (!state.pwd_text.set(p) and state.pwd.seq != 0) return;
    state.pwd = state.touch();
    publish();
}

fn desktopNotification(_: *Handler, n: Notification) void {
    // Not deduplicated: the same words twice are two requests for attention.
    _ = state.notify_title.set(n.title);
    _ = state.notify_body.set(n.body);
    state.notify = state.touch();
    publish();
}

/// Full reset (RIS). The parser has already sent a `clear` and a progress `remove`.
fn reset(_: *Handler) void {
    var any = state.forget(&state.title);
    any = state.forget(&state.pwd) or any;
    any = state.forget(&state.mark) or any;
    any = state.forget(&state.exit) or any;
    if (any) publish();
}

// MARK: output

/// No spaces, no control bytes: safe as the last column of a line.
fn printable(s: []const u8) bool {
    for (s) |b| if (b <= 0x20 or b == 0x7f) return false;
    return true;
}

fn wallClock() i64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// A directory that is really a directory and really ours. `fchmod` succeeds only for the
/// owner, so it is the ownership check and the mode fix in one call. This matters when the
/// socket directory falls back to /tmp, where anyone could have made ours first.
fn ownDir(parent: c.fd_t, path: [*:0]const u8) ?c.fd_t {
    _ = c.mkdirat(parent, path, 0o700);
    const fd = c.openat(parent, path, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0) return null;
    if (c.fchmod(fd, 0o700) != 0) {
        _ = c.close(fd);
        return null;
    }
    return fd;
}

fn openSink(socket_dir: []const u8, session: []const u8) ?Sink {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // Trimmed, or "dir/" would put ".facts" inside the socket directory as a bogus session.
    const base = std.mem.trimEnd(u8, socket_dir, "/");
    if (base.len == 0) return null;
    const root_path = std.fmt.bufPrintSentinel(&buf, "{s}.facts", .{base}, 0) catch return null;
    const name = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{session}, 0) catch return null;
    const root = ownDir(c.AT.FDCWD, root_path) orelse return null;
    defer _ = c.close(root);
    // Separate directories because any name, ".x.tmp" included, is a legal session name, and
    // so that a watcher on `now` only ever sees finished files arrive.
    const tmp = ownDir(root, "tmp") orelse return null;
    const now = ownDir(root, "now") orelse {
        _ = c.close(tmp);
        return null;
    };
    return .{ .now = now, .tmp = tmp, .name = name };
}

fn publish() void {
    const s = sink orelse return;
    scratch.clearRetainingCapacity();
    state.render(&scratch, head) catch return;
    const fd = c.openat(s.tmp, s.name, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, @as(c_uint, 0o600));
    if (fd < 0) return;
    var rest: []const u8 = scratch.items;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n <= 0) break;
        rest = rest[@intCast(n)..];
    }
    _ = c.close(fd);
    if (rest.len == 0 and c.renameat(s.tmp, s.name, s.now, s.name) == 0) return;
    _ = c.unlinkat(s.tmp, s.name, 0);
}

// MARK: tests

const testing = std.testing;

const Rig = struct {
    term: ghostty_vt.Terminal,
    replies: std.ArrayList(u8) = .empty,

    var ticks: i64 = 0;
    fn tick() i64 {
        ticks += 1;
        return ticks;
    }

    fn init(self: *Rig) !void {
        gpa = testing.allocator;
        state = .{};
        head = .{ .pid = 7, .born = 9 };
        sink = null;
        ticks = 1000;
        clock = &tick;
        self.* = .{ .term = try .init(testing.io, gpa, .{ .cols = 80, .rows = 24 }) };
        reply_to = &self.replies;
    }

    fn deinit(self: *Rig) void {
        state.deinit();
        scratch.deinit(gpa);
        scratch = .empty;
        self.replies.deinit(gpa);
        self.term.deinit(gpa);
        reply_to = null;
        clock = &wallClock;
    }

    fn expect(_: *Rig, want: []const u8) !void {
        scratch.clearRetainingCapacity();
        try state.render(&scratch, head);
        try testing.expectEqualStrings(want, scratch.items);
    }
};

test "facts: a report replaces its record, clear removes a subtree" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var s = rig.term.vtStream();
    defer s.deinit();
    hook(&s);

    s.nextSlice("\x1b]7501;state=working:app=demo\x1b\\");
    s.nextSlice("\x1b]7501;state=working:id=a/b\x1b\\");
    s.nextSlice("\x1b]7501;state=working:id=a/bc\x1b\\");
    s.nextSlice("\x1b]7501;state=working:id=a\x07");
    s.nextSlice("\x1b]7501;state=done:app=demo\x1b\\");
    try rig.expect(
        \\v=1 pid=7 born=9 seq=6
        \\status 2 1002 state=working:id=a/b
        \\status 3 1003 state=working:id=a/bc
        \\status 4 1004 state=working:id=a
        \\status 6 1005 state=done:app=demo
        \\
    );
    s.nextSlice("\x1b]7501;state=clear:id=a/b\x1b\\");
    try rig.expect(
        \\v=1 pid=7 born=9 seq=7
        \\status 3 1003 state=working:id=a/bc
        \\status 4 1004 state=working:id=a
        \\status 6 1005 state=done:app=demo
        \\
    );
    s.nextSlice("\x1b]7501;state=clear:id=a\x1b\\");
    try rig.expect("v=1 pid=7 born=9 seq=9\nstatus 6 1005 state=done:app=demo\n");
    s.nextSlice("\x1b]7501;state=clear\x1b\\");
    try rig.expect("v=1 pid=7 born=9 seq=10\n");
}

test "facts: nothing changes, nothing moves" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var s = rig.term.vtStream();
    defer s.deinit();
    hook(&s);

    s.nextSlice("\x1b]9;4;0\x1b\\");
    for (0..3) |_| {
        s.nextSlice("\x1b]7501;state=idle:app=demo\x1b\\");
        s.nextSlice("\x1b]9;4;3\x1b\\");
        s.nextSlice("\x1b]2;hi\x1b\\");
        s.nextSlice("\x1b]7501;state=clear:id=nope\x1b\\");
    }
    try rig.expect(
        \\v=1 pid=7 born=9 seq=3
        \\progress 2 1002 indeterminate
        \\title 3 1003 aGk=
        \\status 1 1001 state=idle:app=demo
        \\
    );
}

test "facts: only the 7501 reply reaches the program" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var s = rig.term.vtStream();
    defer s.deinit();
    hook(&s);

    s.nextSlice("\x1b[c\x1b[5n\x1b]7501;?\x1b\\\x1b[c\x1b[>q");
    try testing.expectEqualStrings(
        "\x1b]7501;" ++ ghostty_vt.osc.program_status.query_reply ++ "\x1b\\",
        rig.replies.items,
    );
    try rig.replies.appendNTimes(gpa, 'x', max_reply_backlog);
    const before = rig.replies.items.len;
    s.nextSlice("\x1b]7501;?\x1b\\");
    try testing.expectEqual(before, rig.replies.items.len);
}

test "facts: a new prompt ends working and blocked, keeps done and the exit code" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var s = rig.term.vtStream();
    defer s.deinit();
    hook(&s);

    s.nextSlice("\x1b]133;C\x1b\\");
    s.nextSlice("\x1b]7501;state=working:id=w\x1b\\");
    s.nextSlice("\x1b]7501;state=blocked:id=b:kind=auth\x1b\\");
    s.nextSlice("\x1b]7501;state=done:id=d\x1b\\");
    s.nextSlice("\x1b]7501;state=error:id=e\x1b\\");
    s.nextSlice("\x1b]133;D;3\x1b\\");
    s.nextSlice("\x1b]133;A\x1b\\");
    try rig.expect(
        \\v=1 pid=7 born=9 seq=10
        \\mark 10 1008 prompt_start
        \\exit 6 1006 3
        \\status 4 1004 state=done:id=d
        \\status 5 1005 state=error:id=e
        \\
    );
    s.nextSlice("\x1b]133;C\x1b\\");
    try rig.expect(
        \\v=1 pid=7 born=9 seq=12
        \\mark 12 1009 output_start
        \\status 4 1004 state=done:id=d
        \\status 5 1005 state=error:id=e
        \\
    );
}

test "facts: progress, bell, pwd, notification, then a full reset" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var s = rig.term.vtStream();
    defer s.deinit();
    hook(&s);

    s.nextSlice("\x1b]9;4;1;40\x1b\\\x07\x07");
    s.nextSlice("\x1b]7;file://host/tmp/a%20b\x1b\\");
    s.nextSlice("\x1b]777;notify;Title;Body text\x1b\\");
    s.nextSlice("\x1b]7501;state=error\x1b\\");
    try rig.expect(
        \\v=1 pid=7 born=9 seq=6
        \\bell 3 1003 2
        \\progress 1 1001 set 40
        \\pwd 4 1004 file://host/tmp/a%20b
        \\notify 5 1005 VGl0bGU= Qm9keSB0ZXh0
        \\status 6 1006 state=error
        \\
    );
    s.nextSlice("\x1bc");
    try rig.expect(
        \\v=1 pid=7 born=9 seq=9
        \\bell 3 1003 2
        \\progress 7 1007 remove
        \\notify 5 1005 VGl0bGU= Qm9keSB0ZXh0
        \\
    );
}

test "facts: the oldest record makes room, long text is cut on a character" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var s = rig.term.vtStream();
    defer s.deinit();
    hook(&s);

    var buf: [64]u8 = undefined;
    for (0..max_records + 2) |i| {
        s.nextSlice(try std.fmt.bufPrint(&buf, "\x1b]7501;state=done:id=r{d}\x1b\\", .{i}));
    }
    try testing.expectEqual(max_records, state.records.items.len);
    try testing.expectEqualStrings("r2", state.records.items[0].id);

    var t: Text(5) = .{};
    try testing.expect(t.set("ab\u{20AC}\u{20AC}"));
    try testing.expectEqualStrings("ab\u{20AC}", t.get());
    try testing.expect(!t.set("ab\u{20AC}\u{20AC}"));
}

test "facts: files land in now/, a directory that is not ours is refused" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Trailing slash on purpose.
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/sock/", .{path_buf[0..n]});

    sink = openSink(dir, ".odd name.tmp") orelse return error.TestUnexpectedNull;
    defer {
        _ = c.close(sink.?.now);
        _ = c.close(sink.?.tmp);
        sink = null;
    }
    var s = rig.term.vtStream();
    defer s.deinit();
    hook(&s);
    s.nextSlice("\x1b]7501;state=working\x1b\\");

    var got: [256]u8 = undefined;
    const text = try tmp.dir.readFile(testing.io, "sock.facts/now/.odd name.tmp", &got);
    try testing.expectEqualStrings("v=1 pid=7 born=9 seq=1\nstatus 1 1001 state=working\n", text);
    try testing.expectError(error.FileNotFound, tmp.dir.readFile(testing.io, "sock.facts/tmp/.odd name.tmp", &got));

    // A symlink where the directory should be.
    try tmp.dir.symLink(testing.io, "sock.facts", "evil.facts", .{});
    const evil = try std.fmt.bufPrint(&dir_buf, "{s}/evil", .{path_buf[0..n]});
    try testing.expectEqual(null, openSink(evil, "x"));
}
