#!/usr/bin/env bash
# run.sh - parity check across the C/C++ compiler drivers on Xtensa esp32:
#   C  : zig cc      vs esp-clang   vs esp-gcc
#   C++: zig c++     vs esp-clang++ vs esp-g++
# Compares target acceptance, real .text (llvm-size -A, NOT Berkeley which counts
# zig's default .eh_frame), eh_frame defaults, ABI (point_dot), and the Itanium
# C++ mangling/vtable surface. See docs/15.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
SRC=experiments/ffi-matrix; INC="$PWD/$SRC/include"; HERE=experiments/compiler-parity
B=build/parity; mkdir -p "$B"
ZT="-target xtensa-freestanding-none -mcpu=esp32"; CT="--target=xtensa-esp-elf -mcpu=esp32"
GE="XTENSA_GNU_CONFIG=$(xtensa_cfg esp32)"

sec(){ printf "  %-13s .text=%-5s eh_frame=%-5s\n" "$1" \
  "$(llvm-size -A "$2" 2>/dev/null | awk '/^\.text/{t+=$2} END{print t}')" \
  "$(llvm-size -A "$2" 2>/dev/null | awk '/eh_frame/{print $2}' || true)"; }

echo "== C drivers (lib_c.c, -ffreestanding -Os) =="
"$ZIG" cc $ZT -ffreestanding -fno-sanitize=undefined -Os -I"$INC" -c "$SRC/c/lib_c.c" -o "$B/c_zig.o"
"$CLANG"  $CT -ffreestanding -Os -I"$INC" -c "$SRC/c/lib_c.c" -o "$B/c_clang.o"
eval $GE "$GCC" -ffreestanding -Os -I"$INC" -c "$SRC/c/lib_c.c" -o "$B/c_gcc.o"
sec "zig cc"    "$B/c_zig.o"; sec "esp-clang" "$B/c_clang.o"; sec "esp-gcc" "$B/c_gcc.o"
echo "  (zig cc emits .eh_frame unwind tables by default; strip with -fno-unwind-tables)"

echo "== C++ drivers (lib_cpp.cpp, -ffreestanding -fno-exceptions -fno-rtti -Os) =="
CXX="-ffreestanding -fno-exceptions -fno-rtti -fno-threadsafe-statics -Os"
"$ZIG" c++ $ZT $CXX -fno-sanitize=undefined -I"$INC" -c "$SRC/cpp/lib_cpp.cpp" -o "$B/x_zig.o"
"$CLANGXX" $CT $CXX -I"$INC" -c "$SRC/cpp/lib_cpp.cpp" -o "$B/x_clang.o"
eval $GE "$GXX" $CXX -I"$INC" -c "$SRC/cpp/lib_cpp.cpp" -o "$B/x_gcc.o"
sec "zig c++"     "$B/x_zig.o"; sec "esp-clang++" "$B/x_clang.o"; sec "esp-g++" "$B/x_gcc.o"

echo "== C++ Itanium ABI parity (mangling + vtable symbols must match) =="
"$ZIG" c++ $ZT $CXX -fno-sanitize=undefined -c "$HERE/mangle.cpp" -o "$B/m_zig.o"
"$CLANGXX" $CT $CXX -c "$HERE/mangle.cpp" -o "$B/m_clang.o"
eval $GE "$GXX" $CXX -c "$HERE/mangle.cpp" -o "$B/m_gcc.o"
for o in m_zig m_clang m_gcc; do
  printf "  %-9s %s\n" "$o" "$(llvm-nm "$B/$o.o" 2>/dev/null | grep -oE '_ZN4demo3addEii|_ZN4Base1fEi|_ZTV7Derived' | sort | tr '\n' ' ')"
done
echo "== point_dot ABI: zig==esp-clang (clang21), gcc same ABI/diff regalloc =="
for o in c_zig c_clang c_gcc; do
  printf "  %-8s %s\n" "$o" "$(llvm-objdump -d --mcpu=esp32 --disassemble-symbols=c_point_dot "$B/$o.o" 2>/dev/null | grep -oE '(entry|mull|add\.n|mov\.n|retw\.n)[^;]*' | tr '\n' ' ')"
done
