#!/usr/bin/env bash
# setup.sh - download, extract and prepare the six toolchains from scratch.
# Idempotent: skips work already done. Toolchains land in $TC (default
# /home/user/toolchains) and downloads in $DL (default /home/user/dl), both
# OUTSIDE the repo so nothing large is ever committed.
set -euo pipefail

TC="${TC:-/home/user/toolchains}"
DL="${DL:-/home/user/dl}"
mkdir -p "$TC" "$DL"

# Pinned releases (see docs/01-toolchains.md).
# Canonical Zig: 0.17.0-xtensa (clang/LLVM 22.1.4) — closes the under-aligned
# struct-by-value ABI bug (docs/05 + docs/09) that 0.16 carried. The 0.16
# baseline is still downloaded so experiments/abi-structs/sweep.sh + run-qemu
# can demonstrate the gap reproducing on the older LLVM line.
ZIG_URL="https://github.com/kassane/zig-espressif-bootstrap/releases/download/0.17.0-xtensa-dev/zig-relsafe-x86_64-linux-musl-baseline.tar.xz"
ZIG_016_URL="https://github.com/kassane/zig-espressif-bootstrap/releases/download/0.16.0-xtensa/zig-relsafe-x86_64-linux-musl-baseline.tar.xz"
CLANG_URL="https://github.com/espressif/llvm-project/releases/download/esp-21.1.3_20260408/clang-esp-21.1.3_20260408-x86_64-linux-gnu.tar.xz"
RUST_URL="https://github.com/esp-rs/rust-build/releases/download/v1.95.0.0/rust-1.95.0.0-x86_64-unknown-linux-gnu.tar.xz"
RUST_SRC_URL="https://github.com/esp-rs/rust-build/releases/download/v1.95.0.0/rust-src-1.95.0.0.tar.xz"
GCC_URL="https://github.com/espressif/crosstool-NG/releases/download/esp-15.2.0_20251204/xtensa-esp-elf-15.2.0_20251204-x86_64-linux-gnu.tar.xz"
# TinyGo: Go-to-LLVM compiler (its own LLVM 20.1.1 bundle). Targets esp32 +
# esp32s3 + esp32c3 (no esp32s2). It's a whole-program compiler — emits a
# firmware .bin, not relocatable .o files — so it sits outside the FFI matrix
# and lives in experiments/tinygo/. See docs/24.
TINYGO_URL="https://github.com/tinygo-org/tinygo/releases/download/v0.41.1/tinygo0.41.1.linux-amd64.tar.gz"
# LDC: kassane/esp-idf-dlang esp-fork build (LDC 1.42 / espressif LLVM 21.1.3).
# Static-musl, ships ldc2.conf with first-class esp32/esp32s2/esp32s3 -mcpu values
# (no -mattr fallback) AND a Xtensa MC that lays literal pools correctly (no
# -output-s re-assembly), so this is the canonical 5th-frontend toolchain. See
# docs/23. The upstream CI LDC (below, LLVM 22.1.2) is kept as a comparison-only
# toolchain referenced by experiments/ldc-fork-comparison/.
LDC_URL="https://github.com/kassane/esp-idf-dlang/releases/download/xtensa-toolchain/ldc2-v1.42.0-espressif-linux-musl-static.tar.xz"
LDC_SHA256="c2cd9f5bdd1caa80233cebc7b3d61243366b1b1a8780af019d0dbfb80becb548"
# Upstream LDC CI (LLVM 22.1.2, upstream-LLVM Xtensa): the "before" of the fork
# comparison. Pinned to c8305d0a; the CI tag is mutable. Fetched only when
# LDC_UPSTREAM=1 (opt-in; ~57 MB) so default users don't pay for the comparison.
LDC_UPSTREAM_URL="https://github.com/ldc-developers/ldc/releases/download/CI/ldc2-c8305d0a-linux-x86_64.tar.xz"
# Matching LLVM 22.1.2 binutils (llvm-link/opt/llvm-dis) — only useful with the
# upstream LDC since esp-clang's 21.1.x binutils now match the canonical LDC.
# Large + opt-in (LLVM22=1); a .tar.zst (needs zstd).
LLVM_URL="https://github.com/ldc-developers/llvm-project/releases/download/ldc-v22.1.2/llvm-22.1.2-linux-x86_64.tar.zst"
# qemu (optional; only needed for scripts/run-qemu.sh). Both softmmu builds.
QEMU_BASE="https://github.com/espressif/qemu/releases/download/esp-develop-9.2.2-20260417"
QEMU_XT_URL="$QEMU_BASE/qemu-xtensa-softmmu-esp_develop_9.2.2_20260417-x86_64-linux-gnu.tar.xz"
QEMU_RV_URL="$QEMU_BASE/qemu-riscv32-softmmu-esp_develop_9.2.2_20260417-x86_64-linux-gnu.tar.xz"

