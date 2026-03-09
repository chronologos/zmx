//! Isolated process-orchestration primitives for black-box e2e testing
//! of the installed `zmx` binary.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const cross = @import("cross");
const build_opts = @import("build_opts");

const Allocator = std.mem.Allocator;

/// Locates the binary under test. ZMX_BIN env var overrides the build-time
/// install path so a release binary can be exercised in place.
pub fn zmxBin(alloc: Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(alloc, "ZMX_BIN")) |p| {
        return p;
    } else |_| {}
    return alloc.dupe(u8, build_opts.zmx_bin);
}

// sun_path is 104 chars on macOS, 108 on Linux. Leave headroom for
// "/{session-name}". Long std.testing.tmpDir paths can exceed this.
const max_socket_dir_len = 85;

/// Polls `pred.check()` every 20ms until true or `timeout_ms` elapses.
pub fn waitFor(timeout_ms: u64, pred: anytype) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (pred.check()) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

pub const Result = struct {
    out: []const u8,
    /// >=0 = exit code, -1 = timeout/killed, -2 = signal
    code: i32,
};

pub const Harness = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    bin: []const u8 = undefined,
    socket_dir: []const u8 = undefined,
    /// short symlink used as ZMX_DIR when socket_dir > sun_path limit
    short_link: ?[]const u8 = null,
    env: std.process.EnvMap = undefined,
    pids: std.ArrayList(posix.pid_t) = .{},
    tmp: ?std.testing.TmpDir = null,

    pub fn init(gpa: Allocator) !*Harness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try tmp.dir.realpath(".", &buf);
        const h = try initIn(gpa, root);
        h.tmp = tmp;
        return h;
    }

    /// Like `init` but rooted at `root`. Caller cleans up `root`.
    /// The arena is initialized in-place on the gpa-owned struct so its
    /// address is stable; an Allocator taken from a stack-local arena
    /// would dangle once this function returns.
    pub fn initIn(gpa: Allocator, root: []const u8) !*Harness {
        const h = try gpa.create(Harness);
        errdefer gpa.destroy(h);
        h.* = .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
        const alloc = h.arena.allocator();
        errdefer h.arena.deinit();

        h.bin = try zmxBin(alloc);
        h.socket_dir = try std.fs.path.join(alloc, &.{ root, "s" });
        const log_dir = try std.fs.path.join(alloc, &.{ h.socket_dir, "logs" });
        try std.fs.cwd().makePath(log_dir);

        var zmx_dir: []const u8 = h.socket_dir;
        if (h.socket_dir.len > max_socket_dir_len) {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "/tmp/zmxh{d}", .{std.time.nanoTimestamp() & 0xffffff});
            try posix.symlink(h.socket_dir, name);
            h.short_link = try alloc.dupe(u8, name);
            zmx_dir = h.short_link.?;
        }

        // Strip every ZMX_* var so an ambient zmx session (ZMX_SESSION,
        // ZMX_SESSION_PREFIX, …) can't leak in and divert `attach` into
        // switchSesh against the isolated socket dir.
        h.env = try std.process.getEnvMap(alloc);
        var it = h.env.iterator();
        var to_remove: std.ArrayList([]const u8) = .{};
        while (it.next()) |e| {
            if (std.mem.startsWith(u8, e.key_ptr.*, "ZMX_")) {
                try to_remove.append(alloc, e.key_ptr.*);
            }
        }
        for (to_remove.items) |k| h.env.remove(k);
        try h.env.put("ZMX_DIR", zmx_dir);

        return h;
    }

    pub fn deinit(h: *Harness) void {
        // h.pids holds only spawnPty children (zmx() reaps its own).
        // std.posix.waitpid panics on ECHILD; use libc directly so an
        // already-reaped pid is harmless.
        for (h.pids.items) |pid| {
            posix.kill(pid, posix.SIG.KILL) catch {};
            var status: c_int = 0;
            _ = std.c.waitpid(pid, &status, 0);
        }
        // Daemons setsid() away; sweep by socket name.
        if (h.listSockets()) |names| {
            for (names) |name| _ = h.zmx(2000, &.{ "kill", name }) catch {};
        } else |_| {}
        if (h.short_link) |link| posix.unlink(link) catch {};
        if (h.tmp) |*tmp| tmp.cleanup();
        h.arena.deinit();
        h.gpa.destroy(h);
    }

    /// Runs a zmx subcommand to completion (or `timeout_ms`) and returns
    /// combined stdout+stderr. The daemon dups its stdio to /dev/null
    /// post-fork, so EOF on our pipes arrives when the *direct* child exits.
    pub fn zmx(h: *Harness, timeout_ms: u64, args: []const []const u8) !Result {
        const alloc = h.arena.allocator();
        var argv = try std.ArrayList([]const u8).initCapacity(alloc, args.len + 1);
        try argv.append(alloc, h.bin);
        try argv.appendSlice(alloc, args);

        var child = std.process.Child.init(argv.items, alloc);
        child.env_map = &h.env;
        child.stdin_behavior = .Close;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        var out: std.ArrayList(u8) = .{};
        var fds = [_]posix.pollfd{
            .{ .fd = child.stdout.?.handle, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = child.stderr.?.handle, .events = posix.POLL.IN, .revents = 0 },
        };
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        var open: u8 = 2;
        var killed = false;
        var buf: [4096]u8 = undefined;
        while (open > 0) {
            const remain = deadline - std.time.milliTimestamp();
            if (remain <= 0 and !killed) {
                posix.kill(child.id, posix.SIG.KILL) catch {};
                killed = true;
            }
            _ = posix.poll(&fds, if (killed) 100 else @intCast(@max(remain, 1))) catch 0;
            inline for (&fds) |*fd| {
                if (fd.fd >= 0 and fd.revents != 0) {
                    const n = posix.read(fd.fd, &buf) catch 0;
                    if (n == 0) {
                        fd.fd = -1;
                        open -= 1;
                    } else try out.appendSlice(alloc, buf[0..n]);
                }
            }
        }
        const term = try child.wait();
        const code: i32 = if (killed) -1 else switch (term) {
            .Exited => |c| @intCast(c),
            .Signal, .Stopped, .Unknown => -2,
        };
        return .{ .out = out.items, .code = code };
    }

    pub fn listSockets(h: *Harness) ![]const []const u8 {
        const alloc = h.arena.allocator();
        var dir = try std.fs.openDirAbsolute(h.socket_dir, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        var names: std.ArrayList([]const u8) = .{};
        while (try it.next()) |e| {
            if (e.kind == .unix_domain_socket) {
                try names.append(alloc, try alloc.dupe(u8, e.name));
            }
        }
        return names.items;
    }

    pub fn socketPath(h: *Harness, name: []const u8) ![]const u8 {
        return std.fs.path.join(h.arena.allocator(), &.{ h.socket_dir, name });
    }

    pub fn waitForSocket(h: *Harness, name: []const u8, timeout_ms: u64) !void {
        const path = try h.socketPath(name);
        return waitFor(timeout_ms, struct {
            p: []const u8,
            pub fn check(s: @This()) bool {
                const st = std.fs.cwd().statFile(s.p) catch return false;
                return st.kind == .unix_domain_socket;
            }
        }{ .p = path });
    }

    /// Builds the null-terminated envp array execvpeZ wants.
    fn envp(h: *Harness) ![*:null]?[*:0]const u8 {
        const alloc = h.arena.allocator();
        var list = try alloc.allocSentinel(?[*:0]const u8, h.env.count(), null);
        var it = h.env.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) {
            list[i] = (try std.fmt.allocPrintSentinel(alloc, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }, 0)).ptr;
        }
        return list.ptr;
    }
};

