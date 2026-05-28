#!/usr/bin/env bash
# sweep.sh - 6-frontend by-value struct-arg ABI sweep on Xtensa.
#
# Generates `caller(T) -> ext(T)` in every language we can build for esp32 and
# classifies how each passes the by-value struct argument: in registers
# (a10..a15, matching the Xtensa C ABI) or spilled to the stack (movsp).
# Result: the discriminator is ALIGNMENT, not size — zig stack-spills align-1
# byte arrays; the rest agree.
#
# Frontend matrix:
#   clang   — extern(C) struct, direct .o (the C-ABI reference)
#   gcc     — same C source, xtensa-esp-elf-gcc (independent C-ABI check)
#   rust    — #[repr(C)] struct, extern "C" caller (LLVM 21.1.3)
#   zig     — extern struct, callconv(.c)
#   D/LDC   — extern(C) struct, -betterC
#   TinyGo  — `//export caller`; produces a relocatable Xtensa ELF that brings
#             the Go runtime undefs (docs/24 §d); for this sweep we only need
#             the `caller` symbol's disasm, not a final link
#
# Bitfield rows (16/32/64-bit packed structs): clang/gcc/zig/D only.
# Rust has no native bitfield syntax; TinyGo (Go) doesn't either — marked N/A.
#
# Usage:  source scripts/env.sh && experiments/abi-structs/sweep.sh [cpu]
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
CPU=${1:-esp32}; CT="--target=xtensa-esp-elf -mcpu=$CPU"
B="build/sweep"; mkdir -p "$B"
G="XTENSA_GNU_CONFIG=$(xtensa_cfg "$CPU")"

classify() { # $1=object -> how `caller` passes the outgoing struct arg
    local d
    d=$("$ESP_CLANG_DIR/llvm-objdump" -d --mcpu="$CPU" --disassemble-symbols=caller "$1" 2>/dev/null || true)
    if [ -z "$d" ]; then echo "—"; return; fi
    if echo "$d" | grep -q 'movsp'; then echo "STACK (movsp)"; else echo "REGISTERS"; fi
}

build_rust() { # $1=field-decl   -> writes $B/s_r.o
    local field="$1"
    mkdir -p "$B/rs/src"
    cat > "$B/rs/Cargo.toml" <<EOF
[package]
name="rs_sweep"
version="0.0.0"
edition="2021"
[lib]
path="src/lib.rs"
crate-type=["staticlib"]
[profile.release]
panic="abort"
opt-level=2
EOF
    cat > "$B/rs/src/lib.rs" <<EOF
#![no_std]
#[panic_handler] fn p(_:&core::panic::PanicInfo)->!{loop{}}
#[repr(C)] pub struct T { pub $field }
extern "C" { fn ext(x:T)->u32; }
#[no_mangle] pub extern "C" fn caller(x:T)->u32 { unsafe { ext(x) } }
EOF
    ( cd "$B/rs" && RUSTC="$RUSTC" "$CARGO" rustc --release -Z build-std=core \
        --target xtensa-"$CPU"-none-elf -- --emit=obj >/dev/null 2>&1 ) || return 1
    local rso
    rso=$(find "$B/rs/target/xtensa-$CPU-none-elf/release/deps" -name 'rs_sweep-*.o' | head -1)
    [ -n "$rso" ] && cp "$rso" "$B/s_r.o"
}

build_tinygo() { # $1=go-field-decl   -> writes $B/s_g.o (or skips if TINYGO unset)
    local field="$1"
    [ -x "${TINYGO:-}" ] || return 1
    cat > "$B/probe.go" <<EOF
package main
type T struct { $field }
//go:noinline
func ext(x T) uint32 { return uint32(0) }
//go:noinline
//export caller
func caller(x T) uint32 { return ext(x) }
func main() {}
EOF
    "$TINYGO" build -target=esp32-coreboard-v2 -o "$B/s_g.o" "$B/probe.go" >/dev/null 2>"$B/tg.err"
}

printf "%-22s %-6s %-14s | %-12s %-12s %-12s %-12s %-12s %s\n" \
    "struct" "align" "clang IR arg" "clang" "gcc" "rust" "zig" "D" "TinyGo"
