#!/usr/bin/env bash
# run.sh - DWARF / debug-info parity audit across all 6 toolchains on Xtensa.
# A reverse-engineering lens on the FFI matrix: same C-ABI function, same
# target, what does each toolchain ship in .debug_*?
#   (a) DWARF section bytes per toolchain (sizes of .debug_{info,line,abbrev,…})
#   (b) DWARF *version* each one emits by default
#   (c) Subprogram DIE for `add_i32` — args, types, source loc
#   (d) Mangling: symbol-table name vs DWARF "DW_AT_name"
#   (e) Reverse-engineer codegen for the SAME function across toolchains
#   (f) Frame info (.eh_frame vs .debug_frame)
#   (g) TinyGo addendum: it's a whole-program compiler so we work from the
#       intermediate linked ELF (preserved with `-work`); the same function
#       is exposed via `//go:noinline` + a side-effecting reference so LTO
#       doesn't DCE it. Reported separately because the byte counts in §a/f
#       are NOT apples-to-apples (TinyGo's ELF includes the full Go runtime).
# Reproduces and extends docs/04/06/15; see docs/22.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
B=build/dwarf-parity; mkdir -p "$B"
CT="--target=xtensa-esp-elf -mcpu=esp32"
DWD="$ESP_CLANG_DIR/llvm-dwarfdump"

echo "== build add_i32 with debug info from all 5 toolchains, esp32 =="
# 1. C — clang
echo 'int add_i32(int a, int b){return a+b;}' > "$B/c.c"
"$CLANG" $CT -ffreestanding -g -O0 -c "$B/c.c" -o "$B/c_clang.o"
# 2. C — gcc
XTENSA_GNU_CONFIG="$(xtensa_cfg esp32)" "$GCC" -ffreestanding -g -O0 -c "$B/c.c" -o "$B/c_gcc.o"
# 3. Zig
echo 'export fn add_i32(a: i32, b: i32) callconv(.c) i32 { return a +% b; }' > "$B/z.zig"
"$ZIG" build-obj -target xtensa-freestanding-none -mcpu=esp32 -O Debug -femit-bin="$B/z.o" "$B/z.zig" 2>/dev/null
# 4. Rust (extract single .o from the staticlib)
mkdir -p "$B/rs"
cat > "$B/rs/lib.rs" <<'EOF'
#![no_std]
#[no_mangle] pub extern "C" fn add_i32(a: i32, b: i32) -> i32 { a.wrapping_add(b) }
#[panic_handler] fn p(_: &core::panic::PanicInfo) -> ! { loop {} }
EOF
cat > "$B/rs/Cargo.toml" <<'EOF'
[package]
name = "rsdbg"
version = "0.0.0"
edition = "2021"
[lib]
path = "lib.rs"
crate-type = ["staticlib"]
[profile.release]
debug = "full"
panic = "abort"
EOF
( cd "$B/rs" && RUSTC="$RUSTC" "$CARGO" rustc --release -Z build-std=core --target xtensa-esp32-none-elf -- --emit=obj >/dev/null 2>&1 )
RS_O=$(find "$B/rs/target/xtensa-esp32-none-elf/release/deps" -name 'rsdbg-*.o' | head -1)
[ -n "$RS_O" ] && cp "$RS_O" "$B/rs.o"
# 5. D (LDC) — direct -c; add_i32 has no libcall so the literal-pool bug
# (docs/19) doesn't bite here, and we keep LDC's native DWARF instead of
# losing it to the clang-as reassembly.
echo 'extern(C) int add_i32(int a, int b) { return a + b; }' > "$B/d.d"
"$LDC2" -mtriple=xtensa-esp-elf -mcpu=esp32 -betterC -g -c "$B/d.d" -of="$B/d.o"

echo "== (a) DWARF section bytes per toolchain =="
# Parse `llvm-readelf -S` tabular output; field 6 = Size in hex (no 0x prefix).
sz() { local f="$1" sect="$2"
  llvm-readelf -S "$f" 2>/dev/null | awk -v s="$sect" '$0 ~ s" "{print $6; exit}'; }
h2d() { [ -n "$1" ] && [ "$1" != "-" ] && printf "%d" "$((16#$1))" 2>/dev/null || printf -; }
printf "  %-10s %-8s %-8s %-8s %-8s %-8s\n" toolchain abbrev info line str loc
for tag in c_clang:clang c_gcc:gcc rs:rust z:zig d:LDC; do
  L="${tag%:*}.o"; name="${tag#*:}"
  [ -f "$B/$L" ] || { printf "  %-10s (no object)\n" "$name"; continue; }
  printf "  %-10s %-8s %-8s %-8s %-8s %-8s\n" "$name" \
    "$(h2d "$(sz "$B/$L" .debug_abbrev || true)")" \
    "$(h2d "$(sz "$B/$L" .debug_info   || true)")" \
    "$(h2d "$(sz "$B/$L" .debug_line   || true)")" \
    "$(h2d "$(sz "$B/$L" .debug_str    || true)")" \
    "$(h2d "$(sz "$B/$L" .debug_loc    || true)")" 2>/dev/null || true
done

echo "== (b) DWARF version emitted by default =="
for tag in c_clang:clang c_gcc:gcc rs:rust z:zig d:LDC; do
  L="${tag%:*}.o"; name="${tag#*:}"
  [ -f "$B/$L" ] || continue
  hdr=$("$DWD" --debug-info "$B/$L" 2>/dev/null | grep -m1 'Compile Unit' || true)
  v=$(printf '%s' "$hdr" | grep -oE 'version = 0x000[1-9]' | grep -oE '[1-9]' || true)
  printf "  %-10s DWARFv%s  (%s)\n" "$name" "${v:-?}" "$(printf '%s' "$hdr" | grep -oE 'format = [A-Z0-9]+' || true)"
