#!/usr/bin/env bash
# run.sh - true LLVM module-merge across all five frontends, using the matching
# LLVM 22.1.2 binutils (ldc-developers/llvm-project ldc-v22.1.2) that esp-clang
# does NOT ship. Closes the docs/04 §(b) gap: the host's llvm-link is LLVM 18 and
# rejects the post-18 IR the frontends emit; the LLVM-22 tools read all of it.
#   (a) the tools (LLVM 22.1.2 vs the host's LLVM 18)
#   (b) llvm-link: host-18 FAILS, LLVM-22 merges driver+C+Rust+Zig+D into 1 module
#   (c) opt -O2 over the merged module -> cross-module inline (D->D: x+2)
#   (d) llvm-dis reads LDC's LLVM-22 bitcode (host-18 cannot)
#   (e) datalayout: D (upstream LLVM-22) differs from the espressif-LLVM-21 trio
# Needs setup.sh LLVM22=1 (the 405 MB LLVM tarball). See docs/04.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
L="$LDC_LLVM_DIR/bin"; M=experiments/ffi-matrix; INC="$PWD/$M/include"; B=build/irmix; mkdir -p "$B"
CT="--target=xtensa-esp-elf -mcpu=esp32"
[ -x "$L/llvm-link" ] || { echo "missing $L/llvm-link — run: LLVM22=1 ./scripts/setup.sh"; exit 1; }

echo "== (a) tools =="
printf "  matching: %s\n" "$("$L/llvm-link" --version 2>/dev/null | grep -oE 'LLVM version [0-9.]+')"
printf "  host:     %s (rejects post-18 IR)\n" "$(llvm-link --version 2>/dev/null | grep -oE 'LLVM version [0-9.]+' | head -1)"

echo "== (b) emit IR for all five frontends (esp32), then llvm-link =="
"$CLANG" $CT -ffreestanding -O1 -S -emit-llvm -I"$INC" "$M/driver.c"  -o "$B/driver.ll" 2>/dev/null
"$CLANG" $CT -ffreestanding -O1 -S -emit-llvm -I"$INC" "$M/c/lib_c.c" -o "$B/lib_c.ll"  2>/dev/null
"$ZIG" build-obj -target xtensa-freestanding-none -mcpu=esp32 -O ReleaseSmall -fno-emit-bin -femit-llvm-ir="$B/lib_zig.ll" "$M/zig/lib_zig.zig" 2>/dev/null
( cd "$M/rust" && RUSTC="$RUSTC" "$CARGO" rustc --release -Z build-std=core --target xtensa-esp32-none-elf -- --emit=llvm-ir >/dev/null 2>&1 )
cp "$(find "$M/rust/target/xtensa-esp32-none-elf/release" -name 'ffi_rs*.ll'|head -1)" "$B/lib_rs.ll"
"$LDC2" -mtriple=xtensa-esp-elf -mcpu=esp32 -betterC -O1 -output-ll -of="$B/lib_d.ll" "$M/d/lib_d.d" 2>/dev/null
printf "  host LLVM-18 llvm-link driver.ll: %s\n" "$(llvm-link "$B/driver.ll" -S -o /dev/null 2>&1 | grep -oiE 'expected type|error' | head -1) (post-18 'nuw' GEP)"
rc=0; "$L/llvm-link" "$B"/driver.ll "$B"/lib_c.ll "$B"/lib_rs.ll "$B"/lib_zig.ll "$B"/lib_d.ll -S -o "$B/merged.ll" 2>/dev/null || rc=$?
printf "  LLVM-22 llvm-link 5 frontends -> 1 module: %s defines (llvm-link rc=%s)\n" "$(grep -c '^define' "$B/merged.ll")" "$rc"

echo "== (c) opt -O2 over the merge -> cross-module inline (D->D) =="
printf 'extern(C) int d_inc(int x){return x+1;}\n' > "$B/callee.d"
printf 'extern(C) int d_inc(int);\nextern(C) int d_use(int x){return d_inc(x)+1;}\n' > "$B/caller.d"
"$LDC2" -mtriple=xtensa-esp-elf -mcpu=esp32 -betterC -O0 -output-ll -of="$B/callee.ll" "$B/callee.d" 2>/dev/null
"$LDC2" -mtriple=xtensa-esp-elf -mcpu=esp32 -betterC -O0 -output-ll -of="$B/caller.ll" "$B/caller.d" 2>/dev/null
"$L/llvm-link" "$B/caller.ll" "$B/callee.ll" -S -o "$B/two.ll" 2>/dev/null
"$L/opt" -O2 -S "$B/two.ll" -o "$B/two_opt.ll" 2>/dev/null
printf "  d_use after merge+opt: %s  (d_inc inlined -> x+2)\n" "$(sed -n '/define.*@d_use/,/^}/p' "$B/two_opt.ll" | grep -oE 'add i32 %[a-z_]+, [0-9]+' | head -1)"
echo "  (cross-FRONTEND inline is gated by matching target-features; the ld.lld"
echo "   LTO path inlines clang<->D regardless — docs/19 §6.)"

echo "== (d) llvm-dis reads LDC's LLVM-22 bitcode (host-18 cannot) =="
"$LDC2" -mtriple=xtensa-esp-elf -mcpu=esp32 -betterC -O1 -output-bc -of="$B/lib_d.bc" "$M/d/lib_d.d" 2>/dev/null
"$L/llvm-dis" "$B/lib_d.bc" -o "$B/lib_d_dis.ll" 2>/dev/null
printf "  producer: %s\n" "$(grep -oE '"ldc version[^"]*"' "$B/lib_d_dis.ll" | head -1)"
hostdis=$(llvm-dis "$B/lib_d.bc" -o /dev/null 2>&1 | grep -oiE 'Unknown attribute[^)]*\)|Invalid record' | head -1 || true)
printf "  host-18 llvm-dis on the 22 bitcode: %s\n" "${hostdis:-(read ok)}"

echo "== (e) datalayout: D (upstream LLVM-22) vs the espressif-LLVM-21 trio =="
printf "  clang/rust/zig: %s\n" "$(grep -oE 'target datalayout = "[^"]*"' "$B/lib_c.ll" | head -1 | sed -E 's/target datalayout = //')"
printf "  D (LDC 22):     %s\n" "$(grep -oE 'target datalayout = "[^"]*"' "$B/lib_d.ll" | head -1 | sed -E 's/target datalayout = //')"
echo "  (differs: D drops v1:8:8/i128:128, adds i8:8:32/i16:16:32 — llvm-link warns,"
echo "   still merges; C-ABI struct layout is unaffected, runtime-verified docs/19.)"
echo "  NOTE: esp32 *codegen* of the merged/22 IR still needs the espressif backend"
echo "  (upstream LLVM-22 has no esp32 CPU model); these tools are for IR merge/inspect."