fetch() { # url outfile
    [ -f "$2" ] && { echo "have $(basename "$2")"; return; }
    echo "downloading $(basename "$2")"
    curl -fsSL --retry 4 --retry-delay 2 -o "$2" "$1"
    case "$2" in
        *.tar.xz) xz -t "$2" ;;
        *.tar.gz) gunzip -t "$2" ;;
    esac
}

fetch "$ZIG_URL"      "$DL/zig-0.17-espressif.tar.xz"
fetch "$ZIG_016_URL"  "$DL/zig-016-xtensa.tar.xz"
fetch "$CLANG_URL"    "$DL/clang-xtensa.tar.xz"
fetch "$RUST_URL"     "$DL/rust-xtensa.tar.xz"
fetch "$RUST_SRC_URL" "$DL/rust-src.tar.xz"
fetch "$GCC_URL"      "$DL/gcc-xtensa.tar.xz"
# kassane/esp-idf-dlang upstream has been unreachable since 2026-05-28 — the
# pinned URL is gone. The fork-LDC tarball is the canonical 5th frontend (docs/23);
# until a new mirror is published, this step uses the cached copy under $DL/
# if present, else falls back to fetching the upstream-LLVM-22 LDC (slightly
# worse: brings back the literal-pool workaround, no esp32-s2/s3 -mcpu).
# Vendoring the 49 MB tarball into git is not workable; if you have the file,
# drop it at $DL/ldc-esp.tar.xz with sha256 $LDC_SHA256 before re-running.
if [ -f "$DL/ldc-esp.tar.xz" ] && \
   echo "$LDC_SHA256  $DL/ldc-esp.tar.xz" | sha256sum -c - >/dev/null 2>&1; then
    echo "have ldc-esp.tar.xz (cached, sha256 verified)"
elif fetch "$LDC_URL" "$DL/ldc-esp.tar.xz" && \
     echo "$LDC_SHA256  $DL/ldc-esp.tar.xz" | sha256sum -c - >/dev/null 2>&1; then
    echo "fetched ldc-esp.tar.xz from upstream"
else
    echo "WARNING: cannot get ldc-esp.tar.xz (esp-idf-dlang upstream is gone)."
    echo "         Falling back to upstream-LLVM-22 LDC as canonical (regression"
    echo "         vs docs/23 — see HANDOFF.md 'LDC mirror outage'). Forcing"
    echo "         LDC_UPSTREAM=1."
    LDC_UPSTREAM=1
fi
fetch "$TINYGO_URL"   "$DL/tinygo.tar.gz"

