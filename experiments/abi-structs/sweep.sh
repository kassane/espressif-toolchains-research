#!/usr/bin/env bash
# sweep.sh - find what actually triggers Zig's Xtensa struct-arg ABI divergence.
#
# Generates `caller(T) -> ext(T)` for several struct shapes, compiles it with
# clang and with zig for esp32, and classifies how each passes the by-value
# struct argument: in registers (a10..a15, matching the Xtensa C ABI) or spilled
# to the stack (movsp). Result: the discriminator is ALIGNMENT, not size.
#
# Usage:  source scripts/env.sh && experiments/abi-structs/sweep.sh [cpu]
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
CPU=${1:-esp32}; CT="--target=xtensa-esp-elf -mcpu=$CPU"
B="build/sweep"; mkdir -p "$B"

classify() { # $1=object -> how `caller` passes the outgoing struct arg
    local d; d=$(llvm-objdump -d --mcpu="$CPU" --disassemble-symbols=caller "$1" 2>/dev/null)
    if echo "$d" | grep -q 'movsp'; then echo "STACK (movsp)"; else echo "REGISTERS"; fi
}

printf "%-20s %-6s %-14s | %-14s %-14s %s\n" "struct" "align" "clang IR arg" "clang" "zig" "FFI"
printf -- '-%.0s' {1..78}; echo
# spec = "label:c-type:zig-type:align"
for spec in \
    "[8]u8:unsigned char d[8]:[8]u8:1" \
    "[16]u8:unsigned char d[16]:[16]u8:1" \
    "[24]u8:unsigned char d[24]:[24]u8:1" \
    "{2xu32}:unsigned d[2]:[2]u32:4" \
    "{6xu32}:unsigned d[6]:[6]u32:4" ; do
    lbl=${spec%%:*}; rest=${spec#*:}; cty=${rest%%:*}; rest=${rest#*:}; zty=${rest%%:*}; al=${rest#*:}
    printf '#include <stdint.h>\ntypedef struct{%s;}T;\nextern uint32_t ext(T);\nuint32_t caller(T x){return ext(x);}\n' "$cty" > "$B/s.c"
    printf 'const T=extern struct{x:%s};\nextern fn ext(T) callconv(.c) u32;\nexport fn caller(v:T) u32 { return ext(v); }\n' "$zty" > "$B/s.zig"
    "$CLANG" $CT -ffreestanding -O2 -c "$B/s.c" -o "$B/s_c.o" 2>/dev/null
    "$ZIG" build-obj -target xtensa-freestanding-none -mcpu="$CPU" -O ReleaseFast -femit-bin="$B/s_z.o" "$B/s.zig" 2>/dev/null
    ir=$("$CLANG" $CT -ffreestanding -O0 -S -emit-llvm "$B/s.c" -o - 2>/dev/null | grep -oE '@caller\([^)]*\)' | grep -oE '\[[0-9]+ x i32\]|ptr[^,)]*' | head -1)
    c=$(classify "$B/s_c.o"); z=$(classify "$B/s_z.o")
    [ "$c" = "$z" ] && verdict="ok" || verdict="MISMATCH"
    printf "%-20s %-6s %-14s | %-14s %-14s %s\n" "$lbl" "$al" "$ir" "$c" "$z" "$verdict"
done
