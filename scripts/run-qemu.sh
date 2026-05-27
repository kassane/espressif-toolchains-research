#!/usr/bin/env bash
# run-qemu.sh - execute Xtensa code on the espressif qemu fork (sim machine,
# semihosting). Builds a tiny reset/vector harness (experiments/qemu-run) and:
#   - runs `hello` (semihosting smoke test) -- WORKS, proves the toolchain output
#     executes on an emulated Xtensa core;
#   - attempts the FFI runtime test (links the esp32 matrix libs). See
#     docs/08-qemu-execution.md for the current status / limitation.
#
# Requires: scripts/setup.sh + build-ffi.sh esp32 first, and the qemu fork at
# $TC/qemu (scripts/setup.sh does not fetch qemu; see docs/08 for the URL).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
D=experiments/qemu-run; B=build/qemu; LIB=build/xtensa-esp32; mkdir -p "$B"
CT="--target=xtensa-esp-elf -mcpu=esp32"
QSYS="$TC/qemu/qemu/bin/qemu-system-xtensa"
RT="$ESP_CLANG_DIR/../lib/clang-runtimes/xtensa-esp-unknown-elf/esp32/lib/libclang_rt.builtins.a"

"$CLANG" $CT -ffreestanding -Os -c "$D/start.S" -o "$B/start.o"
"$CLANG" $CT -ffreestanding -Os -I"$D" -I"$PWD/experiments/ffi-matrix/include" -c "$D/qemu_main.c" -o "$B/qemu_main.o"
printf '#include "semihost.h"\nint xmain(void){ puts_("\\nHELLO from qemu-system-xtensa\\n"); sys_exit(0); return 0; }\n' > "$B/hello.c"
"$CLANG" $CT -ffreestanding -Os -I"$D" -c "$B/hello.c" -o "$B/hello.o"
ld.lld -T "$D/sim.ld" -o "$B/hello.elf" "$B/start.o" "$B/hello.o"

echo "===== hello (semihosting smoke test) ====="
timeout 8 "$QSYS" -machine sim -semihosting -nographic -monitor none -kernel "$B/hello.elf" || true

ld.lld -T "$D/sim.ld" -o "$B/ffi_run.elf" "$B/start.o" "$B/qemu_main.o" \
    "$LIB/lib_c_clang.o" "$LIB/lib_cpp.o" "$LIB/lib_zig.o" \
    --start-group "$LIB/libffi_rs.a" "$RT" --end-group
echo "===== ffi_run (FFI matrix; needs full exception bring-up, see docs/08) ====="
timeout 8 "$QSYS" -machine sim -cpu dc233c -semihosting -nographic -monitor none -kernel "$B/ffi_run.elf" || true
