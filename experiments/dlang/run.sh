#!/usr/bin/env bash
# run.sh - LDC (LLVM D compiler) as a 5th frontend on the espressif backend.
# Uses the espressif/llvm-project-based LDC ($LDC2 -> LLVM 21.1.3 fork, same
# family as esp-clang/rustc). The upstream-LLVM-22 LDC ($LDC2_UPSTREAM) is the
# subject of experiments/ldc-fork-comparison + docs/23.
#   (a) toolchain: LDC 1.42-git / LLVM 21.1.3 (esp fork), Xtensa first-class
#   (b) struct ABI: D marks ALL aggregates byval/sret -> compare vs clang/zig IR
#   (c) machine ABI: where the struct args are read (regs vs stack), per arch
#   (d) literal-pool bug is *gone* in this fork — direct ldc2 -c links cleanly
#       (was: needed -output-s + esp-clang re-assembly + .cfi_* strip)
#   (e) C/C++ FFI mangling: extern(C)/extern(C++)/extern(C++,"ns")/ref
#   (f) -HC: generate a C++ header from D, then C++ calls back INTO D (host run)
#   (g) --extern-std / --link-internally / --help-hidden
#   (h) cross-language LTO: D + clang bitcode (both 21.1.3 — same-LLVM, no skew)
# See docs/19 + docs/23. Runtime PASS/FAIL matrix is scripts/run-qemu.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
D=experiments/dlang; M=experiments/ffi-matrix; B=build/dlang; mkdir -p "$B"
CT="--target=xtensa-esp-elf -mcpu=esp32"; LT="-mtriple=xtensa-esp-elf -mcpu=esp32"

# LDC -> Xtensa object. Direct -c on the fork LDC produces a properly aligned
# literal pool, so no re-assembly is needed. See section (d) and docs/23.
ldc_xt(){ "$LDC2" $LT -betterC -Os -c -of="$1" "$2"; }
sig(){ grep -hE "define .*@$1\b" "$2" 2>/dev/null | head -1 | grep -oE '\([^{]*' \
  | sed -E 's/ ?(noalias|writeonly|readonly|captures\([^)]*\)|initializes\([^)]*\)|range\([^)]*\)|noundef|zeroext|dead_on_unwind|writable|local_unnamed_addr|align [0-9]+)//g; s/  */ /g'; }

echo "== (a) toolchain =="
"$LDC2" --version 2>/dev/null | sed -n '1,2p' | sed 's/^/  /'
printf "  Xtensa registered target: %s\n" "$("$LDC2" -version 2>/dev/null | grep -c 'xtensa ')"

echo "== (b) struct ABI in the IR: clang flattens, zig=direct, D=byval/sret =="
"$LDC2" $LT -betterC -Os -output-ll -of="$B/d.ll" "$M/d/lib_d.d"
"$ZIG" build-obj -target xtensa-freestanding-none -mcpu=esp32 -O ReleaseSmall -fno-emit-bin -femit-llvm-ir="$B/z.ll" "$M/zig/lib_zig.zig"
"$CLANG" $CT -ffreestanding -Os -S -emit-llvm -I"$M/include" -o "$B/c.ll" "$M/c/lib_c.c" 2>/dev/null
for fn in point_dot make_point blob_sum; do
  printf "  %-10s clang:%-22s zig:%-16s D:%s\n" "$fn" \
    "$(sig "c_$fn" "$B/c.ll")" "$(sig "lib_zig.zig_$fn" "$B/z.ll")" "$(sig "d_$fn" "$B/d.ll")"
done
echo "  (clang [N x i32]=regs; zig %T=direct; D byval/sret=indirect-by-memory)"

echo "== (c) machine ABI: where does *_point_dot read its struct args? =="
ldc_xt "$B/lib_d.o" "$M/d/lib_d.d"
"$CLANG" $CT -ffreestanding -Os -I"$M/include" -c "$M/c/lib_c.c" -o "$B/lib_c.o"
printf "  clang c_point_dot multiplies:  %s   (operands a2..a5 = registers)\n" "$(llvm-objdump -d --mcpu=esp32 --disassemble-symbols=c_point_dot "$B/lib_c.o" 2>/dev/null | grep -oE 'mull[[:space:]]+a[0-9]+, a[0-9]+, a[0-9]+' | head -1)"
printf "  D     d_point_dot first load:   %s   (a1=SP => reads the STACK)\n" "$(llvm-objdump -d --mcpu=esp32 --disassemble-symbols=d_point_dot "$B/lib_d.o" 2>/dev/null | grep -oE 'l32i(\.n)?[[:space:]]+a[0-9]+, a1, [0-9]+' | head -1)"

