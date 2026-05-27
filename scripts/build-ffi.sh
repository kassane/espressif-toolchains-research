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

build_host() {
    local B=build/host; mkdir -p "$B"
    echo "== host (x86_64) =="
    "$ZIG" cc  -O2 -I"$INC" -DFFI_HOSTED -c "$SRC/driver.c"      -o "$B/driver.o"
    "$ZIG" cc  -O2 -I"$INC"               -c "$SRC/c/lib_c.c"    -o "$B/lib_c.o"
    "$ZIG" c++ -O2 -I"$INC"               -c "$SRC/cpp/lib_cpp.cpp" -o "$B/lib_cpp.o"
    "$ZIG" build-obj -target x86_64-linux-gnu -O ReleaseSmall -femit-bin="$B/lib_zig.o" "$SRC/zig/lib_zig.zig"
    ( cd "$SRC/rust" && RUSTC="$RUSTC" "$CARGO" build --release >/dev/null 2>&1 )
    cp "$SRC/rust/target/release/libffi_rs.a" "$B/"
    "$ZIG" cc "$B"/driver.o "$B"/lib_c.o "$B"/lib_cpp.o "$B"/lib_zig.o "$B"/libffi_rs.a -o "$B/ffi_host"
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
    # GCC variant of the C lib (note: XTENSA_GNU_CONFIG selects the little-endian esp core)
    XTENSA_GNU_CONFIG="$(xtensa_cfg "$CPU")" "$GCC" -ffreestanding -Os -I"$INC" \
                                               -c "$SRC/c/lib_c.c"      -o "$B/lib_c_gcc.o"
    # Rust via build-std=core
    ( cd "$SRC/rust" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core \
        --target "xtensa-$CPU-none-elf" >/dev/null 2>&1 )
    cp "$SRC/rust/target/xtensa-$CPU-none-elf/release/libffi_rs.a" "$B/"

    local COMMON="$B/driver.o $B/entry.o $B/lib_cpp.o $B/lib_zig.o"
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

case "${1:-all}" in
    host) build_host ;;
    esp32|esp32s2|esp32s3) build_xtensa "$1" ;;
    all) build_host; for c in esp32 esp32s2 esp32s3; do build_xtensa "$c"; done ;;
    *) echo "usage: $0 {host|esp32|esp32s2|esp32s3|all}"; exit 1 ;;
esac
