#!/bin/sh
# Release binaries for every platform zmx ships for, from one machine. The Linux ones are static
# (musl) and link with rustup's own lld, see .cargo/config.toml.
set -eu
cd "$(dirname "$0")"
mkdir -p target/dist
for pair in \
  x86_64-unknown-linux-musl:linux-x86_64 \
  aarch64-unknown-linux-musl:linux-aarch64 \
  x86_64-apple-darwin:macos-x86_64 \
  aarch64-apple-darwin:macos-aarch64
do
  target=${pair%%:*} name=${pair##*:}
  cargo build --release --locked --target "$target"
  cp "target/$target/release/zmx-bridge" "target/dist/zmx-bridge-$name"
done
ls -l target/dist
