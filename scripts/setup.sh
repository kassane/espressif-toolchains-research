#!/usr/bin/env bash
# setup.sh - download, extract and prepare the four toolchains from scratch.
# Idempotent: skips work already done. Toolchains land in $TC (default
# /home/user/toolchains) and downloads in $DL (default /home/user/dl), both
# OUTSIDE the repo so nothing large is ever committed.
set -euo pipefail

TC="${TC:-/home/user/toolchains}"
DL="${DL:-/home/user/dl}"
mkdir -p "$TC" "$DL"

# Pinned releases (see docs/01-toolchains.md).
ZIG_URL="https://github.com/kassane/zig-espressif-bootstrap/releases/download/0.16.0-xtensa/zig-relsafe-x86_64-linux-musl-baseline.tar.xz"
CLANG_URL="https://github.com/espressif/llvm-project/releases/download/esp-21.1.3_20260408/clang-esp-21.1.3_20260408-x86_64-linux-gnu.tar.xz"
RUST_URL="https://github.com/esp-rs/rust-build/releases/download/v1.95.0.0/rust-1.95.0.0-x86_64-unknown-linux-gnu.tar.xz"
RUST_SRC_URL="https://github.com/esp-rs/rust-build/releases/download/v1.95.0.0/rust-src-1.95.0.0.tar.xz"
GCC_URL="https://github.com/espressif/crosstool-NG/releases/download/esp-15.2.0_20251204/xtensa-esp-elf-15.2.0_20251204-x86_64-linux-gnu.tar.xz"

fetch() { # url outfile
    [ -f "$2" ] && { echo "have $(basename "$2")"; return; }
    echo "downloading $(basename "$2")"
    curl -fsSL --retry 4 --retry-delay 2 -o "$2" "$1"
    xz -t "$2"
}

fetch "$ZIG_URL"      "$DL/zig-xtensa.tar.xz"
fetch "$CLANG_URL"    "$DL/clang-xtensa.tar.xz"
fetch "$RUST_URL"     "$DL/rust-xtensa.tar.xz"
fetch "$RUST_SRC_URL" "$DL/rust-src.tar.xz"
fetch "$GCC_URL"      "$DL/gcc-xtensa.tar.xz"

extract() { # tarball marker_dir
    [ -e "$TC/$2" ] && { echo "extracted $2"; return; }
    echo "extracting $(basename "$1")"
    tar xf "$1" -C "$TC"
}
extract "$DL/zig-xtensa.tar.xz"   "zig-relsafe-x86_64-linux-musl-baseline"
extract "$DL/clang-xtensa.tar.xz" "esp-clang"
extract "$DL/gcc-xtensa.tar.xz"   "xtensa-esp-elf"

# Rust ships split components; merge rustc + host std + cargo into one prefix.
if [ ! -x "$TC/rust-esp/bin/rustc" ]; then
    [ -d "$TC/rust-nightly-x86_64-unknown-linux-gnu" ] || tar xf "$DL/rust-xtensa.tar.xz" -C "$TC"
    ( cd "$TC/rust-nightly-x86_64-unknown-linux-gnu" && \
      ./install.sh --prefix="$TC/rust-esp" --without=rust-docs,rust-docs-json-preview --disable-ldconfig )
fi

# rust-src for -Zbuild-std=core (no precompiled xtensa core is shipped).
[ -d "$TC/rust-src-nightly" ] || tar xf "$DL/rust-src.tar.xz" -C "$TC"
SYS="$TC/rust-esp"
mkdir -p "$SYS/lib/rustlib/src"
ln -sfn "$TC/rust-src-nightly/rust-src/lib/rustlib/src/rust" "$SYS/lib/rustlib/src/rust"

echo "setup complete. source scripts/env.sh to use the toolchains."
