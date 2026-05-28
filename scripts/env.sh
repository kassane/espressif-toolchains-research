#!/usr/bin/env bash
# env.sh - point the experiments at the five downloaded toolchains.
# Source this: `source scripts/env.sh`
#
# Toolchains live OUTSIDE the repo (under /home/user/toolchains) and are never
# committed. scripts/setup.sh re-downloads and extracts them from scratch.

export TC="${TC:-/home/user/toolchains}"

# Zig 0.16.0 (kassane/zig-espressif-bootstrap, built against espressif LLVM 21)
export ZIG="$TC/zig-relsafe-x86_64-linux-musl-baseline/zig"

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

# LDC 1.42.0-git (LLVM 22.1.2) - LLVM-based D compiler, ldc-developers/ldc CI
# build. The ONLY toolchain here on LLVM 22 (clang/rust are 21.1.3, zig 21.1.0),
# and it carries Xtensa as an experimental LLVM target. Bare-metal uses -betterC
# (no druntime/Phobos), the D analogue of Rust no_std / Zig freestanding.
export LDC_DIR="$TC/ldc2-c8305d0a-linux-x86_64"
export LDC2="$LDC_DIR/bin/ldc2"

# Matching LLVM 22.1.2 tools (ldc-developers/llvm-project ldc-v22.1.2): the full
# binutils esp-clang does NOT ship — llvm-link / opt / llvm-dis / llvm-as / llc /
# llvm-config. These finally read post-18 IR (the host's are LLVM 18), so they
# can merge/inspect LDC's LLVM-22 bitcode (docs/04). NOT prepended to PATH: that
# would shadow esp-clang's 21.1.3 llvm-objdump/nm/size and ld.lld. Reference the
# tools explicitly via $LDC_LLVM_DIR/bin/<tool>. Optional (setup.sh LLVM22=1).
export LDC_LLVM_DIR="$TC/llvm-22.1.2-linux-x86_64"

# LDC Xtensa codegen flags for a core. LDC's upstream LLVM-22 only knows the
# `esp32` CPU; esp32s2/s3 are "not a recognized processor", so spell out the
# features by hand (ldc #4919). Single source of truth — used by build-ffi.sh
# and analyze.sh so their D objects/IR can't drift apart.
ldc_xtensa_flags() { case "$1" in
    esp32) echo "-mcpu=esp32" ;;
    *)     echo "-mattr=+windowed,+density,+mul32,+mul16,+div32" ;;
esac; }

# Keep cargo's caches local and offline-friendly.
export CARGO_HOME="${CARGO_HOME:-$TC/.cargo-home}"

# LLVM binutils (llvm-objdump, llvm-readobj, llc, llvm-mc, ...) come from esp-clang.
export PATH="$ESP_CLANG_DIR:$GCC_DIR/bin:$RUST_DIR/bin:$(dirname "$ZIG"):$PATH"
