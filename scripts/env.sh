#!/usr/bin/env bash
# env.sh - point the experiments at the six downloaded toolchains.
# Source this: `source scripts/env.sh`
#
# Toolchains live OUTSIDE the repo (under /home/user/toolchains) and are never
# committed. scripts/setup.sh re-downloads and extracts them from scratch.

export TC="${TC:-/home/user/toolchains}"

# Zig 0.16.0 (kassane/zig-espressif-bootstrap, built against espressif LLVM 21)
export ZIG="$TC/zig-relsafe-x86_64-linux-musl-baseline/zig"

# Zig v0.17.0-dev (kassane/zig-mos-bootstrap, bundled clang 22.0.0git / libc++ 22).
# Optional: only used for the C++26 host-side re-probes (docs/20 §9, docs/21 §5,
# experiments/simd/run.sh §6). Download from
# https://github.com/kassane/zig-mos-bootstrap/releases/tag/0.17.0-dev and extract
# to $TC/zig-mos.
export ZIG_MOS="$TC/zig-mos/zig"

# Espressif clang/LLVM 21.1.3 (espressif/llvm-project esp-21.1.3_20260408)
export ESP_CLANG_DIR="$TC/esp-clang/bin"
export CLANG="$ESP_CLANG_DIR/clang"
export CLANGXX="$ESP_CLANG_DIR/clang++"

# Rust 1.95.0-nightly with LLVM 21.1.3 (esp-rs/rust-build v1.95.0.0).
# The release ships split components; scripts/setup.sh runs its install.sh to
# merge rustc + host std + cargo into this single prefix (build-std needs it).
export RUST_DIR="$TC/rust-esp"
export RUSTC="$RUST_DIR/bin/rustc"
export CARGO="$RUST_DIR/bin/cargo"

# GCC 15.2.0 (espressif/crosstool-NG esp-15.2.0_20251204) - NOT LLVM based
export GCC_DIR="$TC/xtensa-esp-elf"
export GCC="$GCC_DIR/bin/xtensa-esp-elf-gcc"
export GXX="$GCC_DIR/bin/xtensa-esp-elf-g++"
# Espressif GCC selects the Xtensa core (and endianness!) via a dynconfig .so.
# The default built-in core is big-endian generic Xtensa; ESP cores are
# little-endian, so XTENSA_GNU_CONFIG must be set for every esp build.
export GCC_CFG_DIR="$GCC_DIR/lib"
xtensa_cfg() { echo "$GCC_CFG_DIR/xtensa_${1}.so"; }  # xtensa_cfg esp32 -> .../xtensa_esp32.so

# LDC 1.42.0-git (espressif/llvm-project, LLVM 21.1.3) - kassane/esp-idf-dlang
# fork build. The canonical 5th frontend. Same LLVM family as esp-clang and
# rustc (21.1.3), so no bitcode-version skew and no -output-s re-assembly
# workaround (its Xtensa MC lays literal pools correctly). First-class -mcpu
# values: esp32, esp32s2, esp32s3, esp8266, cnl, generic. Static-musl binary;
# ldc2.conf pre-bundled. Bare-metal uses -betterC (no druntime/Phobos), the D
# analogue of Rust no_std / Zig freestanding. See docs/23.
export LDC_DIR="$TC/ldc-xtensa"
export LDC2="$LDC_DIR/bin/ldc2"

# Upstream LDC 1.42 (LLVM 22.1.2) - ldc-developers/ldc CI build. Comparison
# only, referenced by experiments/ldc-fork-comparison/ + docs/23. Has the
# Xtensa literal-pool MC bug ("not aligned to 4 bytes") and only recognizes
# -mcpu=esp32 (ldc #4919). Opt-in: setup.sh LDC_UPSTREAM=1.
export LDC2_UPSTREAM="$TC/ldc2-c8305d0a-linux-x86_64/bin/ldc2"

# Fallback: kassane/esp-idf-dlang upstream has been unreachable since
# 2026-05-28. If the fork tarball isn't installed but the upstream-22 LDC is,
# promote it to canonical so the rest of the build still runs (with the
# literal-pool + s2/s3 workarounds back in scope). docs/23 then no longer
# holds for this session.
if [ ! -x "$LDC2" ] && [ -x "$LDC2_UPSTREAM" ]; then
    echo "env.sh: \$LDC2 (esp-fork LDC) missing — promoting \$LDC2_UPSTREAM to canonical." >&2
    echo "        Re-enables the docs/23 workarounds (literal-pool, -mattr s2/s3)." >&2
    LDC2="$LDC2_UPSTREAM"
    LDC_DIR="$TC/ldc2-c8305d0a-linux-x86_64"
