#!/usr/bin/env bash
# run.sh [riscv|xtensa] - build the Rust+Zig bare-metal mixin into one ELF and
# run it on the espressif qemu fork. Rust app (app.rs) drives a Zig kernel
# (dsp.zig); glue in main.c reports via semihosting. Reuses the qemu-run harness.
#   riscv  (default): esp32c3 / qemu-system-riscv32 virt
#   xtensa:           esp32   / qemu-system-xtensa  sim
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
ARCH="${1:-riscv}"
HERE=experiments/baremetal-mixin
QR=experiments/qemu-run
B="build/mixin-$ARCH"; mkdir -p "$B"

if [ "$ARCH" = riscv ]; then
    CT="--target=riscv32-esp-elf -mcpu=esp32c3"; ZT="-target riscv32-freestanding-none -mcpu=esp32c3"
    RTARGET=riscv32imc-unknown-none-elf
    RT="$ESP_CLANG_DIR/../lib/clang-runtimes/riscv32-esp-unknown-elf/rv32imc-zicsr-zifencei_ilp32_no-rtti/lib/libclang_rt.builtins.a"
    SEMI="$QR/riscv"; START="$QR/riscv/start.S"; LD="$QR/riscv/virt.ld"
    QEMU="$TC/qemu/qemu/bin/qemu-system-riscv32"; QARGS=(-machine virt -bios "$B/mixin.elf")
else
    CT="--target=xtensa-esp-elf -mcpu=esp32"; ZT="-target xtensa-freestanding-none -mcpu=esp32"
    RTARGET=xtensa-esp32-none-elf
    RT="$ESP_CLANG_DIR/../lib/clang-runtimes/xtensa-esp-unknown-elf/esp32/lib/libclang_rt.builtins.a"
    SEMI="$QR"; START="$QR/start.S"; LD="$QR/sim.ld"
    QEMU="$TC/qemu/qemu/bin/qemu-system-xtensa"; QARGS=(-machine sim -cpu dc233c -kernel "$B/mixin.elf")
fi

echo "[zig]   dsp kernel"; "$ZIG" build-obj $ZT -O ReleaseSmall -femit-bin="$B/dsp.o" "$HERE/dsp.zig"
echo "[clang] glue";       "$CLANG" $CT -ffreestanding -Os -I"$SEMI" -c "$HERE/main.c" -o "$B/main.o"
echo "[clang] reset shim"; "$CLANG" $CT -ffreestanding -Os -c "$START" -o "$B/start.o"
echo "[rust]  app";        ( cd "$HERE" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target "$RTARGET" >/dev/null 2>&1 )
cp "$HERE/target/$RTARGET/release/libapp.a" "$B/"
echo "[link]";             ld.lld -T "$LD" -o "$B/mixin.elf" "$B/start.o" "$B/main.o" "$B/dsp.o" \
    --start-group "$B/libapp.a" "$RT" --end-group
echo "[run] $ARCH"; timeout 12 "$QEMU" "${QARGS[@]}" -nographic -semihosting -monitor none || true
