#!/usr/bin/env bash
# env.sh - point the experiments at the six downloaded toolchains.
# Source this: `source scripts/env.sh`
#
# Toolchains live OUTSIDE the repo (under /home/user/toolchains) and are never
# committed. scripts/setup.sh re-downloads and extracts them from scratch.

export TC="${TC:-/home/user/toolchains}"

# Zig 0.17.0-xtensa (kassane/zig-espressif-bootstrap, bundled clang/LLVM
# 22.1.4). Canonical default — closes the under-aligned struct-by-value bug
# (docs/05) and the riscv `point_dot` bug (docs/09) by lowering aggregate
# args as `[N x i32]` instead of forwarding the raw struct type to LLVM's
# default CC. `zig c++` is now clang 22.1.4 / libc++ 22, so the C++26
# host-side probes (docs/16 §6, docs/20 §9, docs/21 §5) now use this
# binary directly (P2686R5 constexpr structured bindings compiles cleanly).
export ZIG="${ZIG:-$TC/zig-0.17-espressif/zig}"

# Zig 0.16.0 (kassane/zig-espressif-bootstrap, LLVM 21.1.0). Legacy/comparison
# lane — `experiments/abi-structs/sweep.sh` and `scripts/run-qemu.sh` show the
# struct-by-value gap reproducing on this build. `ZIG=$ZIG_016
# ./scripts/build-ffi.sh esp32` recreates the pre-0.17 baseline.
export ZIG_016="$TC/zig-relsafe-x86_64-linux-musl-baseline/zig"

# $LLD — the canonical lld invocation every script in the repo uses. Resolved
# to `zig ld.lld` (the LLD bundled inside $ZIG, currently LLD 22.1.4 on the
# 0.17 canonical lane). Three reasons:
#   1. Reproducibility — pinned to the in-repo $ZIG instead of $PATH, which
#      can resolve to the host package's LLD 18 (rejects post-18 IR — CLAUDE
#      gotcha #4) or to esp-clang's Espressif LLD 21.1.3, depending on shell
#      state.
#   2. LLVM cluster fit — now that LDC is also LLVM 22.1.4 (docs/05 §"LDC
#      1.42 status"), `zig ld.lld` matches both the canonical Zig AND the
#      canonical LDC. Object-level FFI is identical either way; for LTO
#      it's the right tool for the 22.x cluster.
#   3. One central handle — to swap lld (e.g. to esp-clang's for a specific
#      LTO probe), pass `LLD="$ESP_CLANG_DIR/ld.lld" ./scripts/build-ffi.sh
#      esp32`. env.sh honors a pre-set $LLD.
#
# Scripts use `$LLD -T ... -o … ...` — bash word-splits the unquoted
# variable in command position, so the `$ZIG ld.lld` two-token form
# expands correctly.
export LLD="${LLD:-$ZIG ld.lld}"

# Zig v0.17.0-dev (kassane/zig-mos-bootstrap, bundled clang 22.0.0git / libc++ 22).
# Comparison-only: a different upstream build, same LLVM-22 family as the
# canonical $ZIG. Used by `experiments/simd/run.sh` §6 only to cross-check that
# upstream mainline clang and the espressif bootstrap agree on the C++26
# surface. Optional download from
# https://github.com/kassane/zig-mos-bootstrap/releases/tag/0.17.0-dev,
# extracted to $TC/zig-mos.
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

# LDC 1.42.0 (espressif/llvm-project, LLVM 22.1.4) - kassane/esp-idf-dlang
# fork build. The canonical 5th frontend. Now in the LLVM-22 cluster (same as
# zig 0.17 + $LDC2_UPSTREAM + $LDC_LLVM_DIR binutils — docs/04), no longer in
# the LLVM-21 cluster with esp-clang/rust. Still has the espressif Xtensa MC
# patches (literal pools lay correctly, no -output-s re-assembly), AND
# carries the [N x i32] frontend struct-arg lowering — closes the universal
# D byval/sret aggregate ABI bug (docs/05/19/23) that the old 21.1.3 build
# had. First-class -mcpu values: esp32, esp32s2, esp32s3, esp8266, cnl,
# generic. Static-musl binary; ldc2.conf pre-bundled. Bare-metal uses
# -betterC (no druntime/Phobos), the D analogue of Rust no_std / Zig
# freestanding. See docs/19/23.
export LDC_DIR="$TC/ldc-xtensa"
export LDC2="$LDC_DIR/bin/ldc2"

# Canonical $LDC2 flag set: every upcoming language change (-preview=all,
# which includes dip1000/dip1008/dip1021/safer/systemVariables/in/bitfields/
# fieldwise/fixAliasThis/rvaluerefparam/nosharedaccess/fixImmutableConv/
# inclusiveincontracts) PLUS the latest accepted edition (DIP1052; LDC 1.42
# accepts 2023–2025, rejects 2026). Stress-tested at the shell against every
# .d source in the repo; the only required source-level fix is `@system` on
# raw-pointer-indexing kernels (e.g. experiments/simd/vadd.d), which is the
# honest annotation for a C-ABI buffer consumer anyway. Scripts that *probe*
# specific preview/edition flags (safety.sh §a/§b/§d/§g) intentionally skip
# $LDC_PE so the flag-as-test-variable contract still works. See HANDOFF and
# docs/20 §2/§3.
export LDC_PE="-preview=all --edition=2025"

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
