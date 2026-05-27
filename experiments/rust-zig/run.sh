#!/usr/bin/env bash
# run.sh - Rust <-> Zig frontend interop on Xtensa (the two non-C LLVM frontends).
#   (a) ABI of scalars incl. C-inexpressible u128/f128/f16  -> IR signatures
#   (b) runtime: Rust calls Zig with u128 (carry across 4 words) on qemu
#   (c) cross-language LTO (rust 21.1.3 bc + zig 21.1.0 bc) -> version skew
# See docs/17.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
D=experiments/rust-zig; B=build/rz; QR=experiments/qemu-run; mkdir -p "$B"
CT="--target=xtensa-esp-elf -mcpu=esp32"; ZT="-target xtensa-freestanding-none -mcpu=esp32"
RTLIB="$ESP_CLANG_DIR/../lib/clang-runtimes/xtensa-esp-unknown-elf/esp32/lib/libclang_rt.builtins.a"

echo "== (a) scalar ABI: Rust vs Zig IR arg/ret signatures (esp32) =="
"$ZIG" build-obj $ZT -O ReleaseSmall -fno-emit-bin -femit-llvm-ir="$B/iface.ll" "$D/iface.zig"
( cd "$D/rs" && RUSTC="$RUSTC" "$CARGO" rustc --release -Z build-std=core --target xtensa-esp32-none-elf -- --emit=llvm-ir >/dev/null 2>&1 )
RLL=$(grep -rls 'define.*@rs_add_u128' "$D/rs/target" --include='*.ll' | head -1)
sig(){ grep -hE "define .*@$1\b" "$2" 2>/dev/null | head -1 | grep -oE '\([^{]*' \
  | sed -E 's/ ?(noundef|noalias|readonly|captures\([^)]*\)|dereferenceable\([^)]*\)|align [0-9]+|writable|writeonly|zeroext|range\([^)]*\)|dead_on_unwind|initializes\([^)]*\))//g; s/  */ /g'; }
for fn in add_u128 add_f128 add_f16 not enum; do
  printf "  %-9s rust: %-32s zig: %s\n" "$fn" "$(sig "rs_$fn" "$RLL")" "$(sig "iface.zig_$fn" "$B/iface.ll")"
done
echo "  (u128/f128: rust uses byval ptr for arg2, zig direct i128 -- backend reconciles to same machine ABI)"

echo "== (b) runtime: Rust computes 2x u128, calls Zig, checks carry (qemu xtensa) =="
"$ZIG" build-obj $ZT -O ReleaseSmall -femit-bin="$B/rt.o" "$D/rt.zig"
( cd "$D/rt" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target xtensa-esp32-none-elf >/dev/null 2>&1 )
cp "$(find "$D/rt/target" -name librzrt.a | head -1)" "$B/"
"$CLANG" $CT -ffreestanding -Os -I"$QR" -c "$D/main.c" -o "$B/main.o"
"$CLANG" $CT -ffreestanding -Os -c "$QR/start.S" -o "$B/start.o"
ld.lld -T "$QR/sim.ld" -o "$B/rz.elf" "$B/start.o" "$B/main.o" "$B/rt.o" --start-group "$B/librzrt.a" "$RTLIB" --end-group
timeout 12 "$TC/qemu/qemu/bin/qemu-system-xtensa" -machine sim -cpu dc233c -semihosting -nographic -monitor none -kernel "$B/rz.elf" || true

echo "== (c) cross-language LTO: rust bc (21.1.3) + zig bc (21.1.0) =="
( cd "$D/rt" && RUSTC="$RUSTC" "$CARGO" rustc --release -Z build-std=core --target xtensa-esp32-none-elf -- --emit=llvm-bc >/dev/null 2>&1 )
cp "$(find "$D/rt/target" -name 'rzrt*.bc' | head -1)" "$B/rzrt.bc"
"$ZIG" build-obj $ZT -O ReleaseSmall -fno-emit-bin -femit-llvm-bc="$B/rt.bc" "$D/rt.zig"
if ld.lld --lto-O2 -e rs_check_u128 -u zig_add_u128 "$B/rzrt.bc" "$B/rt.bc" -o "$B/lto.elf" 2>"$B/lto.err"; then
  echo "  LTO linked (versions matched)"; else echo "  LTO FAILS: $(grep -oiE 'Invalid record' "$B/lto.err" | head -1) (zig 21.1.0 vs rust/lld 21.1.3)"; fi
