const std = @import("std");
const posix = std.posix;
const t = std.testing;
const harness = @import("../harness.zig");

// Smoke tests for invocation patterns that touch defensive code paths.
// "Doesn't crash" assertions — underlying failure modes are UB / latent /
// race-dependent and don't reproduce reliably black-box.

test "attach with non-tty stdin doesn't crash on tcgetattr failure" {
    var h = try harness.Harness.init(t.allocator);
    defer h.deinit();

    // Harness.zmx sets stdin_behavior = .Close → not a TTY.
    const r = try h.zmx(2000, &.{ "attach", "nontty" });

    try t.expect(std.ascii.indexOfIgnoreCase(r.out, "panic") == null);
    try t.expect(std.mem.indexOf(u8, r.out, "reached unreachable") == null);
}

test "attach with many args doesn't overflow child argv buffer" {
    var h = try harness.Harness.init(t.allocator);
    defer h.deinit();
    const alloc = h.arena.allocator();

    var argv = try std.ArrayList([:0]const u8).initCapacity(alloc, 71);
    try argv.append(alloc, try alloc.dupeZ(u8, h.bin));
    try argv.appendSlice(alloc, &.{ "attach", "manyargs", "echo" });
    var i: u32 = 0;
    while (i < 67) : (i += 1) {
        try argv.append(alloc, try std.fmt.allocPrintSentinel(alloc, "a{d}", .{i}, 0));
    }

    var pty = try harness.spawnPty(h, argv.items);
    defer pty.close();

    // Socket appearing means the daemon survived fork+exec with >64 argv.
    try h.waitForSocket("manyargs", 3000);
    posix.kill(pty.pid, posix.SIG.KILL) catch {};
}

test "daemon survives SIGKILLed client (SIGPIPE ignored)" {
    var h = try harness.Harness.init(t.allocator);
    defer h.deinit();
    const alloc = h.arena.allocator();

    var s = try harness.Session.create(h, "survivor");
    defer s.kill();

    // Second client, SIGKILLed mid-attach. The daemon's next write to that
    // socket would deliver SIGPIPE if not ignored.
    var pty = try harness.spawnPty(h, &.{
        try alloc.dupeZ(u8, h.bin), "attach", "survivor",
    });
    defer pty.close();

    std.Thread.sleep(300 * std.time.ns_per_ms);
    posix.kill(pty.pid, posix.SIG.KILL) catch {};
    _ = posix.waitpid(pty.pid, 0);

    const got = try s.run("true", 5000);
    try t.expectEqual(@as(i32, 0), got);
}
