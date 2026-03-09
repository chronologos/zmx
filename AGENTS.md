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
- **E2E:** `zig build test-e2e` — black-box against `zig-out/bin/zmx`.
  Override the binary with `ZMX_BIN=/path/to/zmx`.
- **State machine:** `zig build test-e2e --fuzz` — coverage-guided op-tape
  against a real daemon; Linux-only on 0.15.x. Seed corpus runs on every
  plain `test-e2e`.

Harness-specific gotchas (sun_path limit, ZMX_* env leaks, blocking
`run` semantics, shell-quoting): see `tests/AGENTS.md`.

## Issue Tracking

We use bd (beads, https://github.com/steveyegge/beads) for issue tracking instead of Markdown TODOs or external tools.

Run `bd quickstart` to learn how to use it.
