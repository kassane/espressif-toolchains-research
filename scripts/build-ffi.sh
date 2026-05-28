#!/usr/bin/env bash
# build-ffi.sh - build the cross-language FFI matrix.
#   ./build-ffi.sh host           -> build for x86_64 and RUN it
#   ./build-ffi.sh esp32|esp32s2|esp32s3  -> cross-build + link Xtensa ELFs
#   ./build-ffi.sh all            -> host + all three Xtensa cores
#
# Each backend language implements the same C-ABI contract; this script links
# objects from four compilers (and two linkers) to prove interop.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

SRC=experiments/ffi-matrix
INC="$PWD/$SRC/include"

# LDC -> Xtensa object. LDC's LLVM-22 integrated assembler mis-lays the Xtensa
# literal pool under function-sections: a function's l32r literal (e.g. the
# __muldf3 address in d_mul_f64) is emitted into the PRECEDING function's
# section at an unaligned offset, so ld.lld rejects it
# ("R_XTENSA_SLOT0_OP ... not aligned to 4 bytes"). Work around it by emitting
# textual asm and re-assembling with esp clang (LLVM 21), whose Xtensa MC uses
# separate, 4-aligned .literal sections. Also strip .cfi_* — the Xtensa
# assembler rejects CFI directives ("CFI is not supported for this target"),
# which LDC emits anyway. See docs/19.
ldc_xtensa_obj() { # mcpu out src
    local cpu=$1 out=$2 src=$3 s="${2%.o}.s" feat
    # LDC's upstream LLVM-22 only knows the `esp32` Xtensa CPU; esp32s2/s3 are
    # "not a recognized processor" and fall back to generic (no mul32 -> an
    # __mulsi3 libcall that the RT lib lacks). So specify features by hand for
    # those (ldc #4919). Float stays soft, which is interop-safe: f32/f64 cross
    # the C ABI in a-registers regardless of whether the body uses the FPU.
    case "$cpu" in
        esp32) feat="-mcpu=esp32" ;;
        *)     feat="-mattr=+windowed,+density,+mul32,+mul16,+div32" ;;
    esac
    "$LDC2" -mtriple=xtensa-esp-elf $feat -betterC -Os -output-s -of="$s" "$src"
    sed -E -i '/^[[:space:]]*\.cfi_/d' "$s"
    "$CLANG" --target=xtensa-esp-elf -mcpu="$cpu" -c "$s" -o "$out"
}

build_host() {
    local B=build/host; mkdir -p "$B"
    echo "== host (x86_64) =="
    "$ZIG" cc  -O2 -I"$INC" -DFFI_HOSTED -c "$SRC/driver.c"      -o "$B/driver.o"
    "$ZIG" cc  -O2 -I"$INC"               -c "$SRC/c/lib_c.c"    -o "$B/lib_c.o"
    "$ZIG" c++ -O2 -I"$INC"               -c "$SRC/cpp/lib_cpp.cpp" -o "$B/lib_cpp.o"
    "$ZIG" build-obj -target x86_64-linux-gnu -O ReleaseSmall -femit-bin="$B/lib_zig.o" "$SRC/zig/lib_zig.zig"
    "$LDC2" -betterC -O2 -c -of="$B/lib_d.o" "$SRC/d/lib_d.d"
    ( cd "$SRC/rust" && RUSTC="$RUSTC" "$CARGO" build --release >/dev/null 2>&1 )
    cp "$SRC/rust/target/release/libffi_rs.a" "$B/"
    "$ZIG" cc "$B"/driver.o "$B"/lib_c.o "$B"/lib_cpp.o "$B"/lib_zig.o "$B"/lib_d.o "$B"/libffi_rs.a -o "$B/ffi_host"
    echo "-- running --"; "./$B/ffi_host"
}

