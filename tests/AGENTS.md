# Test Harness — Agent Guide

Nuances discovered while building this harness. Read before extending it.

## Unix socket path-length limit (sun_path)

**Symptom:** `Harness.waitForSocket` times out; socket file never appears.

**Cause:** `sun_path` is 104 chars on macOS (108 on Linux).
`std.testing.tmpDir` realpaths to something like
`/Users/.../zmx/.zig-cache/tmp/<16-char-rand>/`. Add `/s/<session>` and
long checkout paths push past the limit → `bind()` fails (silently or
with ENAMETOOLONG, which zmx may not surface).

**Fix in `Harness.initIn`:** when `socket_dir` > 85 chars, create a
short symlink under `/tmp` and use that as `ZMX_DIR`. The real
directory still lives under the testing tmpdir for cleanup.

## Ambient `ZMX_*` leaks divert `attach`

`attach` consults `getSeshNameFromEnv()` first; if `ZMX_SESSION` is set
(e.g. you're running the suite from inside a zmx session), it tries
`switchSesh` against the *isolated* socket dir and fails with
`SessionNotFound`. `Harness.initIn` strips every `ZMX_*` var before
re-adding `ZMX_DIR`.

## `forkpty` already does setsid()

`spawnPty` uses `cross.forkpty`, which internally `setsid()`s the child
and assigns the slave as its controlling terminal. Don't add a second
`setsid`/`setpgid` — it'll EPERM. The daemon `setsid()`s itself again
post-fork anyway, and `Harness.deinit` sweeps via `zmx kill` against
socket names rather than pgid.

## `Session` needs no client-side PTY

The daemon allocates its **own** PTY for the shell (`Daemon.spawnPty`).
`Session.create` therefore uses plain `Harness.zmx("run", name, "-d", …)`
with `stdin = .Close`. `spawnPty` is reserved for tests that
specifically exercise an attached client (`e2e/defensive.zig`).

## `zmx run` is blocking; `-d` returns on Ack

Non-detached `zmx run name cmd` tails the daemon until `.TaskComplete`
and `posix.exit(cmd_exit_code)`. `Session.run` returns that code
directly — there is no separate `zmx wait` round-trip.

`Session.create` uses `-d` so the create client returns on `.Ack`, then
`zmx wait` consumes the bootstrap `true`'s task marker before the first
test `run()`.

## `ZMX_DIR` is the socket dir, not its parent

```zig
socket_dir = $ZMX_DIR  (directly)
log_dir    = $ZMX_DIR/logs
```

`Harness.initIn` sets `ZMX_DIR={socket_dir}`, not `{root}`. When
sweeping in `deinit` / `listSockets`, filter by
`.kind == .unix_domain_socket` — `logs/` lives there too.

## zmx shell-quotes args with shell metacharacters

`zmx run sess "(exit 0)"` → `shellNeedsQuoting` sees `(` → arg becomes
`'(exit 0)'` → `command not found` (exit 127). For test commands use
`true`, `false`, `sleep 0.1`.

## Don't use `exit N` as a test command

`exit N` kills the **interactive shell** → daemon sees PTY EOF →
shutdown → socket deleted. State-machine invariants then fail on
"session should still exist". Use `true`/`false`.

## Error-message assertions are fragile

Zig's error-return traces print source lines using paths baked into
debug info. From a different CWD they don't resolve → output is
`???:?:?: 0x... in _foo (???)` with no error name.

**Assert on behavior:** exit codes, `listSockets()`, filesystem state.

## `std.posix.waitpid` panics on `ECHILD`

`Harness.zmx` reaps its own child via `Child.wait()`. `Harness.deinit`
must therefore only reap pids it hasn't already waited — and uses
`std.c.waitpid` directly so an already-reaped pid is a harmless `-1`
rather than `unreachable`.

## ArenaAllocator must not be moved after first use

`arena.allocator()` returns an `Allocator` holding `&arena`. If `arena`
is later moved (struct copy), every existing `Allocator` dangles. In
`Harness.initIn` the arena is initialized **in place** on the
gpa-allocated struct before any allocation happens.
