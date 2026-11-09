# src/fork/

Everything this fork adds to the zmx daemon lives here. `main` mirrors upstream
(`neurosnap/zmx`); the `fork` bookmark is our commits stacked on top of it. The rules exist
so that `jj rebase -b fork -d main` stays a non-event.

## What is here

- `facts.zig`: sets the callbacks on the daemon's terminal parser, answers the OSC 7501 probe,
  and publishes what the program in the pty reports as one small file per session.
- `FACTS.md`: that file's format, the whole contract with its readers.
- `../../bridge/`: the reader, `zmx-bridge`. A separate Rust program with its own build;
  nothing in zmx's build knows about it.

The two seams: `install(...)` in `src/loop.zig`, after the parser is made, and the import in
`src/test.zig` that gets this directory's tests collected.

## Rules

1. **New daemon code goes in this directory**, never in an upstream file.
2. **Imports are limited** to `std`, `ghostty-vt`, `../loop.zig` (for the `Daemon` type only)
   and sibling files in this directory. Upstream moves helpers between `util.zig`,
   `main.zig` and friends; code that doesn't import them can't be broken by that.
3. **Every upstream line we touch ends in `// [fork]`.** These are the seams. Keep each to
   one line that calls into this directory.
4. **`scripts/fork-check.sh` knows the seam count.** Adding or removing a seam means
   changing `seams=` there in the same commit.

Nothing here may be imported from `src/lib.zig`: upstream is adding a `-Ddaemon=false` build
in which `ghostty-vt` is not fetched at all, and `lib.zig` is that build's root. `src/test.zig`
is fine (it already imports `loop.zig` unconditionally) and needs a seam of its own, because
tests in a file reached only from a function body are never collected.

## The one exception: the libghostty pin

Not in use at the moment: since v1.0 upstream pins a ghostty that has everything `facts.zig`
needs, so the fork leaves `build.zig.zon` and the lock alone. `fork-check.sh` compares the two
only while our pin differs from `main`'s. Upstream's lock and flake still name Zig 0.16 and
its old pin, so don't expect the nix build to work until upstream regenerates them.

If the fork needs a newer ghostty than upstream again, that changes `url` and `hash` in
`build.zig.zon` and most of `build.zig.zon2json-lock`, and neither can carry a marker
(`zig fetch --save` rewrites the lines; the lock is JSON). They will conflict whenever
upstream bumps its own pin. Resolve by taking whichever ghostty commit is newer, then
regenerate rather than hand-merge:

```sh
zig-0.17 fetch --save=ghostty 'git+https://github.com/ghostty-org/ghostty#<full sha>'

# No nix on the Mac, so the lock is regenerated in a container. The zig2nix rev is the one
# in flake.lock; bwrap inside the nix build needs the two extra docker flags.
docker run --rm --security-opt seccomp=unconfined --cap-add SYS_ADMIN \
  -e NIX_CONFIG='experimental-features = nix-command flakes' \
  -v "$PWD:/w" -w /w nixos/nix:latest \
  nix run "github:Cloudef/zig2nix/$(jq -r .nodes.zig2nix.locked.rev flake.lock)" -- \
  zon2lock build.zig.zon
```

`fork-check.sh` fails if the lock doesn't contain the hash the fork pins.

## After every rebase or pin bump

```sh
scripts/fork-check.sh
env -u ZMX_SESSION -u ZMX_SESSION_PREFIX -u ZMX_NO_DETACH_KEY \
  zig-0.17 build test -Dtarget=aarch64-macos
zig-0.17 build -Dtarget=aarch64-macos
env -u ZMX_SESSION -u ZMX_SESSION_PREFIX -u ZMX_NO_DETACH_KEY TMPDIR=/tmp SHELL=/bin/bash \
  bats --jobs 1 test/*.bats
(cd bridge && cargo test)
```

- `zig-0.17` is the Zig that `minimum_zig_version` in `build.zig.zon` names. Toolchains sit
  side by side and are never upgraded in place, because zmx and Ghostty change Zig versions at
  different times: the official tarball from ziglang.org is unpacked to
  `~/.local/share/zig-X.Y.Z/`, and `~/.local/bin/zig-X.Y` is a symlink to its `zig`.
- **The pin cannot pass the Zig that zmx builds with.** When Ghostty moves to a newer Zig first,
  the newest usable pin is the commit on its main just before the move.
- The `env -u` on the unit tests matters when they are run from inside a zmx session. Upstream's
  tests call `unsetenv` on those names; if one was really set, libc closes the gap in the
  environment array, and zig 0.16's test runner, which kept the old length, panics with
  `attempt to use null value` the first time a later test logs a warning.
- `-Dtarget` is deliberate. A native-target build compiles zig 0.16.0's libc++ against the
  Xcode SDK, which fails on the macOS 27.0 SDK (`use of undeclared identifier 'INFINITY'`),
  on upstream's pin too. An explicit target uses zig's bundled headers instead.
- One bats test, `write: a file larger than the PTY input buffer arrives whole`, fails on macOS
  on plain upstream as well (v1.0.1).
- `bats` reuses `zig-out/bin/zmx` if it exists, so rebuild first or it tests a stale binary.
- `TMPDIR=/tmp` keeps the per-test socket paths under the `sun_path` limit. Each test gets
  its own `ZMX_DIR`, so real sessions are not touched.
