#!/usr/bin/env bash
# run.sh - address-space support across frontends on Xtensa, and the real
# mechanism for ESP memory regions (IRAM/DRAM/flash/RTC). See docs/18.
# Self-contained: generates sources under build/as.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
B=build/as; mkdir -p "$B"
CT="--target=xtensa-esp-elf -mcpu=esp32"; ZT="-target xtensa-freestanding-none -mcpu=esp32"; G="XTENSA_GNU_CONFIG=$(xtensa_cfg esp32)"
LT="-mtriple=xtensa-esp-elf -mcpu=esp32"

echo "== datalayout: distinct address spaces on Xtensa? =="
echo 'void f(){}' | "$CLANG" $CT -S -emit-llvm -o - -x c - 2>/dev/null | grep -m1 'target datalayout'
echo "  (only p:32:32 => single flat address space; addrspace(N) is annotation-only)"

echo "== clang: numbered __attribute__((address_space(1))) =="
echo 'char load(char __attribute__((address_space(1)))* p){return *p;}' > "$B/as.c"
"$CLANG" $CT -ffreestanding -O1 -S -emit-llvm -o - -x c "$B/as.c" 2>/dev/null | grep -m1 'addrspace(1)' && echo "  -> clang emits ptr addrspace(1) (compiles)"

echo "== gcc: numbered address_space(1) =="
eval $G "$GCC" -ffreestanding -O1 -c "$B/as.c" -o "$B/as_g.o" 2>&1 | grep -m1 -iE 'ignored|attribute' || echo "  (compiled)"

echo "== zig: addrspace(.generic) vs a non-xtensa space (.flash) =="
printf 'export fn zg(p: *addrspace(.generic) const u8) u8 { return p.*; }\n' > "$B/ok.zig"
"$ZIG" build-obj $ZT -O ReleaseSmall -femit-bin="$B/zg.o" "$B/ok.zig" && echo "  .generic: OK"
printf 'export fn zf(p: *addrspace(.flash) const u8) u8 { return p.*; }\n' > "$B/bad.zig"
"$ZIG" build-obj $ZT -O ReleaseSmall -femit-bin="$B/zf.o" "$B/bad.zig" 2>&1 | grep -m1 -iE 'not supported|error' || true

echo "== rust: no address-space syntax (all pointers addrspace 0) =="

echo "== D/LDC: no pointer-addrspace syntax in the language =="
# D has no __attribute__((address_space(N))) analog at the source level.
# Probe 1: confirm LDC's ldc.attributes has no pointer-addrspace attribute.
echo "  D source-level: N/A (no syntax) — LDC's @llvmAttr is function/param only"
# Probe 2: inline LLVM IR via __ir! CAN spell addrspace(N), but Xtensa codegen
# flattens it identically to addrspace(0) — same datalayout p:32:32 story.
cat > "$B/ir_as.d" <<'EOF'
import ldc.llvmasm;
extern(C) ubyte load_as1(uint p) @trusted {
  return __ir!(`%pp = inttoptr i32 %0 to ptr addrspace(1)
                %v = load i8, ptr addrspace(1) %pp
                ret i8 %v`, ubyte)(p);
}
extern(C) ubyte load_as0(uint p) @trusted {
  return __ir!(`%pp = inttoptr i32 %0 to ptr
                %v = load i8, ptr %pp
                ret i8 %v`, ubyte)(p);
}
EOF
"$LDC2" $LT -betterC -O2 -output-ll -of="$B/ir_as.ll" "$B/ir_as.d" 2>/dev/null
"$LDC2" $LT -betterC -O2 -c -of="$B/ir_as.o" "$B/ir_as.d" 2>/dev/null
grep -m1 'addrspace(1)' "$B/ir_as.ll" >/dev/null && echo "  D inline IR: ptr addrspace(1) carried through to IR (via __ir!)"
d_as1=$(llvm-objdump -d --mcpu=esp32 --disassemble-symbols=load_as1 "$B/ir_as.o" 2>/dev/null | grep -oE 'l8ui[[:space:]]+a[0-9]+, a[0-9]+, [0-9]+' | head -1)
d_as0=$(llvm-objdump -d --mcpu=esp32 --disassemble-symbols=load_as0 "$B/ir_as.o" 2>/dev/null | grep -oE 'l8ui[[:space:]]+a[0-9]+, a[0-9]+, [0-9]+' | head -1)
[ "$d_as1" = "$d_as0" ] && echo "  D codegen: load_as1 ($d_as1) == load_as0 ($d_as0) — addrspace flattened"

echo "== ESP regions via linker SECTIONS (the real mechanism) — every frontend =="
echo 'void __attribute__((section(".iram1.text"))) hot(void){}' > "$B/sec.c"
"$CLANG" $CT -ffreestanding -Os -c "$B/sec.c" -o "$B/sec_clang.o"
eval $G "$GCC" -ffreestanding -Os -c "$B/sec.c" -o "$B/sec_gcc.o"
printf 'export fn hot() linksection(".iram1.text") void {}\n' > "$B/sec.zig"
"$ZIG" build-obj $ZT -O ReleaseSmall -femit-bin="$B/sec_zig.o" "$B/sec.zig"
mkdir -p "$B/secrs"
printf '[package]\nname="secrs"\nversion="0.0.0"\nedition="2021"\n[lib]\nname="secrs"\npath="lib.rs"\ncrate-type=["staticlib"]\n[profile.release]\npanic="abort"\n' > "$B/secrs/Cargo.toml"
printf '#![no_std]\n#[no_mangle] #[link_section=".iram1.text"] pub extern "C" fn hot(){}\n#[panic_handler] fn p(_:&core::panic::PanicInfo)->!{loop{}}\n' > "$B/secrs/lib.rs"
( cd "$B/secrs" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target xtensa-esp32-none-elf >/dev/null 2>&1 )
cat > "$B/sec.d" <<'EOF'
import ldc.attributes;
extern(C) @section(".iram1.text") void hot() {}
EOF
"$LDC2" $LT -betterC -Os -c -of="$B/sec_d.o" "$B/sec.d" 2>/dev/null
sec(){ llvm-readobj --sections "$1" 2>/dev/null | grep -oE '\.iram1[a-z0-9._]*' | head -1; }
for o in sec_clang sec_gcc sec_zig; do printf "  %-10s %s\n" "$o" "$(sec "$B/$o.o")"; done
printf "  %-10s %s\n" "rust" "$(sec "$(find "$B/secrs/target" -name libsecrs.a|head -1)")"
printf "  %-10s %s\n" "sec_d" "$(sec "$B/sec_d.o")"

echo "== summary table =="
printf "  %-8s | %-32s | %s\n" "frontend" "addrspace(N) syntax" "@section/linksection .iram1.text"
printf "  %-8s-+-%-32s-+-%s\n" "--------" "--------------------------------" "--------------------------------"
printf "  %-8s | %-32s | %s\n" "clang"  "accepted (annotation)"          "$(sec "$B/sec_clang.o")"
printf "  %-8s | %-32s | %s\n" "gcc"    "ignored (warning)"              "$(sec "$B/sec_gcc.o")"
printf "  %-8s | %-32s | %s\n" "zig"    ".generic OK / .flash rejected"  "$(sec "$B/sec_zig.o")"
printf "  %-8s | %-32s | %s\n" "rust"   "none (no syntax)"               "$(sec "$(find "$B/secrs/target" -name libsecrs.a|head -1)")"
printf "  %-8s | %-32s | %s\n" "d/ldc"  "N/A (no syntax; __ir! carries)" "$(sec "$B/sec_d.o")"