pub const PtyChild = struct {
    pid: posix.pid_t,
    master: posix.fd_t,

    pub fn close(p: *PtyChild) void {
        if (p.master >= 0) {
            posix.close(p.master);
            p.master = -1;
        }
    }
};

/// Spawns `argv` under a PTY via libc forkpty. The child gets the slave
/// as stdin/out/err and a controlling terminal; we hold the master.
/// A detached thread drains the master so PTY output doesn't back up
/// and block the child shell.
pub fn spawnPty(h: *Harness, argv: []const [:0]const u8) !PtyChild {
    const alloc = h.arena.allocator();
    var argz = try alloc.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |a, i| argz[i] = a.ptr;
    const env = try h.envp();

    var master: c_int = -1;
    const pid = cross.forkpty(&master, null, null, null);
    if (pid < 0) return error.ForkPtyFailed;
    if (pid == 0) {
        const err = posix.execvpeZ(argv[0], argz.ptr, env);
        std.log.err("execvpeZ: {s}", .{@errorName(err)});
        posix.exit(127);
    }
    try h.pids.append(alloc, @intCast(pid));
    _ = try posix.fcntl(master, posix.F.SETFL, @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));

    const t = try std.Thread.spawn(.{}, drain, .{@as(posix.fd_t, master)});
    t.detach();

    return .{ .pid = @intCast(pid), .master = master };
}

fn drain(fd: posix.fd_t) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        _ = posix.poll(&fds, -1) catch return;
        if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) return;
        const n = posix.read(fd, &buf) catch return;
        if (n == 0) return;
    }
}

pub const Session = struct {
    h: *Harness,
    name: [:0]const u8,

    /// Creates a session via detached `zmx run <name> -d true`. The daemon
    /// allocates its own PTY for the shell, so the create client needs no
    /// controlling terminal. Then waits for the socket and for the bootstrap
    /// `true` to settle so the first `run()` doesn't race the per-session
    /// task marker.
    pub fn create(h: *Harness, name: [:0]const u8) !Session {
        const r1 = try h.zmx(5000, &.{ "run", name, "-d", "true" });
        if (r1.code != 0) {
            std.log.err("create {s}: run -d exited {d}: {s}", .{ name, r1.code, r1.out });
            return error.SessionCreateFailed;
        }
        try h.waitForSocket(name, 3000);
        const r2 = try h.zmx(5000, &.{ "wait", name });
        if (r2.code != 0) {
            std.log.err("create {s}: bootstrap wait exited {d}: {s}", .{ name, r2.code, r2.out });
            return error.BootstrapWaitFailed;
        }
        return .{ .h = h, .name = name };
    }

    /// Sends `cmd` and returns its exit code. `zmx run` (non-detached) tails
    /// until `.TaskComplete` and exits with the command's status.
    pub fn run(s: *Session, cmd: []const u8, timeout_ms: u64) !i32 {
        const r = try s.h.zmx(timeout_ms, &.{ "run", s.name, cmd });
        if (r.code < 0) return error.RunTimeout;
        return r.code;
    }

    pub fn kill(s: *Session) void {
        _ = s.h.zmx(2000, &.{ "kill", s.name }) catch {};
    }
};