fi
export LDC2 LDC_DIR

# Matching LLVM 22.1.2 tools (ldc-developers/llvm-project ldc-v22.1.2): full
# binutils (llvm-link/opt/llvm-dis/llvm-as/llc) for inspecting/merging the
# upstream LDC's LLVM-22 bitcode (the host's are LLVM 18). NOT needed for the
# canonical 21.1.3 LDC — esp-clang ships matching binutils. NOT prepended to
# PATH (would shadow esp-clang's tools). Reference explicitly via
# $LDC_LLVM_DIR/bin/<tool>. Optional (setup.sh LLVM22=1). See docs/04, docs/23.
export LDC_LLVM_DIR="$TC/llvm-22.1.2-linux-x86_64"

# TinyGo v0.41.1 — Go-to-LLVM compiler (its own bundled LLVM 20.1.1; yet a third
# LLVM family in the matrix, after 21.1.x and 22.1.2). Whole-program compiler
# (no -c relocatable mode outside wasm), so it sits outside the FFI matrix:
# experiments/tinygo/run.sh probes its target list / feature set / firmware
# build flow. Xtensa targets: esp32 + esp32s3 + esp32c3 (no esp32s2). docs/24.
export TINYGO_DIR="$TC/tinygo"
export TINYGO="$TINYGO_DIR/bin/tinygo"

# LDC Xtensa codegen flags for a core. Pairs -mcpu (canonical CPU name; the
# fork LDC recognizes esp32/s2/s3 natively) with an explicit -mattr= feature
# list that pins the codegen-relevant ISA options esp-clang implicitly enables
# for the same -mcpu. Two reasons to be explicit even though -mcpu already
# enables these via the CPU definition: (1) the user-facing tests are then
# self-documenting about what ISA they need (windowed call ABI, density compact
# insns, mul/div, atomics, FP); (2) future LDC versions can't silently change a
# per-CPU default and drift D's codegen away from clang's. The feature subset
# below is the intersection of features both LDC versions recognize, so the
# same string drives experiments/ldc-fork-comparison's upstream-LDC arm too.
# Fork-only features (+esp32s2ops/+esp32s3ops/+expstate/+hifi3) come implicitly
# from -mcpu on the fork LDC — they only exist there.
LDC_MATTR_E32="+bool,+clamps,+coprocessor,+dcache,+debug,+density,+dfpaccel,+div32,+exception,+fp,+highpriinterrupts,+interrupt,+loop,+mac16,+minmax,+miscsr,+mul16,+mul32,+mul32high,+nsa,+prid,+regprotect,+rvector,+s32c1i,+sext,+threadptr,+windowed"
LDC_MATTR_S2="+clamps,+coprocessor,+dcache,+debug,+density,+div32,+exception,+highpriinterrupts,+interrupt,+minmax,+miscsr,+mul16,+mul32,+mul32high,+nsa,+prid,+regprotect,+rvector,+sext,+threadptr,+windowed"
LDC_MATTR_S3="+bool,+clamps,+coprocessor,+dcache,+debug,+density,+div32,+exception,+fp,+highpriinterrupts,+interrupt,+loop,+mac16,+minmax,+miscsr,+mul16,+mul32,+mul32high,+nsa,+prid,+regprotect,+rvector,+s32c1i,+sext,+threadptr,+windowed"
ldc_xtensa_flags() { case "$1" in
    esp32)   echo "-mcpu=esp32   -mattr=$LDC_MATTR_E32" ;;
    esp32s2) echo "-mcpu=esp32s2 -mattr=$LDC_MATTR_S2" ;;
    esp32s3) echo "-mcpu=esp32s3 -mattr=$LDC_MATTR_S3" ;;
    *)       echo "-mcpu=$1" ;;
esac; }

# Keep cargo's caches local and offline-friendly.
export CARGO_HOME="${CARGO_HOME:-$TC/.cargo-home}"

# LLVM binutils (llvm-objdump, llvm-readobj, llc, llvm-mc, ...) come from esp-clang.
export PATH="$ESP_CLANG_DIR:$GCC_DIR/bin:$RUST_DIR/bin:$(dirname "$ZIG"):$PATH"
