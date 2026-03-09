# zmx

The goal of this project is to create a way to attach and detach terminal sessions without killing the underlying linux process.

When researching `zmx`, also read the @README.md in the root of this project directory to learn more about the features, documentation, prior art, etc.

## tech stack

- `zig` v0.15.1
- `libghostty-vt` for terminal escape codes and terminal state management

## commands

- **Build:** `zig build`
- **Build Check (Zig)**: `zig build check`
- **Test (Zig):** `zig build test`
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`

## find any library API definitions

Before trying anything else, run the `zigdoc` command to find an API with documentation:

```
zigdoc {symbol}
# examples
zigdoc ghostty-vt
zigdoc std.ArrayList
zigdoc std.mem.Allocator
zigdoc std.http.Server
```

Only if that doesn't work should you grep the project dir.

## find zig std library source code

To inspect the source code for zig's standard library, look inside the `zig_std_src` folder.

## find ghostty library source code

To inspect the source code for zig's standard library, look inside the `ghostty_src` folder.

## Testing

- **Unit + fuzz seed:** `zig build test` — includes in-process fuzz for IPC
  decode (seed corpus only).
- **Fuzz (continuous):** `zig build test --fuzz` — coverage-guided, runs
  until ctrl-C.
- **E2E (Go):** `ZMX_BIN=$PWD/zig-out/bin/zmx go test -C tests ./e2e -v`
  (go.mod is in `tests/`, so use `-C tests` or `cd tests` first)
- **State machine:** `... -run StateMachine -rapid.checks=10` — slow;
  each check spawns real daemons under PTY.

Harness-specific gotchas (pipe inheritance, PTY setup, ZMX_DIR shape,
shell-quoting, overlapping-runs race): see `tests/AGENTS.md`.

## Issue Tracking

We use bd (beads, https://github.com/steveyegge/beads) for issue tracking instead of Markdown TODOs or external tools.

Run `bd quickstart` to learn how to use it.