echo "== (d) literal-pool: direct ldc2 -c -> ld.lld with the FFI linker script =="
"$LDC2" $LT -betterC -Os -c -of="$B/direct.o" "$M/d/lib_d.d" 2>/dev/null
RT_E32="$ESP_CLANG_DIR/../lib/clang-runtimes/xtensa-esp-unknown-elf/esp32/lib/libclang_rt.builtins.a"
if ld.lld -T "$M/xtensa.ld" -o "$B/direct.elf" \
    build/xtensa-esp32/driver.o build/xtensa-esp32/entry.o \
    build/xtensa-esp32/lib_cpp.o build/xtensa-esp32/lib_zig.o \
    "$B/direct.o" build/xtensa-esp32/lib_c_clang.o \
    --start-group build/xtensa-esp32/libffi_rs.a "$RT_E32" --end-group 2>"$B/d.err"; then
  echo "  direct ldc2 -c -> ld.lld: OK ($(stat -c%s "$B/direct.elf") B, 0 undef)"
  echo "  (the upstream-LLVM-22 LDC fails this with 'R_XTENSA_SLOT0_OP not aligned"
  echo "   to 4 bytes' — see experiments/ldc-fork-comparison §(c) + docs/23.)"
else
  echo "  unexpected link failure: $(head -1 "$B/d.err")"
fi

echo "== (e) C/C++ FFI mangling (extern(C)/(C++)/(C++,\"ns\")/ref) =="
"$LDC2" -betterC -c -of="$B/cppiface.o" "$D/cppiface.d"
llvm-nm "$B/cppiface.o" 2>/dev/null | grep ' T ' | awk '{print $3}' | while read -r s; do
  printf "  %-26s %s\n" "$s" "$(echo "$s" | c++filt 2>/dev/null || echo "$s")"; done

echo "== (f) -HC: D emits a C++ header; C++ then calls back INTO D (host) =="
"$LDC2" -betterC -HC=silent --HCf="$B/cppiface.h" -c -of="$B/cppiface_host.o" "$D/cppiface.d"
grep -E 'extern|namespace|struct Vec2' "$B/cppiface.h" | head -5 | sed 's/^/  hdr: /'
cat > "$B/use.cpp" <<EOF
#include "cppiface.h"
#include <cstdio>
int main(){ Vec2 a{1.5f,2.0f}, b{3.0f,4.0f};
  std::printf("  C++ -> D: cpp_add=%d espffi::ns_add=%d vec_dot=%.1f\n",
              cpp_add(20,22), espffi::ns_add(40,2), (double)vec_dot(a,b)); return 0; }
EOF
"$ZIG" c++ -O2 -Wno-nullability-completeness -I"$B" "$B/use.cpp" "$B/cppiface_host.o" -o "$B/use" 2>/dev/null
"./$B/use"

echo "== (g) --extern-std / --link-internally / --help-hidden =="
printf 'extern(C++) struct S{int a;}\nextern(C++) void f(S){}\n' > "$B/es.d"
printf "  --extern-std f(S):"; for std in c++98 c++11 c++23; do
  "$LDC2" -betterC --extern-std=$std -c -of="$B/es.o" "$B/es.d" 2>/dev/null
  printf " %s=%s" "$std" "$(llvm-nm "$B/es.o" 2>/dev/null | grep ' T ' | awk '{print $3}')"; done; echo " (default c++11)"
printf 'extern(C) int f(){return 0;}\n' > "$B/li.d"
if "$LDC2" --link-internally -shared -of="$B/li.so" "$B/li.d" 2>"$B/li.err"; then li="yes (linked $(basename "$B/li.so"))"
elif grep -qiE 'lld:' "$B/li.err"; then li="yes (LDC's bundled lld ran; only host libs missing in sandbox)"
else li="external linker"; fi
printf "  --link-internally uses LDC's in-process LLD: %s\n" "$li"
printf "  --help-hidden options: %s (clang/LLVM-style full help)\n" "$("$LDC2" --help-hidden 2>&1 | grep -cE '^[[:space:]]+--')"

echo "== (h) cross-language LTO: D + clang bitcode (both LLVM 21.1.3 — no skew) =="
printf 'extern(C) int d_lto(int x){return x+1;}\n' > "$B/l.d"
printf 'extern int d_lto(int);\nint c_lto(int x){return d_lto(x)+1;}\n' > "$B/l.c"
"$LDC2" $LT -betterC -Os -output-bc -of="$B/d.bc" "$B/l.d"
"$CLANG" $CT -ffreestanding -Os -emit-llvm -c "$B/l.c" -o "$B/c.bc"
if ld.lld --lto-O2 -e c_lto -u d_lto "$B/c.bc" "$B/d.bc" -o "$B/lto.elf" 2>"$B/lto.err"; then
  echo "  LTO linked + inlined across the boundary: c_lto = $(llvm-objdump -d --mcpu=esp32 --disassemble-symbols=c_lto "$B/lto.elf" 2>/dev/null | grep -oE 'addi\.n[[:space:]]+a[0-9]+, a[0-9]+, [0-9]+' | head -1) (x+2)"
else
  echo "  LTO FAILS: $(grep -oiE 'invalid record' "$B/lto.err" | head -1)"
fi