printf -- '-%.0s' {1..114}; echo
# spec = "label|c-field|zig-field|d-field|rust-field|go-field|align"
for spec in \
    "[8]u8|unsigned char d[8]|[8]u8|ubyte[8] d|d:[u8;8]|D [8]byte|1" \
    "[16]u8|unsigned char d[16]|[16]u8|ubyte[16] d|d:[u8;16]|D [16]byte|1" \
    "[24]u8|unsigned char d[24]|[24]u8|ubyte[24] d|d:[u8;24]|D [24]byte|1" \
    "{2xu32}|unsigned d[2]|[2]u32|uint[2] d|d:[u32;2]|D [2]uint32|4" \
    "{6xu32}|unsigned d[6]|[6]u32|uint[6] d|d:[u32;6]|D [6]uint32|4" ; do
    lbl="${spec%%|*}"; r="${spec#*|}"
    cty="${r%%|*}"; r="${r#*|}"
    zty="${r%%|*}"; r="${r#*|}"
    dty="${r%%|*}"; r="${r#*|}"
    rty="${r%%|*}"; r="${r#*|}"
    gty="${r%%|*}"; r="${r#*|}"
    al="${r%%|*}"
    # Sources
    printf '#include <stdint.h>\ntypedef struct{%s;}T;\nextern uint32_t ext(T);\nuint32_t caller(T x){return ext(x);}\n' "$cty" > "$B/s.c"
    printf 'const T=extern struct{x:%s};\nextern fn ext(T) callconv(.c) u32;\nexport fn caller(v:T) u32 { return ext(v); }\n' "$zty" > "$B/s.zig"
    printf 'extern(C) struct T { %s; }\nextern(C) uint ext(T);\nextern(C) uint caller(T x) { return ext(x); }\n' "$dty" > "$B/s.d"
    # Compile each
    "$CLANG" $CT -ffreestanding -O2 -c "$B/s.c" -o "$B/s_c.o" 2>/dev/null
    eval "$G" "$GCC" -ffreestanding -O2 -c "$B/s.c" -o "$B/s_gcc.o" 2>/dev/null
    "$ZIG" build-obj -target xtensa-freestanding-none -mcpu="$CPU" -O ReleaseFast -femit-bin="$B/s_z.o" "$B/s.zig" 2>/dev/null
    "$LDC2" -mtriple=xtensa-esp-elf -mcpu="$CPU" -betterC -O2 -c -of="$B/s_d.o" "$B/s.d" 2>/dev/null
    rm -f "$B/s_r.o"; build_rust "$rty" || true
    rm -f "$B/s_g.o"; build_tinygo "$gty" || true
    ir=$("$CLANG" $CT -ffreestanding -O0 -S -emit-llvm "$B/s.c" -o - 2>/dev/null \
         | grep -oE '@caller\([^)]*\)' \
         | grep -oE '\[[0-9]+ x i[0-9]+\]|ptr[^,)]*' | head -1 || true)
    c=$(classify "$B/s_c.o");  gcc=$(classify "$B/s_gcc.o")
    rs=$(classify "$B/s_r.o"); z=$(classify "$B/s_z.o")
    d=$(classify "$B/s_d.o");  g=$(classify "$B/s_g.o")
    printf "%-22s %-6s %-14s | %-12s %-12s %-12s %-12s %-12s %s\n" \
        "$lbl" "$al" "$ir" "$c" "$gcc" "$rs" "$z" "$d" "$g"
done

echo
echo "C-bitfield rows (only the languages with native bitfield syntax — clang,"
echo "gcc, zig packed struct(uN) with explicit backing, D extern(C) — show data."
echo "Rust has no native bitfields, TinyGo/Go neither, so both are N/A.)"
echo
printf "%-22s %-6s %-14s | %-12s %-12s %-12s %-12s %-12s %s\n" \
    "struct" "align" "clang IR arg" "clang" "gcc" "rust" "zig" "D" "TinyGo"
printf -- '-%.0s' {1..114}; echo
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
    eval "$G" "$GCC" -ffreestanding -O2 -c "$B/s.c" -o "$B/s_gcc.o" 2>/dev/null
    "$ZIG" build-obj -target xtensa-freestanding-none -mcpu="$CPU" -O ReleaseFast -femit-bin="$B/s_z.o" "$B/s.zig" 2>/dev/null
    "$LDC2" -mtriple=xtensa-esp-elf -mcpu="$CPU" -betterC -O2 -c -of="$B/s_d.o" "$B/s.d" 2>/dev/null
    ir=$("$CLANG" $CT -ffreestanding -O0 -S -emit-llvm "$B/s.c" -o - 2>/dev/null \
         | grep -oE '@caller\([^)]*\)' \
         | grep -oE 'i[0-9]+ [a-z]*|\[[0-9]+ x i[0-9]+\]|ptr[^,)]*' | head -1 || true)
    c=$(classify "$B/s_c.o");   gcc=$(classify "$B/s_gcc.o")
    z=$(classify "$B/s_z.o");   d=$(classify "$B/s_d.o")
    printf "%-22s %-6s %-14s | %-12s %-12s %-12s %-12s %-12s %s\n" \
        "$full_lbl" "$al" "$ir" "$c" "$gcc" "n/a (no syntax)" "$z" "$d" "n/a (no syntax)"
done

echo
echo "Summary:"
echo "  byte-array rows: zig stack-spills the align-1 by-value (the classic"
echo "    docs/05 hole); D's IR is byval but the espressif Xtensa backend"
echo "    lowers it without movsp, so the heuristic puts it in REGISTERS."
echo "    rust + gcc + TinyGo all agree with clang (REGISTERS)."
echo "  word-array rows: every toolchain agrees (REGISTERS), trivial."
echo "  bitfield rows: clang/gcc flatten to scalar backing; zig with explicit"
echo "    packed-struct backing matches; D emits byval(struct) IR for every"
echo "    bitfield case (universal-aggregate bug, docs/19/23). Rust + TinyGo:"
echo "    no native bitfield syntax."
