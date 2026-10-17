# src/fork/

Everything this fork adds to the zmx daemon lives here. `main` mirrors upstream
(`neurosnap/zmx`); the `fork` bookmark is our commits stacked on top of it. The rules exist
so that `jj rebase -b fork -d main` stays a non-event.

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

The fork pins a newer ghostty than upstream does. That changes `url` and `hash` in
`build.zig.zon` and most of `build.zig.zon2json-lock`, and neither can carry a marker
(`zig fetch --save` rewrites the lines; the lock is JSON). They will conflict whenever
upstream bumps its own pin. Resolve by taking whichever ghostty commit is newer, then
regenerate rather than hand-merge:

```sh
zig-0.16 fetch --save=ghostty 'git+https://github.com/ghostty-org/ghostty#<full sha>'

# No nix on the Mac, so the lock is regenerated in a container. The zig2nix rev is the one
# in flake.lock; bwrap inside the nix build needs the two extra docker flags.
docker run --rm --security-opt seccomp=unconfined --cap-add SYS_ADMIN \
  -e NIX_CONFIG='experimental-features = nix-command flakes' \
  -v "$PWD:/w" -w /w nixos/nix:latest \
  nix run "github:Cloudef/zig2nix/$(jq -r .nodes.zig2nix.locked.rev flake.lock)" -- \
  zon2lock build.zig.zon
```

`fork-check.sh` fails if the lock doesn't contain the hash `build.zig.zon` pins.

## After every rebase or pin bump

```sh
scripts/fork-check.sh
zig-0.16 build test -Dtarget=aarch64-macos
zig-0.16 build -Dtarget=aarch64-macos
env -u ZMX_SESSION -u ZMX_SESSION_PREFIX -u ZMX_NO_DETACH_KEY TMPDIR=/tmp SHELL=/bin/bash \
  bats --jobs 1 test/*.bats
```

- `-Dtarget` is deliberate. A native-target build compiles zig 0.16.0's libc++ against the
  Xcode SDK, which fails on the macOS 27.0 SDK (`use of undeclared identifier 'INFINITY'`),
  on upstream's pin too. An explicit target uses zig's bundled headers instead.
- `bats` reuses `zig-out/bin/zmx` if it exists, so rebuild first or it tests a stale binary.
- `TMPDIR=/tmp` keeps the per-test socket paths under the `sun_path` limit. Each test gets
  its own `ZMX_DIR`, so real sessions are not touched.
