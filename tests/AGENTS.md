# Test Harness — Agent Guide

Nuances discovered while building this harness. Read before extending it.

## Unix socket path-length limit (sun_path)

**Symptom:** `NewSession` times out waiting for socket; socket file never
appears. Only affects tests with long names.

**Cause:** `sun_path` is 104 chars on macOS (108 on Linux). `t.TempDir()`
returns something like `/var/folders/.../T/<TestNameWithFullCamelCase>NNN/001/`.
Add `/s/<session>` and you're at 105+ chars → `bind()` fails (silently or
with ENAMETOOLONG, which zmx may not surface clearly).

**Fix in `NewIn()`:** when `socketDir` > 85 chars, create a short symlink
under `/tmp` and use that as `ZMX_DIR`. The real directory still lives
under `tmp_path` for cleanup. The symlink is removed in `Close()`.

**If you see this again:** either shorten the test name, or check that
`NewIn`'s symlink fallback is firing.

## The daemon-inherits-pipe problem

**Symptom:** `go test` hangs at 30s/60s timeout, goroutine dump shows
`cmd.Wait()` blocked in `syscall.Wait4`.

**Cause:** zmx commands that create a session (`attach`, first `run`) fork a
daemon that inherits our captured stdout/stderr pipes. `cmd.Wait()` blocks
until **both** (a) the process exits AND (b) copying goroutines for
captured pipes return (EOF). The daemon keeps the write end open → never
EOFs → hang.

**Fix pattern in `Harness.Zmx()`:** allocate `os.Pipe()` pairs instead of
`cmd.Stdout = &buf`. We own both ends, so on timeout we close the read end
→ any holder (including daemon) gets EPIPE on next write → our reader
goroutine returns → no leak.

**Don't forget to `<-done` after `cmd.Process.Kill()`** — the process is
dead but the Wait goroutine needs draining or it leaks across rapid
iterations and eventually hits the outer test timeout.

## PTY + process-group conflict on macOS

**Symptom:** `pty.Start: fork/exec ...: operation not permitted`.

**Cause:** `creack/pty.Start()` internally does `setsid()` on the child to
give it a controlling terminal. Also setting `SysProcAttr{Setpgid: true}`
conflicts on macOS.

**Fix:** Don't set Setpgid for PTY-spawned processes. The daemon setsid()s
itself anyway (`ensureSession` → child branch), and `Harness.Close()` sweeps
via `zmx kill` against socket names rather than pgid.

## `ZMX_DIR` is the socket dir, not its parent

zmx's `Cfg.init`:
```zig
socket_dir = $ZMX_DIR  (directly)
log_dir    = $ZMX_DIR/logs
```

`Harness.NewIn()` must set `ZMX_DIR={SocketDir}`, not `{root}`. When
sweeping sockets in `Close()` or `ListSockets()`, filter by
`ModeSocket` — the `logs/` subdir lives there too.

## zmx shell-quotes args with shell metacharacters

`zmx run sess "(exit 0)"` → `shellNeedsQuoting` sees `(` → arg becomes
`'(exit 0)'` → shell sees a literal string → `command not found` (exit 127).

**For test commands, use simple names:** `true`, `false`, `sleep 0.1`.
Avoid `()`, `|`, `$`, etc. If you need complex commands, quote them
yourself and pass as a single arg zmx won't re-quote.

## Don't use `exit N` as a test command

`exit N` kills the **interactive shell**, which makes the daemon see PTY
EOF → shutdown → socket deleted. State-machine invariants then fail on
"session should still exist". Use `true`/`false` instead.

## Bootstrap-task synchronization in `NewSession()`

`NewSession()` waits (via `zmx wait`) for the bootstrap `true` command's
task-marker before returning. Without this, the first test `Run()` would
race with the bootstrap: the protocol has no per-invocation nonces, so
two overlapping `zmx run` commands on the same session can be confused.
This is a protocol limitation, not a harness bug — but tests must not
trip over it accidentally.

If you see intermittent `wait` timeouts or wrong exit codes on the
*first* `Run()` after session creation, check this synchronization is
intact.

## Error-message assertions are fragile

Zig's error-return traces print the offending source line **by reading
source files at runtime** using paths baked into debug info. When the test
runs from a different CWD, paths don't resolve → output is
`???:?:?: 0x... in _foo (???)` with no error name.

**Assert on behavior:** exit codes, `ListSockets()`, filesystem state. Not
on `"InvalidSessionName" in output`.

## State-machine tempdir per iteration

`rapid.T` has no `TempDir()` or `Cleanup()` — those would be wrong anyway
since `rapid.Check` runs the inner func many times (exploration + shrinking).
The pattern: outer `*testing.T` provides a root tempdir; each iteration
gets a subdirectory `iter{N}` via `harness.NewIn()`; `defer h.Close()`
inside the check func for per-iteration teardown.

## Task-marker echo-collision with fast builtins

When a test command is a fast builtin (`true`, `false`), the shell's echo
of the typed command (`...ZMX_TASK_COMPLETED:$?`) and the real marker
output (`ZMX_TASK_COMPLETED:0`) can land in one PTY read. The marker
scanner matches the echo first, parse fails, and `wait` hangs.

In practice echo and output usually arrive in separate reads, so this is
rare. If a state-machine test shows intermittent `wait` timeouts on
`true`/`false`, this is the likely cause — it's a protocol limitation,
not a harness issue.
