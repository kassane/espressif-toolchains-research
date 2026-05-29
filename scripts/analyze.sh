#!/usr/bin/env bash
# analyze.sh - regenerate the evidence behind the report: LLVM IR signatures,
# Xtensa disassembly of ABI-revealing functions, code sizes and CPU features.
# Writes human-readable dumps under build/analysis/. Requires build-ffi.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
SRC=experiments/ffi-matrix; INC="$PWD/$SRC/include"
OUT=build/analysis; mkdir -p "$OUT"
CPU=${1:-esp32}; CT="--target=xtensa-esp-elf -mcpu=$CPU"

echo "# CPU feature parity ($CPU): rustc vs clang vs zig" | tee "$OUT/features-$CPU.txt"
{
  echo "## rustc --print cfg"; "$RUSTC" --print cfg --target "xtensa-$CPU-none-elf" | grep target_feature
  echo "## clang target-features"; echo 'void f(){}' | "$CLANG" $CT -S -emit-llvm -o - -x c - 2>/dev/null | grep -oE 'target-features"="[^"]*"'
  echo "## zig --show-builtin (features)"; "$ZIG" build-obj --show-builtin -target xtensa-freestanding-none -mcpu="$CPU" 2>/dev/null | sed -n '/featureSet/,/}/p'
} >> "$OUT/features-$CPU.txt"

echo "# LLVM IR ABI signatures ($CPU)" | tee "$OUT/ir-signatures-$CPU.txt"
IR=build/ir-$CPU; mkdir -p "$IR"
"$CLANG" $CT -ffreestanding -O0 -S -emit-llvm -I"$INC" "$SRC/c/lib_c.c" -o "$IR/lib_c.ll"
"$ZIG" build-obj -target xtensa-freestanding-none -mcpu="$CPU" -O ReleaseSmall \
    -fno-emit-bin -femit-llvm-ir="$IR/lib_zig.ll" "$SRC/zig/lib_zig.zig"
( cd "$SRC/rust" && RUSTC="$RUSTC" "$CARGO" rustc --release -Z build-std=core \
    --target "xtensa-$CPU-none-elf" -- --emit=llvm-ir >/dev/null 2>&1 )
cp "$(find "$SRC/rust/target/xtensa-$CPU-none-elf/release" -name 'ffi_rs*.ll' | head -1)" "$IR/lib_rs.ll"
# D (LDC): ldc_xtensa_flags (env.sh) returns "-mcpu=<cpu> -mattr=<features>" as
# a whitespace-separated pair; let the shell word-split it. Shared with
# build-ffi.sh so the dumped IR matches the linked object.
# shellcheck disable=SC2046
"$LDC2" -mtriple=xtensa-esp-elf $(ldc_xtensa_flags "$CPU") $LDC_PE -betterC -Os -output-ll -of="$IR/lib_d.ll" "$SRC/d/lib_d.d"
for fn in add_i32 mul_f64 make_point point_dot make_blob blob_sum apply; do
  echo "== $fn =="; for l in c rs zig d; do printf "  %-4s " "$l"; grep -E "define.*$fn" "$IR/lib_$l.ll" | head -1; done
done | tee -a "$OUT/ir-signatures-$CPU.txt"

echo "# Disassembly of ABI-revealing functions ($CPU)" | tee "$OUT/disasm-$CPU.txt"
ELF="build/xtensa-$CPU/ffi_llvm.elf"
for fn in c_add_i32 rs_add_i32 zig_add_i32 d_add_i32 c_apply zig_apply c_blob_sum zig_blob_sum d_blob_sum d_point_dot c_make_blob zig_make_blob; do
  echo "== $fn =="
  llvm-objdump -d --mcpu="$CPU" --disassemble-symbols="$fn" "$ELF" 2>/dev/null \
    | grep -E '^\s*[0-9a-f]+:' | sed -E 's/^\s*[0-9a-f]+: //'
done | tee -a "$OUT/disasm-$CPU.txt"

echo "# Code size per language ($CPU, .text bytes)" | tee "$OUT/sizes-$CPU.txt"
for o in lib_c_clang lib_c_gcc lib_cpp lib_zig lib_d; do
  printf "%-14s %s\n" "$o" "$(llvm-size "build/xtensa-$CPU/$o.o" 2>/dev/null | awk 'NR==2{print $1}')"
done | tee -a "$OUT/sizes-$CPU.txt"
echo "analysis written to $OUT/"
