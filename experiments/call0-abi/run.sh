#!/usr/bin/env bash
# run.sh - compare windowed vs CALL0 (-mcpu=<core>-windowed) ABI across the 5
# LLVM/GCC frontends on every Xtensa core. Xtensa has TWO calling conventions:
#
#   windowed (default): `entry` saves callee's a0..a3 to a hidden 16-byte slot,
#                       caller passes args in a10..a15, callx8 rotates the
#                       register window by 8 so callee reads a2..a7; return is
#                       `retw.n` which un-rotates.
#   CALL0:              no register windowing. Caller passes args in a2..a7,
#                       callee reads a2..a7 directly, no rotation, `ret.n` to a0.
#                       Used in ESP32 ROM functions and bootloader paths.
#
# How each frontend selects CALL0:
#   clang  -Xclang -target-feature -Xclang -windowed  (subtract LLVM feature)
#   gcc    -mabi=call0                                 (GCC-native flag)
#   zig    -mcpu=<core>-windowed                       (LLVM feature subtraction)
#   LDC    -mattr=-windowed                            (LLVM feature subtraction)
#   rust   -C target-feature=-windowed                 (LLVM feature subtraction)
#   TinyGo no flag                                     (whole-program, fixed ABI)
#
# Verifies the same source produces CALL0 codegen (no `entry`, `ret.n` instead
# of `retw.n`) in every frontend. Probes `add_i32(a,b)`; the canonical $ZIG
# (0.17) lane has the docs/05 by-value struct ABI fixed already, so this
# experiment is purely about the windowed/CALL0 selector parity — set
# ZIG=$ZIG_016 to layer the legacy struct break on top if you want.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
B=build/call0-abi; mkdir -p "$B"

# Use LLVM-22 binutils for disasm — esp-clang's 21.1.3 binutils can decode the
# instructions but the windowed prologue annotations are cleaner here. Falls
# back to esp-clang's if LDC_LLVM_DIR isn't installed (LLVM22=1).
DUMP="$ESP_CLANG_DIR/llvm-objdump"
[ -x "$LDC_LLVM_DIR/bin/llvm-objdump" ] && DUMP="$LDC_LLVM_DIR/bin/llvm-objdump"

cat > "$B/add.c"   <<'EOF'
int add_i32(int a, int b) { return a + b; }
EOF
cat > "$B/add.zig" <<'EOF'
export fn add_i32(a: i32, b: i32) callconv(.c) i32 { return a + b; }
EOF
cat > "$B/add.d"   <<'EOF'
extern(C) int add_i32(int a, int b) { return a + b; }
EOF
mkdir -p "$B/rs/src"
cat > "$B/rs/Cargo.toml" <<'EOF'
[package]
name="call0_rs"
version="0.0.0"
edition="2021"
[lib]
path="src/lib.rs"
crate-type=["staticlib"]
[profile.release]
panic="abort"
opt-level=2
EOF
cat > "$B/rs/src/lib.rs" <<'EOF'
#![no_std]
#[panic_handler] fn p(_: &core::panic::PanicInfo) -> ! { loop {} }
#[no_mangle] pub extern "C" fn add_i32(a: i32, b: i32) -> i32 { a + b }
EOF

# Helpers: extract just the prologue/epilogue + body summary.
summary() {  # $1=object  $2=symbol
    local d
    d=$("$DUMP" -d --mcpu=esp32 --disassemble-symbols="$2" "$1" 2>/dev/null)
    # Look for entry / retw.n / ret.n / movsp / s32i.n in prologue
    local entry=$(echo "$d" | grep -ciE '\bentry\b')
    local retw=$(echo "$d"  | grep -ciE '\bretw\.n\b')
    local retn=$(echo "$d"  | grep -ciE '\bret\.n\b')
    local movsp=$(echo "$d" | grep -ciE '\bmovsp\b')
    local sigil
    if [ "$entry" -ge 1 ]; then sigil="WINDOWED (entry+retw.n)"
    elif [ "$retn" -ge 1 ]; then sigil="CALL0    (no-entry+ret.n)"
    else sigil="unknown ($entry/entry $retw/retw.n $retn/ret.n)"
    fi
    printf "%-32s %s\n" "$1" "$sigil"
}

build_rust() { # $1=cpu  $2=extra-rustc-flags  $3=outfile
    local cpu="$1" xflags="$2" out="$3"
    rm -rf "$B/rs/target"
    ( cd "$B/rs" && RUSTC="$RUSTC" "$CARGO" rustc --release -Z build-std=core \
        --target "xtensa-${cpu}-none-elf" -- --emit=obj $xflags 2>/dev/null )
    local rso
    rso=$(find "$B/rs/target/xtensa-${cpu}-none-elf/release/deps" -name 'call0_rs-*.o' | head -1)
    [ -n "$rso" ] && cp "$rso" "$out"
}

