#!/usr/bin/env bash
# run.sh - re-test esp-rs/rust issue reproducers on the current toolchain and
# port the equivalent code to all frontends (clang/gcc/zig). See docs/13.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
D=experiments/esp-rs-issues; B=build/esp-rs-issues; mkdir -p "$B"
CTX="--target=xtensa-esp-elf -mcpu=esp32"

echo "== Rust crate (xtensa-esp32-none-elf, opt-level=z): #95 + #137 + #277(min) =="
( cd "$D" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target xtensa-esp32-none-elf 2>&1 | tail -1 )
echo "   -> compiles: #95 enum/match FIXED, #137 u128 OK, #277 float-pool min does NOT ICE"

echo "== Port #95/#277 to C (clang + gcc, xtensa) =="
"$CLANG" $CTX -ffreestanding -Os -c "$D/ports.c" -o "$B/pc.o"   && echo "   clang OK"
XTENSA_GNU_CONFIG="$(xtensa_cfg esp32)" "$GCC" -ffreestanding -Os -c "$D/ports.c" -o "$B/pg.o" && echo "   gcc   OK"
echo "   (#137 u128 OMITTED for C: __int128 is unsupported by clang & gcc on xtensa)"

echo "== Port #95/#137/#277 to Zig (xtensa) =="
"$ZIG" build-obj -target xtensa-freestanding-none -mcpu=esp32 -O ReleaseSmall -femit-bin="$B/pz.o" "$D/ports.zig" && echo "   zig   OK (u128 supported, like Rust)"