extract() { # tarball marker_dir
    [ -e "$TC/$2" ] && { echo "extracted $2"; return; }
    echo "extracting $(basename "$1")"
    tar xf "$1" -C "$TC"
}
# Canonical 0.17 ships top-level files (zig + lib/) so strip-components=1 into a
# target dir. The legacy 0.16 tarball uses its own top-level dir, so a plain
# extract picks it up.
if [ ! -x "$TC/zig-0.17-espressif/zig" ]; then
    echo "extracting zig-0.17-espressif.tar.xz"
    mkdir -p "$TC/zig-0.17-espressif"
    tar xf "$DL/zig-0.17-espressif.tar.xz" -C "$TC/zig-0.17-espressif" --strip-components=1
fi
extract "$DL/zig-016-xtensa.tar.xz" "zig-relsafe-x86_64-linux-musl-baseline"
extract "$DL/clang-xtensa.tar.xz" "esp-clang"
extract "$DL/gcc-xtensa.tar.xz"   "xtensa-esp-elf"
[ -f "$DL/ldc-esp.tar.xz" ] && extract "$DL/ldc-esp.tar.xz" "ldc-xtensa"
extract "$DL/tinygo.tar.gz"       "tinygo"

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

# qemu (optional): only fetched if QEMU=1, since run-qemu.sh is the only consumer.
if [ "${QEMU:-0}" = 1 ]; then
    fetch "$QEMU_XT_URL" "$DL/qemu-xtensa.tar.xz"
    fetch "$QEMU_RV_URL" "$DL/qemu-riscv.tar.xz"
    mkdir -p "$TC/qemu"
    [ -x "$TC/qemu/qemu/bin/qemu-system-xtensa" ]  || tar xf "$DL/qemu-xtensa.tar.xz" -C "$TC/qemu"
    [ -x "$TC/qemu/qemu/bin/qemu-system-riscv32" ] || tar xf "$DL/qemu-riscv.tar.xz"  -C "$TC/qemu"
    echo "qemu installed. NOTE: it needs libSDL2 + libslirp even headless:"
    echo "  apt-get install -y libsdl2-2.0-0 libslirp0"
fi

# Upstream LDC + matching LLVM 22.1.2 binutils (optional, comparison-only).
#   LDC_UPSTREAM=1 -> $LDC2_UPSTREAM (the "before" of the fork comparison;
#                    docs/23, experiments/ldc-fork-comparison/).
#   LLVM22=1       -> $LDC_LLVM_DIR (llvm-link/opt/llvm-dis at LLVM 22.1.2;
#                    only useful with the upstream LDC, since esp-clang's
#                    21.1.x binutils now version-match the canonical LDC).
if [ "${LDC_UPSTREAM:-0}" = 1 ]; then
    fetch "$LDC_UPSTREAM_URL" "$DL/ldc-upstream.tar.xz"
    [ -e "$TC/ldc2-c8305d0a-linux-x86_64" ] || tar xf "$DL/ldc-upstream.tar.xz" -C "$TC"
    echo "upstream-LLVM-22 LDC installed (\$LDC2_UPSTREAM, comparison only)."
fi
if [ "${LLVM22:-0}" = 1 ]; then
    command -v zstd >/dev/null 2>&1 || apt-get install -y zstd >/dev/null 2>&1 || \
        echo "WARNING: install zstd to extract the .tar.zst (apt-get install -y zstd)"
    [ -f "$DL/llvm22-ldc.tar.zst" ] || { echo "downloading llvm-22.1.2"; \
        curl -fsSL --retry 4 --retry-delay 2 -o "$DL/llvm22-ldc.tar.zst" "$LLVM_URL"; }
    [ -x "$TC/llvm-22.1.2-linux-x86_64/bin/llvm-link" ] || \
        tar --zstd -xf "$DL/llvm22-ldc.tar.zst" -C "$TC"
    echo "llvm-22.1.2 tools installed (\$LDC_LLVM_DIR)."
fi

echo "setup complete. source scripts/env.sh to use the toolchains."
echo "(QEMU=1 also fetches the espressif qemu fork; LDC_UPSTREAM=1 the upstream-LLVM-22 LDC; LLVM22=1 its matching binutils.)"
