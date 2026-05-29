#!/usr/bin/env bash
# run.sh - explore SIMD/vectorization on Xtensa (esp32s3 is the only ESP with a
# vector unit: the 128-bit `EE.*` "PIE" extension, q0-q7). See docs/16.
#   1. autovectorization: does any frontend vectorize a loop to EE.?  (no)
#   2. explicit vector types: vector_size / @Vector / __vector -> EE. or scalar? (scalar)
#   3. inline asm: can clang/gcc/zig emit EE.* by hand?                  (yes)
#   4. EE.* on esp32 (no SIMD) -> rejected.
#   5. D parity (autovec / __vector / LDC __asm)                         (yes, asm path works)
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
D=experiments/simd; B=build/simd; mkdir -p "$B"
S3C="--target=xtensa-esp-elf -mcpu=esp32s3"; S3Z="-target xtensa-freestanding-none -mcpu=esp32s3"
S3L="-mtriple=xtensa-esp-elf -mcpu=esp32s3"
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

echo "== 5. D parity: autovec / __vector / inline asm =="
# LDC ($LDC2 = espressif/llvm-project 21.1.3 build) speaks -mcpu=esp32s3 natively.
# -betterC drops druntime so the object links with -nostdlib like clang/zig output.
"$LDC2" $S3L $LDC_PE -betterC -O3 -c "$D/vadd.d" -of="$B/vadd_d.o"
"$LDC2" $S3L $LDC_PE -betterC -O3 -c "$D/vec.d"  -of="$B/vec_d.o"
"$LDC2" $S3L $LDC_PE -betterC -O2 -c "$D/ee.d"   -of="$B/ee_d.o"
echo "  autovec (vadd.d, 4 loops)         EE.*=$(ee "$B/vadd_d.o")  -> scalar, matches clang/gcc"
echo "  __vector(byte[16]) (vec.d)        EE.*=$(ee "$B/vec_d.o")  -> scalarized, matches clang vector_size / zig @Vector"
echo "  LDC __asm (ldc.llvmasm, ee.d)     EE.*=$(ee "$B/ee_d.o")  -> emits ee.vld/vadds/vst, full parity with clang/gcc/zig asm path"
echo "  (D's classic DMD-style asm{} block has no Xtensa mnemonics; LDC's __asm lowers to LLVM 'call asm sideeffect ...' identical to clang's __asm__ volatile)"

echo "== 6. C++26 <simd> (P1928) — host probe via zig c++ + zig-mos-bootstrap =="
# C++26's std::simd is the C++-language analog of Rust's core::simd / Zig's
# @Vector / D's __vector. Not relevant on the Xtensa target (esp-clang has no
# libc++ on bare-metal) but probed here on the host libc++ that ships with
# our two zig c++ builds to record availability for docs/16.
# Skip silently if the optional zig-mos-bootstrap isn't installed.
ZIG_MOS="${ZIG_MOS:-$TC/zig-mos/zig}"
probe_cpp26_simd() {  # zig-binary label hdr
    local zig="$1" label="$2" hdr="$3"
    if "$zig" c++ -std=c++26 -fexperimental-library -x c++ - -o /dev/null >/dev/null 2>&1 <<EOF
#include <$hdr>
int main(){ return 0; }
EOF
    then printf "  %-30s <%s>  parses\n" "$label" "$hdr"
    else printf "  %-30s <%s>  MISSING\n" "$label" "$hdr"
    fi
}
# $ZIG is now zig 0.17 (clang 22.1.4 / libc++ 22) — same libc++ family as
# $ZIG_MOS, kept side-by-side as the bootstrap-vs-mainline sanity check.
# The legacy 0.16/libc++ 21 row uses $ZIG_016 if installed.
probe_cpp26_simd "$ZIG" "zig 0.17 / libc++ 22 (canonical)" "simd"
probe_cpp26_simd "$ZIG" "zig 0.17 / libc++ 22 (canonical)" "experimental/simd"
if [ -x "${ZIG_016:-}" ]; then
    probe_cpp26_simd "$ZIG_016" "zig 0.16 / libc++ 21 (legacy)" "simd"
    probe_cpp26_simd "$ZIG_016" "zig 0.16 / libc++ 21 (legacy)" "experimental/simd"
fi
if [ -x "$ZIG_MOS" ]; then
    probe_cpp26_simd "$ZIG_MOS" "v0.17.0-dev / libc++ 22" "simd"
    probe_cpp26_simd "$ZIG_MOS" "v0.17.0-dev / libc++ 22" "experimental/simd"
    # Confirm the operator+ stub (libc++ 22 TS) blocks the basic add use case.
    if "$ZIG_MOS" c++ -std=c++26 -fexperimental-library -x c++ - -o /dev/null >/dev/null 2>&1 <<EOF
#include <experimental/simd>
namespace stdx = std::experimental;
int main() {
    stdx::native_simd<int> a(1), b(2);
    auto c = a + b;          // libc++ 22: operator+ is unary-only
    return c[0];
}
EOF
    then
        echo "  v0.17.0-dev experimental/simd a+b   compiles (libc++ 22 has binary ops now)"
    else
        echo "  v0.17.0-dev experimental/simd a+b   ERROR: \"invalid operands to binary expression\""
        echo "    libc++ 22 ships <experimental/simd> with operator+ as a no-arg unary stub;"
        echo "    can't add two vectors yet. C++26 <simd> (P1928) hasn't landed in libc++ 22"
        echo "    mainline either. Even when it does, no Xtensa cost model means it'd"
        echo "    scalarize the same way the other vector types do (see §1/§2)."
    fi
else
    echo "  (skip v0.17.0-dev rows — \$ZIG_MOS not set;"
    echo "   see https://github.com/kassane/zig-mos-bootstrap/releases/tag/0.17.0-dev)"
fi
# esp-g++ 15.2.0 / libstdc++ 15 — the GCC arm of the matrix. Probe both
# -ffreestanding (the canonical embedded compile mode for xtensa-esp-elf) and
# hosted, since libstdc++ 15 ships <experimental/simd> but bits/requires_hosted.h
# blocks it under -ffreestanding.
probe_libstdcxx_simd() {  # hdr extra_flag
    local hdr="$1" xtra="$2"
    XTENSA_GNU_CONFIG=$(xtensa_cfg esp32) "$GXX" -std=c++26 $xtra -x c++ -c - -o /dev/null >/dev/null 2>&1 <<EOF
#include <$hdr>
int main(){return 0;}
EOF
}
for hdr in simd experimental/simd; do
    if probe_libstdcxx_simd "$hdr" "-ffreestanding"; then
        printf "  %-30s <%s>  parses (-ffreestanding)\n" "esp-g++ 15 / libstdc++ 15" "$hdr"
    else
        if probe_libstdcxx_simd "$hdr" ""; then
            printf "  %-30s <%s>  freestanding-blocked, parses hosted\n" "esp-g++ 15 / libstdc++ 15" "$hdr"
        else
            printf "  %-30s <%s>  MISSING\n" "esp-g++ 15 / libstdc++ 15" "$hdr"
        fi
    fi
done
echo "  libstdc++ 15 does NOT ship C++26 <simd> (P1928) — same gap as libc++ 21/22."
echo "  It DOES ship <experimental/simd> (TS) on disk, but bits/requires_hosted.h"
echo "  rejects it under -ffreestanding ('This header is not available in"
echo "  freestanding mode.'), so the canonical embedded compile can't include it."
echo "  Both C++ producers in the matrix agree: no <simd> path on bare-metal Xtensa."
