#!/usr/bin/env bash
# run.sh - explore SIMD/vectorization on Xtensa (esp32s3 is the only ESP with a
# vector unit: the 128-bit `EE.*` "PIE" extension, q0-q7). See docs/16.
#   1. autovectorization: does any frontend vectorize a loop to EE.*?  (no)
#   2. explicit vector types: vector_size / @Vector -> EE.* or scalarized? (scalar)
#   3. inline asm: can clang/gcc/zig emit EE.* by hand?                  (yes)
#   4. EE.* on esp32 (no SIMD) -> rejected.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
D=experiments/simd; B=build/simd; mkdir -p "$B"
S3C="--target=xtensa-esp-elf -mcpu=esp32s3"; S3Z="-target xtensa-freestanding-none -mcpu=esp32s3"
 G3="XTENSA_GNU_CONFIG=$(xtensa_cfg esp32s3)"
ee(){ llvm-objdump -d --mcpu=esp32s3 "$1" 2>/dev/null | grep -ciE 'ee\.v'; }

echo "== 1. autovectorize vadd loops (i8/i16/i32/f32), -O3 -> EE.* count (expect 0) =="
"$CLANG" $S3C -ffreestanding -O3 -c "$D/vadd.c" -o "$B/vadd_clang.o"
eval $G3 "$GCC" -ffreestanding -O3 -c "$D/vadd.c" -o "$B/vadd_gcc.o"
echo "  clang: $(ee "$B/vadd_clang.o")   gcc: $(eval $G3 xtensa-esp-elf-objdump -d "$B/vadd_gcc.o" 2>/dev/null | grep -ciE 'ee\.v')   -> scalar loops, no SIMD"

echo "== 2. explicit vector types -> scalarized (no q-reg codegen) =="
"$CLANG" $S3C -ffreestanding -O3 -c "$D/vec.c" -o "$B/vec.o"
"$ZIG" build-obj $S3Z -O ReleaseFast -femit-bin="$B/zvec.o" "$D/zvec.zig"
echo "  clang vector_size(16) EE.*=$(ee "$B/vec.o") (scalar add x16);  zig @Vector EE.*=$(ee "$B/zvec.o") (scalar)"

echo "== 3. inline asm EE.* (the only way to use S3 SIMD) =="
"$CLANG" $S3C -ffreestanding -O2 -c "$D/ee.c" -o "$B/ee_clang.o"
eval $G3 "$GCC" -ffreestanding -O2 -c "$D/ee.c" -o "$B/ee_gcc.o"
"$ZIG" build-obj $S3Z -O ReleaseSmall -femit-bin="$B/ee_zig.o" "$D/ee.zig"   # struct-form clobbers
echo "  EE.* emitted -> clang:$(ee "$B/ee_clang.o")  gcc:$(eval $G3 xtensa-esp-elf-objdump -d "$B/ee_gcc.o" 2>/dev/null|grep -ciE 'ee\.v')  zig:$(ee "$B/ee_zig.o")"

echo "== Rust (xtensa-esp32s3-none-elf -O3): autovec, core::simd, inline asm =="
( cd "$D/rs" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target xtensa-esp32s3-none-elf >/dev/null 2>&1 )
RA=$(find "$D/rs/target" -name 'libsimd_rs.a' | head -1)
rsee(){ llvm-objdump -d --mcpu=esp32s3 --disassemble-symbols=$1 "$RA" 2>/dev/null | grep -ciE 'ee\.v'; }
echo "  rs_vadd_i8 (autovec loop) EE.*=$(rsee rs_vadd_i8)   rs_simd_add (core::simd) EE.*=$(rsee rs_simd_add)   rs_ee_vadd (asm!) EE.*=$(rsee rs_ee_vadd)"
echo "  (rust needs #![feature(asm_experimental_arch)] for xtensa asm!; no qreg class — esp-rs #265)"

echo "== 4. EE.* on esp32 (LX6, no SIMD) -> assembler rejects =="
if "$CLANG" --target=xtensa-esp-elf -mcpu=esp32 -ffreestanding -O2 -c "$D/ee.c" -o "$B/ee_esp32.o" 2>/dev/null; then
    echo "  (unexpected) assembled on esp32"
else
    echo "  rejected: 'instruction use requires an option to be enabled' (S3-only)"
fi
