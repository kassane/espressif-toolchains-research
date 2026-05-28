#!/usr/bin/env bash
# sweep.sh - find what actually triggers Zig's Xtensa struct-arg ABI divergence.
#
# Generates `caller(T) -> ext(T)` for several struct shapes, compiles it with
# clang and with zig for esp32, and classifies how each passes the by-value
# struct argument: in registers (a10..a15, matching the Xtensa C ABI) or spilled
# to the stack (movsp). Result: the discriminator is ALIGNMENT, not size.
#
# Extended with three C-bitfield rows (16/32/64-bit packed structs) — D
# supports C-style bitfield syntax natively in extern(C) structs (no preview
# flag needed in LDC 1.42+). Zig's analog is `packed struct(uN)` with an
# explicit backing integer (without the backing, Zig errors:
# "parameter of type 'F' not allowed in function with calling convention
# 'xtensa_call0'" — implicit-signedness gate). The bitfield rows expose the
# same D-frontend bug the byte-array rows do: clang flattens the packed
# struct to its backing scalar; D wraps it in byval anyway.
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

printf "%-22s %-6s %-14s | %-14s %-14s %-14s %s\n" "struct" "align" "clang IR arg" "clang" "zig" "D" "FFI"
printf -- '-%.0s' {1..96}; echo
# spec = "label:c-type:zig-type:d-type:align"
for spec in \
    "[8]u8:unsigned char d[8]:[8]u8:ubyte[8] d:1" \
    "[16]u8:unsigned char d[16]:[16]u8:ubyte[16] d:1" \
    "[24]u8:unsigned char d[24]:[24]u8:ubyte[24] d:1" \
    "{2xu32}:unsigned d[2]:[2]u32:uint[2] d:4" \
    "{6xu32}:unsigned d[6]:[6]u32:uint[6] d:4" ; do
    lbl=${spec%%:*}; rest=${spec#*:}; cty=${rest%%:*}; rest=${rest#*:}; zty=${rest%%:*}; rest=${rest#*:}; dty=${rest%%:*}; al=${rest#*:}
    printf '#include <stdint.h>\ntypedef struct{%s;}T;\nextern uint32_t ext(T);\nuint32_t caller(T x){return ext(x);}\n' "$cty" > "$B/s.c"
    printf 'const T=extern struct{x:%s};\nextern fn ext(T) callconv(.c) u32;\nexport fn caller(v:T) u32 { return ext(v); }\n' "$zty" > "$B/s.zig"
    # D: extern(C) struct + caller forwarding by-value to ext; -betterC drops druntime.
    printf 'extern(C) struct T { %s; }\nextern(C) uint ext(T);\nextern(C) uint caller(T x) { return ext(x); }\n' "$dty" > "$B/s.d"
    "$CLANG" $CT -ffreestanding -O2 -c "$B/s.c" -o "$B/s_c.o" 2>/dev/null
    "$ZIG" build-obj -target xtensa-freestanding-none -mcpu="$CPU" -O ReleaseFast -femit-bin="$B/s_z.o" "$B/s.zig" 2>/dev/null
    "$LDC2" -mtriple=xtensa-esp-elf -mcpu="$CPU" -betterC -O2 -c -of="$B/s_d.o" "$B/s.d" 2>/dev/null
    ir=$("$CLANG" $CT -ffreestanding -O0 -S -emit-llvm "$B/s.c" -o - 2>/dev/null | grep -oE '@caller\([^)]*\)' | grep -oE '\[[0-9]+ x i32\]|ptr[^,)]*' | head -1)
    c=$(classify "$B/s_c.o"); z=$(classify "$B/s_z.o"); d=$(classify "$B/s_d.o")
    diff=""
    [ "$c" != "$z" ] && diff="${diff}zig "
    [ "$c" != "$d" ] && diff="${diff}D "
    if [ -z "$diff" ]; then verdict="ok"; else verdict="MISMATCH (${diff% })"; fi
    printf "%-22s %-6s %-14s | %-14s %-14s %-14s %s\n" "$lbl" "$al" "$ir" "$c" "$z" "$d" "$verdict"
done

echo
echo "C-bitfield rows (D has native C-style bitfields in extern(C); Zig uses"
echo "packed struct(uN) with EXPLICIT backing — without backing Zig errors"
echo "on extern callconv: 'parameter of type ... not allowed in function with"
echo "calling convention xtensa_call0' / 'inferred backing integer of packed"
echo "struct has unspecified signedness'):"
echo
# bitfield_spec uses '|' separators since C/D bitfield syntax has colons in it.
# Format: label|c-bf|zig-packed-typedecl|d-bf|align
for bspec in \
    "bf 16b(4+4+8)|unsigned a:4; unsigned b:4; unsigned c:8|packed struct(u16) { a: u4, b: u4, c: u8 }|uint a : 4; uint b : 4; uint c : 8|2" \
    "bf 32b(8+8+16)|unsigned a:8; unsigned b:8; unsigned c:16|packed struct(u32) { a: u8, b: u8, c: u16 }|uint a : 8; uint b : 8; uint c : 16|4" \
    "bf 64b(32+32)|unsigned long long a:32; unsigned long long b:32|packed struct(u64) { a: u32, b: u32 }|ulong a : 32; ulong b : 32|8"; do
    full_lbl="${bspec%%|*}"; rest="${bspec#*|}"
    cbf="${rest%%|*}"; rest="${rest#*|}"
    zsstr="${rest%%|*}"; rest="${rest#*|}"
    dbf="${rest%%|*}"; rest="${rest#*|}"
    al="${rest%%|*}"
    printf '#include <stdint.h>\ntypedef struct { %s; } T;\nextern uint32_t ext(T);\nuint32_t caller(T x) { return ext(x); }\n' "$cbf" > "$B/s.c"
    printf 'const T = %s;\nextern fn ext(T) callconv(.c) u32;\nexport fn caller(v: T) u32 { return ext(v); }\n' "$zsstr" > "$B/s.zig"
    printf 'extern(C) struct T { %s; }\nextern(C) uint ext(T);\nextern(C) uint caller(T x) { return ext(x); }\n' "$dbf" > "$B/s.d"
    "$CLANG" $CT -ffreestanding -O2 -c "$B/s.c" -o "$B/s_c.o" 2>/dev/null
    "$ZIG" build-obj -target xtensa-freestanding-none -mcpu="$CPU" -O ReleaseFast -femit-bin="$B/s_z.o" "$B/s.zig" 2>/dev/null
    "$LDC2" -mtriple=xtensa-esp-elf -mcpu="$CPU" -betterC -O2 -c -of="$B/s_d.o" "$B/s.d" 2>/dev/null
    ir=$("$CLANG" $CT -ffreestanding -O0 -S -emit-llvm "$B/s.c" -o - 2>/dev/null \
         | grep -oE '@caller\([^)]*\)' \
         | grep -oE 'i[0-9]+ [a-z]*|\[[0-9]+ x i[0-9]+\]|ptr[^,)]*' | head -1 || true)
    c=$(classify "$B/s_c.o"); z=$(classify "$B/s_z.o"); d=$(classify "$B/s_d.o")
    # Inspect IR-level signatures for D vs clang (bitfield-specific check)
    "$LDC2" -mtriple=xtensa-esp-elf -mcpu="$CPU" -betterC -output-ll -of="$B/s_d.ll" "$B/s.d" 2>/dev/null
    # Extract just the parameter list (between @caller( and the matching ))
    d_ir=$(grep -oE '@caller\([^)]*\)' "$B/s_d.ll" | head -1 \
           | grep -oE 'byval\(%[^)]*\)|i[0-9]+[^,)]*' | head -1 || true)
    printf "%-22s %-6s %-14s | %-14s %-14s %-14s D-IR=%s\n" "$full_lbl" "$al" "$ir" "$c" "$z" "$d" "$d_ir"
done

echo
echo "Summary:"
echo "  byte-array rows: zig stack-spills the align-1 by-value (the classic"
echo "    docs/05 hole); D's IR is byval but the espressif Xtensa backend"
echo "    lowers it without movsp, so the heuristic puts it in REGISTERS."
echo "  word-array rows: all three agree (REGISTERS), trivial."
echo "  bitfield rows: clang flattens to the scalar backing type and ships"
echo "    it as i16/i32/[2 x i32] in regs. Zig with explicit packed-struct"
echo "    backing matches clang exactly. D emits byval(struct) IR for every"
echo "    bitfield case, just like every other aggregate — the bug isn't"
echo "    bitfield-specific, it's universal to LDC's frontend (docs/19/23)."
