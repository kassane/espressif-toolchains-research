#!/usr/bin/env bash
# open-issues.sh - reproduce/test the directly-testable OPEN esp-rs/rust issues
# on the current toolchain and compare across frontends. See docs/14.
# (The ESP-IDF-gated ones — #275/#253/#256/#258 and full #277 — need the espidf
#  std target + crates and are out of scope here; #277 is in issue277/.)
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
B=build/open-issues; mkdir -p "$B"
CTX="--target=xtensa-esp-elf -mcpu=esp32"

echo "===== #270: -C force-frame-pointers -> register-scavenge failure (rust) ====="
# Fresh CARGO_TARGET_DIR so build-std rebuilds compiler_builtins with the flag.
# Capture then grep (the build *fails* with exit 101, which pipefail would
# otherwise mistake for "no match").
i270out=$( cd experiments/esp-rs-issues && CARGO_TARGET_DIR="$PWD/../../$B/i270" \
      RUSTC="$RUSTC" RUSTFLAGS="-C force-frame-pointers" \
      "$CARGO" build --release -Z build-std=core --target xtensa-esp32-none-elf 2>&1 || true )
if echo "$i270out" | grep -qiE 'scavenge|emergency spill'; then
    echo "  REPRODUCES: 'Cannot scavenge register without an emergency spill slot' (LLVM-xtensa regalloc)"
else
    echo "  did NOT reproduce (fixed?)"
fi
echo "  (clang/gcc with -fno-omit-frame-pointer on a small fn do not trip it)"

echo "===== #278: narrow (u8/u16) stack-arg store width across frontends ====="
cat > "$B/m.c" <<'EOF'
extern unsigned fm(int,int,int,int,int,int,unsigned char,unsigned short,unsigned char,unsigned short,unsigned char);
unsigned callm(unsigned char a,unsigned short b,unsigned char c,unsigned short d,unsigned char e){return fm(1,2,3,4,5,6,a,b,c,d,e);}
EOF
cat > "$B/m.zig" <<'EOF'
extern fn fm(i32,i32,i32,i32,i32,i32,u8,u16,u8,u16,u8) callconv(.c) u32;
export fn callm(a:u8,b:u16,c:u8,d:u16,e:u8) u32 { return fm(1,2,3,4,5,6,a,b,c,d,e); }
EOF
widths(){ # obj symbol
    llvm-objdump -d --mcpu=esp32 --disassemble-symbols="$2" "$1" 2>/dev/null | grep -oE 's(8|16|32)i' | sort | uniq -c | tr '\n' ' '
}
"$CLANG" $CTX -ffreestanding -O2 -c "$B/m.c" -o "$B/mc.o"; echo "  clang caller stores: $(widths "$B/mc.o" callm)"
XTENSA_GNU_CONFIG="$(xtensa_cfg esp32)" "$GCC" -ffreestanding -O2 -c "$B/m.c" -o "$B/mg.o"; echo "  gcc   caller stores: $(widths "$B/mg.o" callm)"
"$ZIG" build-obj -target xtensa-freestanding-none -mcpu=esp32 -O ReleaseFast -femit-bin="$B/mz.o" "$B/m.zig"; echo "  zig   caller stores: $(widths "$B/mz.o" callm)"
# Rust caller (rs_issue278_callm in experiments/esp-rs-issues/lib.rs)
( cd experiments/esp-rs-issues && CARGO_TARGET_DIR="$PWD/../../$B/i278" \
    RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target xtensa-esp32-none-elf >/dev/null 2>&1 )
RS_LIB="$B/i278/xtensa-esp32-none-elf/release/libesp_rs_issues.a"
[ -f "$RS_LIB" ] && echo "  rust  caller stores: $(widths "$RS_LIB" rs_issue278_callm)"
# D caller (d_issue278_callm in ports.d, compiled by run.sh §b — re-build here so we don't depend on order)
"$LDC2" -mtriple=xtensa-esp-elf -mcpu=esp32 $LDC_PE -betterC -Os --function-sections -c experiments/esp-rs-issues/ports.d -of="$B/md.o" 2>/dev/null
echo "  D/LDC caller stores: $(widths "$B/md.o" d_issue278_callm)"
echo "  Per-frontend caller policy as observed on current toolchain:"
echo "    - clang / rust : narrow s8i + s16i stores (per upstream report)"
echo "    - gcc / zig / D: widened s32i stores (matches the Xtensa ABI guidance)"
echo "    Slot OFFSETS are 4-byte-stepped in every frontend; the symptom only"
echo "    manifests if the callee reads its narrow arg as a *full word* and"
echo "    sees the upper bytes (which the narrow store leaves undefined). #278's"
echo "    own repro was a C callee reading u32 from the slot. Workaround: declare"
echo "    such params as u32 on both sides. See docs/14."

echo "===== #243: size_of::<Self>() in release (xtensa-esp32s3-none-elf) — SIGSEGV? ====="
mkdir -p "$B/i243"
printf '[package]\nname="i243"\nversion="0.0.0"\nedition="2021"\n[lib]\nname="i243"\npath="lib.rs"\ncrate-type=["staticlib"]\n[profile.release]\nopt-level=3\ndebug=2\npanic="abort"\n' > "$B/i243/Cargo.toml"
cat > "$B/i243/lib.rs" <<'EOF'
#![no_std]
pub trait Sz { fn s(&self) -> usize; }
pub struct A([u8;8]); pub struct C([u32;16]);
impl Sz for A { fn s(&self)->usize{ core::mem::size_of::<Self>() } }
impl Sz for C { fn s(&self)->usize{ core::mem::size_of::<Self>() } }
#[no_mangle] pub extern "C" fn use_sz(x:&A,y:&C)->usize{ x.s()+y.s() }
#[panic_handler] fn p(_:&core::panic::PanicInfo)->!{loop{}}
EOF
i243out=$( cd "$B/i243" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target xtensa-esp32s3-none-elf 2>&1 || true )
if echo "$i243out" | grep -qiE 'SIGSEGV|signal: 11'; then
    echo "  REPRODUCES SIGSEGV"
else
    echo "  did NOT reproduce (compiles cleanly on 1.95; was 1.80/1.82)"
fi
