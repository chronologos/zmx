const std = @import("std");
const t = std.testing;
const harness = @import("../harness.zig");

// Coverage-guided state-machine: the fuzzer hands us bytes, we decode
// them as a Run/Kill/Check op tape and replay against a real daemon
// while keeping an in-memory model. After every step, the system must
// agree with the model.
//
// `zig build test-e2e` (no --fuzz) runs once per seed corpus entry, so
// the hand-picked scenarios below are exercised deterministically in CI.

const Op = enum(u2) { run, kill, check };
const names = [_][:0]const u8{ "sa", "sb" };

const Model = struct {
    h: *harness.Harness,
    sessions: [names.len]?*harness.Session = @splat(null),
    last_exit: [names.len]?i32 = @splat(null),

    fn ensure(m: *Model, idx: usize) !void {
        if (m.sessions[idx] != null) return;
        const s = try m.h.arena.allocator().create(harness.Session);
        s.* = try harness.Session.create(m.h, names[idx]);
        m.sessions[idx] = s;
        m.last_exit[idx] = null;
    }

    fn run(m: *Model, idx: usize, want: i32) !void {
        try m.ensure(idx);
        const cmd = if (want == 0) "true" else "false";
        const got = try m.sessions[idx].?.run(cmd, 5000);
        if (got != want) {
            std.log.err("run({s},{s}) → wait={d} want={d} (state drift)", .{ names[idx], cmd, got, want });
            return error.StateDrift;
        }
        m.last_exit[idx] = want;
    }

    fn kill(m: *Model, arg: u8) !void {
        var live: [names.len]usize = undefined;
        var n: usize = 0;
        for (m.sessions, 0..) |s, i| if (s != null) {
            live[n] = i;
            n += 1;
        };
        if (n == 0) return;
        const idx = live[arg % n];
        m.sessions[idx].?.kill();
        m.sessions[idx] = null;
        m.last_exit[idx] = null;

        const path = try m.h.socketPath(names[idx]);
        try harness.waitFor(2000, struct {
            p: []const u8,
            pub fn check(s: @This()) bool {
                std.fs.cwd().access(s.p, .{}) catch return true;
                return false;
            }
        }{ .p = path });
    }

    fn check(m: *Model) !void {
        const listed = try m.h.listSockets();
        for (m.sessions, 0..) |s, i| if (s != null) {
            var found = false;
            for (listed) |sock| if (std.mem.eql(u8, sock, names[i])) {
                found = true;
            };
            if (!found) return error.ModelHasSessionButNoSocket;
        };
        outer: for (listed) |sock| {
            for (names, 0..) |name, i| if (std.mem.eql(u8, sock, name)) {
                if (m.sessions[i] != null) continue :outer;
            };
            std.log.err("leaked socket: {s}", .{sock});
            return error.LeakedSocket;
        }
    }

    fn close(m: *Model) void {
        for (&m.sessions) |*s| if (s.*) |sess| {
            sess.kill();
            s.* = null;
        };
    }
};

fn fuzzSession(_: void, tape: []const u8) anyerror!void {
    var h = try harness.Harness.init(t.allocator);
    defer h.deinit();
    var m = Model{ .h = h };
    defer m.close();

    var i: usize = 0;
    while (i + 1 < tape.len) : (i += 2) {
        const op: Op = @enumFromInt(tape[i] & 0b11);
        const arg = tape[i + 1];
        std.log.debug("step {d}: {s} arg={d}", .{ i / 2, @tagName(op), arg });
        switch (op) {
            .run => try m.run(arg % names.len, arg & 1),
            .kill => try m.kill(arg),
            .check => try m.check(),
        }
        try m.check();
    }
}

// Three deterministic scenarios that double as the fuzz seed corpus:
//   1. create → run(0) → kill → recreate → run(1)
//   2. interleaved sa/sb runs
//   3. kill with no live sessions (no-op)
const seed_tapes: []const []const u8 = &.{
    &[_]u8{ 0, 0, 1, 0, 0, 1 },
    &[_]u8{ 0, 0, 0, 3, 0, 1, 0, 2 },
    &[_]u8{ 1, 0, 2, 0 },
};

test "fuzz session state machine" {
    try std.testing.fuzz({}, fuzzSession, .{ .corpus = seed_tapes });
}
