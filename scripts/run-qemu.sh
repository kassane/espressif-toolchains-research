#!/usr/bin/env bash
# run-qemu.sh [xtensa|riscv] - execute the FFI matrix on emulated ESP cores via
# the espressif qemu fork, reporting per-language results over semihosting.
#   xtensa (default): -machine sim -cpu dc233c   (needs build-ffi.sh esp32)
#   riscv:            -machine virt               (needs build-ffi.sh esp32c3)
# Expected: scalars + struct returns pass for all 4 languages; Zig fails a
# by-value struct ARG differently per arch (xtensa blob_sum, riscv point_dot).
# See docs/08 (xtensa), docs/09 (riscv). qemu fork lives at $TC/qemu (xtensa &
# riscv softmmu tarballs from espressif/qemu esp-develop-9.2.2-20260417).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
ARCH="${1:-xtensa}"
D=experiments/qemu-run; INC="$PWD/experiments/ffi-matrix/include"

if [ "$ARCH" = riscv ]; then
    B=build/qemu-rv; LIB=build/riscv-esp32c3; mkdir -p "$B"
    CT="--target=riscv32-esp-elf -mcpu=esp32c3"
    RT="$ESP_CLANG_DIR/../lib/clang-runtimes/riscv32-esp-unknown-elf/rv32imc-zicsr-zifencei_ilp32_no-rtti/lib/libclang_rt.builtins.a"
    QEMU="$TC/qemu/qemu/bin/qemu-system-riscv32"
    # Compile qemu_main next to the riscv semihost.h so the quote-include resolves to it.
    cp "$D/qemu_main.c" "$B/qm.c"; cp "$D/riscv/semihost.h" "$B/semihost.h"
    "$CLANG" $CT -ffreestanding -Os -I"$B" -I"$INC" -c "$B/qm.c" -o "$B/qm.o"
    "$CLANG" $CT -ffreestanding -Os -c "$D/riscv/start.S" -o "$B/start.o"
    ld.lld -T "$D/riscv/virt.ld" -o "$B/ffi_rv_run.elf" "$B/start.o" "$B/qm.o" \
        "$LIB/lib_c.o" "$LIB/lib_cpp.o" "$LIB/lib_zig.o" \
        --start-group "$LIB/libffi_rs.a" "$RT" --end-group
    echo "===== FFI matrix on qemu-system-riscv32 (virt) ====="
    timeout 12 "$QEMU" -machine virt -bios "$B/ffi_rv_run.elf" -nographic -semihosting -monitor none || true
    exit 0
fi

# --- xtensa ---
B=build/qemu; LIB=build/xtensa-esp32; mkdir -p "$B"
CT="--target=xtensa-esp-elf -mcpu=esp32"
RT="$ESP_CLANG_DIR/../lib/clang-runtimes/xtensa-esp-unknown-elf/esp32/lib/libclang_rt.builtins.a"
QEMU="$TC/qemu/qemu/bin/qemu-system-xtensa"
"$CLANG" $CT -ffreestanding -Os -c "$D/start.S" -o "$B/start.o"
"$CLANG" $CT -ffreestanding -Os -I"$D" -I"$INC" -c "$D/qemu_main.c" -o "$B/qemu_main.o"
printf '#include "semihost.h"\nint xmain(void){ puts_("\\nHELLO from qemu-system-xtensa\\n"); sys_exit(0); return 0; }\n' > "$B/hello.c"
"$CLANG" $CT -ffreestanding -Os -I"$D" -c "$B/hello.c" -o "$B/hello.o"
ld.lld -T "$D/sim.ld" -o "$B/hello.elf" "$B/start.o" "$B/hello.o"
echo "===== hello (semihosting smoke test) ====="
timeout 8 "$QEMU" -machine sim -semihosting -nographic -monitor none -kernel "$B/hello.elf" || true
ld.lld -T "$D/sim.ld" -o "$B/ffi_run.elf" "$B/start.o" "$B/qemu_main.o" \
    "$LIB/lib_c_clang.o" "$LIB/lib_cpp.o" "$LIB/lib_zig.o" \
    --start-group "$LIB/libffi_rs.a" "$RT" --end-group
echo "===== FFI matrix on qemu-system-xtensa (sim/dc233c) ====="
timeout 12 "$QEMU" -machine sim -cpu dc233c -semihosting -nographic -monitor none -kernel "$B/ffi_run.elf" || true