done

echo "== (c) DW_TAG_subprogram for add_i32 (function DIE — names, types, params) =="
for tag in c_clang:clang c_gcc:gcc rs:rust z:zig d:LDC; do
  L="${tag%:*}.o"; name="${tag#*:}"
  [ -f "$B/$L" ] || continue
  echo "  --- $name ---"
  ("$DWD" --debug-info "$B/$L" 2>/dev/null | awk '/DW_TAG_subprogram/,/^[A-Z0-9][A-Z0-9]+: $/' | \
    grep -E 'DW_AT_(name|linkage_name|low_pc|high_pc|frame_base|type)' | head -6 | sed 's/^/      /') || true
done

echo "== (d) Symbol-table name (FFI symbol that the linker actually sees) =="
for tag in c_clang:clang c_gcc:gcc rs:rust z:zig d:LDC; do
  L="${tag%:*}.o"; name="${tag#*:}"
  [ -f "$B/$L" ] || continue
  sym=$(llvm-nm "$B/$L" 2>/dev/null | awk '/ T add_i32/{print $3; exit}' || true)
  [ -z "$sym" ] && sym=$(llvm-nm "$B/$L" 2>/dev/null | awk '/add_i32/{print $3; exit}' || true)
  printf "  %-10s %s\n" "$name" "${sym:--}"
done
echo "  (DWARF DW_AT_name strings in unlinked .o look wrong for rust/zig/LDC"
echo "   — DWARFv4 .debug_str_offsets needs link-time relocations to resolve.)"

echo "== (e) Reverse-engineer add_i32 codegen across toolchains =="
for tag in c_clang:clang c_gcc:gcc rs:rust z:zig d:LDC; do
  L="${tag%:*}.o"; name="${tag#*:}"
  [ -f "$B/$L" ] || continue
  echo "  --- $name (raw add_i32) ---"
  (llvm-objdump -d --mcpu=esp32 --disassemble-symbols=add_i32 "$B/$L" 2>/dev/null | tail -n +7 | head -7 | sed 's/^/      /') || true
done

echo "== (f) Frame info (.eh_frame / .debug_frame): unwind table sizes =="
printf "  %-10s eh_frame   debug_frame\n" toolchain
for tag in c_clang:clang c_gcc:gcc rs:rust z:zig d:LDC; do
  L="${tag%:*}.o"; name="${tag#*:}"
  [ -f "$B/$L" ] || continue
  printf "  %-10s %-10s %s\n" "$name" \
    "$(h2d "$(sz "$B/$L" .eh_frame || true)")" \
    "$(h2d "$(sz "$B/$L" .debug_frame || true)")" 2>/dev/null || true
done

echo "== (g) TinyGo addendum: 6th toolchain via linked-ELF inspection =="
# TinyGo never emits a -c relocatable .o (docs/24); it always builds a flash
# image. With `-work` we preserve the intermediate dir; the linked ELF
# `<work>/main` is a real Xtensa ELF with DWARF that we CAN inspect — but its
# byte counts include the full Go runtime, so they're not apples-to-apples
# with the 5 single-function .o files above. Reported here for completeness.
if [ -x "${TINYGO:-}" ]; then
  cat > "$B/dwarf.go" <<'EOF'
package main
//go:noinline
func go_add_i32(a, b int32) int32 { return a + b }
var x int32 = 7
var y int32 = 11
func main() {
    x = go_add_i32(x, y)
    for { x = go_add_i32(x, y) }
}
EOF
  # Keep stdout and stderr split — TinyGo has an open bug where merging them
  # to one fd silently truncates the build log and reports rc=1 (docs/24).
  "$TINYGO" build -opt=0 -work -target=esp32-coreboard-v2 \
      -o "$B/tg.bin" "$B/dwarf.go" >"$B/tg.out" 2>"$B/tg.err"
  TG=$(ls -td /tmp/tinygo*/ 2>/dev/null | head -1)
  if [ -n "$TG" ] && [ -f "$TG/main" ]; then
    echo "  (Source: \$TG/main from $TG — preserved by tinygo -work.)"
    printf "  %-10s %s\n" "TinyGo" \
      "DWARFv$("$DWD" --debug-info "$TG/main" 2>/dev/null | grep -oE 'version = 0x000[1-9]' | grep -oE '[1-9]' | head -1) producer: $("$DWD" --debug-info "$TG/main" 2>/dev/null | grep -oE 'DW_AT_producer.*' | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
    printf "  go_add_i32 (-opt=0) disasm:\n"
    "$ESP_CLANG_DIR/llvm-objdump" -d --mcpu=esp32 --disassemble-symbols='main.go_add_i32' "$TG/main" 2>/dev/null \
      | grep -E '^[0-9a-f]+:' | head -3 | sed 's/^/      /'
    echo "  (NOTE: .text/.debug_* sizes include the full TinyGo Go runtime + std lib,"
    echo "   not just the function; see docs/22 §g for the apples-to-apples caveat.)"
  else
    echo "  TinyGo build failed; see $B/tg.err"
  fi
else
  echo "  \$TINYGO not set; skip (run: LDC_UPSTREAM=0 ./scripts/setup.sh + source scripts/env.sh)"
fi