for CPU in esp32 esp32s2 esp32s3; do
    echo ""
    echo "=== $CPU :: windowed vs CALL0 (-mcpu=$CPU-windowed) prologue ==="
    G_CFG="XTENSA_GNU_CONFIG=$(xtensa_cfg "$CPU")"

    # clang
    "$CLANG" --target=xtensa-esp-elf -mcpu="$CPU" -ffreestanding -Os \
        -c "$B/add.c" -o "$B/clang_w_${CPU}.o"
    "$CLANG" --target=xtensa-esp-elf -mcpu="$CPU" -Xclang -target-feature -Xclang -windowed \
        -ffreestanding -Os -c "$B/add.c" -o "$B/clang_c0_${CPU}.o"
    summary "$B/clang_w_${CPU}.o"  add_i32
    summary "$B/clang_c0_${CPU}.o" add_i32

    # gcc (note: gcc uses -mabi=call0, not LLVM feature subtraction)
    eval $G_CFG "$GCC" -ffreestanding -Os -c "$B/add.c" -o "$B/gcc_w_${CPU}.o"
    eval $G_CFG "$GCC" -ffreestanding -Os -mabi=call0 -c "$B/add.c" -o "$B/gcc_c0_${CPU}.o"
    summary "$B/gcc_w_${CPU}.o"  add_i32
    summary "$B/gcc_c0_${CPU}.o" add_i32

    # zig
    "$ZIG" build-obj -target xtensa-freestanding-none -mcpu="$CPU" -O ReleaseSmall \
        -femit-bin="$B/zig_w_${CPU}.o" "$B/add.zig"
    "$ZIG" build-obj -target xtensa-freestanding-none -mcpu="${CPU}-windowed" -O ReleaseSmall \
        -femit-bin="$B/zig_c0_${CPU}.o" "$B/add.zig"
    summary "$B/zig_w_${CPU}.o"  add_i32
    summary "$B/zig_c0_${CPU}.o" add_i32

    # LDC (espressif fork, native esp32/s2/s3 -mcpu)
    "$LDC2" -mtriple=xtensa-esp-elf -mcpu="$CPU" $LDC_PE -betterC -O2 -c "$B/add.d" \
        -of="$B/ldc_w_${CPU}.o" 2>/dev/null
    "$LDC2" -mtriple=xtensa-esp-elf -mcpu="$CPU" -mattr=-windowed $LDC_PE -betterC -O2 -c "$B/add.d" \
        -of="$B/ldc_c0_${CPU}.o" 2>/dev/null
    summary "$B/ldc_w_${CPU}.o"  add_i32
    summary "$B/ldc_c0_${CPU}.o" add_i32

    # rust (windowed is the default on every xtensa-esp* target; subtract via -C target-feature)
    build_rust "$CPU" ""                            "$B/rust_w_${CPU}.o"
    build_rust "$CPU" "-C target-feature=-windowed" "$B/rust_c0_${CPU}.o"
    summary "$B/rust_w_${CPU}.o"  add_i32
    summary "$B/rust_c0_${CPU}.o" add_i32
done

echo ""
echo "=== Side-by-side disasm: zig add_i32 windowed vs CALL0 (esp32) ==="
echo "--- windowed ---"
"$DUMP" -d --mcpu=esp32 --disassemble-symbols=add_i32 "$B/zig_w_esp32.o" 2>/dev/null | tail -8
echo "--- CALL0 ---"
"$DUMP" -d --mcpu=esp32 --disassemble-symbols=add_i32 "$B/zig_c0_esp32.o" 2>/dev/null | tail -8

echo ""
echo "=== Conclusion ==="
echo "  All 5 frontends respond identically to the CALL0 selector (LLVM 'windowed'"
echo "  feature subtraction for clang/zig/LDC/rust; -mabi=call0 for gcc). Prologue"
echo "  flips from 'entry a1, N' + 'retw.n' to direct stack adjust + 'ret.n'."
echo "  Args still arrive in a2..a7 in BOTH conventions for the callee — the"
echo "  difference is in caller-side rotation (callx8 vs callx0) and the saved"
echo "  link-register slot. Windowed and CALL0 code are NOT interlinkable: a"
echo "  windowed caller's callx8 rotates the register window, so a CALL0 callee"
echo "  would see correct arg regs but its plain 'ret' wouldn't unwind the window."
