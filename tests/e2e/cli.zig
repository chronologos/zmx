const std = @import("std");
const t = std.testing;
const harness = @import("../harness.zig");

// Assert on behavior (exit code, filesystem state) — not error strings.
// Zig's error-return-trace text depends on CWD and build mode.

test "path traversal in session name is rejected" {
    var h = try harness.Harness.init(t.allocator);
    defer h.deinit();

    const evil = try std.fs.path.join(h.arena.allocator(), &.{
        std.fs.path.dirname(h.socket_dir).?, "evil",
    });
    defer std.fs.cwd().deleteFile(evil) catch {};

    const r = try h.zmx(2000, &.{ "attach", "../evil" });

    try t.expect(r.code != 0);
    try t.expectError(error.FileNotFound, std.fs.cwd().access(evil, .{}));
    try t.expectEqual(@as(usize, 0), (try h.listSockets()).len);
}

test "invalid session names are rejected" {
    var h = try harness.Harness.init(t.allocator);
    defer h.deinit();

    // Embedded NUL is not testable via argv: execve truncates at NUL so
    // zmx would see a valid 1-char name. Covered at the IPC layer instead.
    for ([_][]const u8{ "a/b", "..", "." }) |name| {
        const r = try h.zmx(1000, &.{ "attach", name });
        try t.expect(r.code != 0);
        try t.expectEqual(@as(usize, 0), (try h.listSockets()).len);
    }
}

test "history --vt with no session arg errors cleanly" {
    var h = try harness.Harness.init(t.allocator);
    defer h.deinit();

    const r = try h.zmx(2000, &.{ "history", "--vt" });

    try t.expect(std.ascii.indexOfIgnoreCase(r.out, "panic") == null);
    try t.expect(r.code != 0);
}

test "wait on nonexistent session does not exit 0" {
    var h = try harness.Harness.init(t.allocator);
    defer h.deinit();

    const r = try h.zmx(6000, &.{ "wait", "ghost" });

    try t.expect(r.code != 0);
    if (r.code == 2) {
        try t.expect(std.mem.indexOf(u8, r.out, "no matching sessions") != null);
    }
}