build_xtensa() {
    local CPU=$1; local B="build/xtensa-$CPU"; mkdir -p "$B"
    local CT="--target=xtensa-esp-elf -mcpu=$CPU"
    local RT="$ESP_CLANG_DIR/../lib/clang-runtimes/xtensa-esp-unknown-elf/$CPU/lib/libclang_rt.builtins.a"
    echo "== xtensa $CPU =="
    # LLVM family
    "$CLANG"   $CT -ffreestanding -Os -I"$INC" -c "$SRC/driver.c"       -o "$B/driver.o"
    "$CLANG"   $CT -ffreestanding -Os          -c "$SRC/entry_xtensa.c" -o "$B/entry.o"
    "$CLANG"   $CT -ffreestanding -Os -I"$INC" -c "$SRC/c/lib_c.c"      -o "$B/lib_c_clang.o"
    "$CLANGXX" $CT -ffreestanding -fno-exceptions -fno-rtti -fno-threadsafe-statics -Os -I"$INC" \
                                               -c "$SRC/cpp/lib_cpp.cpp" -o "$B/lib_cpp.o"
    "$ZIG" build-obj -target xtensa-freestanding-none -mcpu="$CPU" -O ReleaseSmall \
                                               -femit-bin="$B/lib_zig.o" "$SRC/zig/lib_zig.zig"
    # D via LDC (-betterC; Xtensa is an experimental LLVM-22 target in this build).
    # See ldc_xtensa_obj for the literal-pool re-assembly workaround.
    ldc_xtensa_obj "$CPU" "$B/lib_d.o" "$SRC/d/lib_d.d"
    # GCC variant of the C lib (note: XTENSA_GNU_CONFIG selects the little-endian esp core)
    XTENSA_GNU_CONFIG="$(xtensa_cfg "$CPU")" "$GCC" -ffreestanding -Os -I"$INC" \
                                               -c "$SRC/c/lib_c.c"      -o "$B/lib_c_gcc.o"
    # Rust via build-std=core
    ( cd "$SRC/rust" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core \
        --target "xtensa-$CPU-none-elf" >/dev/null 2>&1 )
    cp "$SRC/rust/target/xtensa-$CPU-none-elf/release/libffi_rs.a" "$B/"

    local COMMON="$B/driver.o $B/entry.o $B/lib_cpp.o $B/lib_zig.o $B/lib_d.o"
    # (a) pure-LLVM linked by lld
    ld.lld -T "$SRC/xtensa.ld" -o "$B/ffi_llvm.elf"  $COMMON "$B/lib_c_clang.o" \
        --start-group "$B/libffi_rs.a" "$RT" --end-group
    # (b) GCC C + LLVM rest, linked by lld
    ld.lld -T "$SRC/xtensa.ld" -o "$B/ffi_mixed.elf" $COMMON "$B/lib_c_gcc.o" \
        --start-group "$B/libffi_rs.a" "$RT" --end-group
    # (c) pure-LLVM linked by GNU ld
    XTENSA_GNU_CONFIG="$(xtensa_cfg "$CPU")" xtensa-esp-elf-ld -T "$SRC/xtensa.ld" -o "$B/ffi_gnuld.elf" \
        $COMMON "$B/lib_c_clang.o" --start-group "$B/libffi_rs.a" "$RT" --end-group 2>/dev/null
    echo "  linked: $(ls "$B"/*.elf | wc -l) ELFs; undefined symbols:"
    for e in "$B"/*.elf; do printf "    %-16s %s undef\n" "$(basename "$e")" "$(llvm-nm "$e" 2>/dev/null | grep -c ' U ')"; done
}

# RISC-V control: the same espressif LLVM also hosts riscv32 (esp clang's default
# triple). ESP32-C3 = rv32imc. Used to show the Zig struct-ABI gap is Xtensa-only.
build_riscv() {
    local B="build/riscv-esp32c3"; mkdir -p "$B"
    local CT="--target=riscv32-esp-elf -mcpu=esp32c3"
    local RT="$ESP_CLANG_DIR/../lib/clang-runtimes/riscv32-esp-unknown-elf/rv32imc-zicsr-zifencei_ilp32_no-rtti/lib/libclang_rt.builtins.a"
    echo "== riscv esp32c3 (rv32imc) =="
    "$CLANG"   $CT -ffreestanding -Os -I"$INC" -c "$SRC/driver.c"       -o "$B/driver.o"
    "$CLANG"   $CT -ffreestanding -Os          -c "$SRC/entry_xtensa.c" -o "$B/entry.o"
    "$CLANG"   $CT -ffreestanding -Os -I"$INC" -c "$SRC/c/lib_c.c"      -o "$B/lib_c.o"
    "$CLANGXX" $CT -ffreestanding -fno-exceptions -fno-rtti -Os -I"$INC" -c "$SRC/cpp/lib_cpp.cpp" -o "$B/lib_cpp.o"
    "$ZIG" build-obj -target riscv32-freestanding-none -mcpu=esp32c3 -O ReleaseSmall -femit-bin="$B/lib_zig.o" "$SRC/zig/lib_zig.zig"
    # D via LDC. esp32c3 = rv32imc; upstream LLVM-22 has no esp32c3 CPU, so use
    # the generic rv32 + explicit +m,+c features. No literal-pool quirk here
    # (RISC-V calls use auipc/jalr, not Xtensa's l32r), so a direct object works.
    "$LDC2" -mtriple=riscv32-unknown-none-elf -mattr=+m,+c -betterC -Os -c -of="$B/lib_d.o" "$SRC/d/lib_d.d"
    ( cd "$SRC/rust" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target riscv32imc-unknown-none-elf >/dev/null 2>&1 )
    cp "$SRC/rust/target/riscv32imc-unknown-none-elf/release/libffi_rs.a" "$B/"
    ld.lld -e _start --section-start=.text=0x40380000 -o "$B/ffi_rv.elf" \
        "$B/driver.o" "$B/entry.o" "$B/lib_c.o" "$B/lib_cpp.o" "$B/lib_zig.o" "$B/lib_d.o" \
        --start-group "$B/libffi_rs.a" "$RT" --end-group
    echo "  linked ffi_rv.elf; undefined: $(llvm-nm "$B/ffi_rv.elf" 2>/dev/null | grep -c ' U ')"
}

case "${1:-all}" in
    host) build_host ;;
    esp32|esp32s2|esp32s3) build_xtensa "$1" ;;
    esp32c3|riscv) build_riscv ;;
    all) build_host; for c in esp32 esp32s2 esp32s3; do build_xtensa "$c"; done; build_riscv ;;
    *) echo "usage: $0 {host|esp32|esp32s2|esp32s3|esp32c3|all}"; exit 1 ;;
esac
