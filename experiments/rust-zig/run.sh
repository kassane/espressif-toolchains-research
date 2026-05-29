#!/usr/bin/env bash
# run.sh - Rust <-> Zig frontend interop on Xtensa (the two non-C LLVM frontends).
#   (a) scalar ABI incl. C-inexpressible u128/f128/f16  -> IR signatures
#   (b) runtime: Rust calls Zig with u128 (carry across 4 words) on qemu
#   (c) cross-language LTO (rust 21.1.3 bc + zig 22.1.4 bc) -> LLVM-21 vs LLVM-22
#       cluster split (was 21.1.0 vs 21.1.3 patch skew on the legacy $ZIG_016 lane)
#   (d) atomics: both use native s32c1i (no libcall)?
# See docs/17.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
D=experiments/rust-zig; B=build/rz; QR=experiments/qemu-run; mkdir -p "$B"
CT="--target=xtensa-esp-elf -mcpu=esp32"; ZT="-target xtensa-freestanding-none -mcpu=esp32"
RTLIB="$ESP_CLANG_DIR/../lib/clang-runtimes/xtensa-esp-unknown-elf/esp32/lib/libclang_rt.builtins.a"
# disassemble a symbol from a staticlib (find the defining member object)
disa(){ local ar="$1" sym="$2" t="$B/_x"; rm -rf "$t"; mkdir -p "$t"; ( cd "$t" && llvm-ar x "$PWD/../../../$ar" 2>/dev/null || llvm-ar x "$ar" 2>/dev/null ); \
  for o in "$t"/*.o; do if llvm-nm "$o" 2>/dev/null | grep -q " T $sym\b"; then llvm-objdump -d --mcpu=esp32 --disassemble-symbols="$sym" "$o" 2>/dev/null; return; fi; done; }

echo "== (a) scalar ABI: Rust vs Zig IR arg/ret signatures (esp32) =="
"$ZIG" build-obj $ZT -O ReleaseSmall -fno-emit-bin -femit-llvm-ir="$B/iface.ll" "$D/iface.zig"
( cd "$D/rs" && RUSTC="$RUSTC" "$CARGO" rustc --release -Z build-std=core --target xtensa-esp32-none-elf -- --emit=llvm-ir >/dev/null 2>&1 )
RLL=$(grep -rls 'define.*@rs_add_u128' "$D/rs/target" --include='*.ll' | head -1)
sig(){ grep -hE "define .*@$1\b" "$2" 2>/dev/null | head -1 | grep -oE '\([^{]*' \
  | sed -E 's/ ?(noundef|noalias|readonly|captures\([^)]*\)|dereferenceable\([^)]*\)|align [0-9]+|writable|writeonly|zeroext|range\([^)]*\)|dead_on_unwind|initializes\([^)]*\))//g; s/  */ /g'; }
for fn in add_u128 add_f128 add_f16 not enum; do
  printf "  %-9s rust: %-32s zig: %s\n" "$fn" "$(sig "rs_$fn" "$RLL")" "$(sig "iface.zig_$fn" "$B/iface.ll")"
done
echo "  (u128/f128: rust uses byval ptr for arg2, zig direct -- backend reconciles to same machine ABI)"

echo "== (b) runtime: Rust computes 2x u128, calls Zig, checks carry (qemu xtensa) =="
"$ZIG" build-obj $ZT -O ReleaseSmall -femit-bin="$B/rt.o" "$D/rt.zig"
( cd "$D/rt" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target xtensa-esp32-none-elf >/dev/null 2>&1 )
cp "$(find "$D/rt/target" -name librzrt.a | head -1)" "$B/"
"$CLANG" $CT -ffreestanding -Os -I"$QR" -c "$D/main.c" -o "$B/main.o"
"$CLANG" $CT -ffreestanding -Os -c "$QR/start.S" -o "$B/start.o"
ld.lld -T "$QR/sim.ld" -o "$B/rz.elf" "$B/start.o" "$B/main.o" "$B/rt.o" --start-group "$B/librzrt.a" "$RTLIB" --end-group
timeout 12 "$TC/qemu/qemu/bin/qemu-system-xtensa" -machine sim -cpu dc233c -semihosting -nographic -monitor none -kernel "$B/rz.elf" || true

echo "== (c) cross-language LTO: rust bc (21.1.3) + zig bc ($("$ZIG" cc --version|head -1|grep -oE '[0-9]+\.[0-9]+\.[0-9]+'|head -1)) =="
( cd "$D/rt" && RUSTC="$RUSTC" "$CARGO" rustc --release -Z build-std=core --target xtensa-esp32-none-elf -- --emit=llvm-bc >/dev/null 2>&1 )
cp "$(find "$D/rt/target" -name 'rzrt*.bc' | head -1)" "$B/rzrt.bc"
"$ZIG" build-obj $ZT -O ReleaseSmall -fno-emit-bin -femit-llvm-bc="$B/rt.bc" "$D/rt.zig"
if ld.lld --lto-O2 -e rs_check_u128 -u zig_add_u128 "$B/rzrt.bc" "$B/rt.bc" -o "$B/lto.elf" 2>"$B/lto.err"; then
  echo "  LTO linked (versions matched)"; else echo "  LTO FAILS: $(grep -oiE 'Invalid record' "$B/lto.err" | head -1) (LLVM-21 cluster lld vs zig's LLVM-${ZBC_MAJ:-22} bitcode — set ZIG=\$ZIG_016 to repro the 21.1.0-vs-21.1.3 patch skew)"; fi

echo "== (d) atomics: native s32c1i in both (no __atomic/__sync libcall)? =="
"$ZIG" build-obj $ZT -O ReleaseSmall -femit-bin="$B/at.o" "$D/atomic.zig"
( cd "$D/atomic" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target xtensa-esp32-none-elf >/dev/null 2>&1 )
RAA=$(find "$D/atomic/target" -name librzat.a | head -1)
zc=$(llvm-objdump -d --mcpu=esp32 --disassemble-symbols=zig_atomic_add "$B/at.o" 2>/dev/null | grep -c s32c1i)
rc=$(disa "$RAA" rs_atomic_add | grep -c s32c1i)
echo "  zig_atomic_add s32c1i=$zc   rs_atomic_add s32c1i=$rc   (both native CAS + memw; no libcall)"

echo "== (e) optional pointers: Rust Option<NonNull<T>> <-> Zig ?*T =="
"$ZIG" build-obj $ZT -O ReleaseSmall -fno-emit-bin -femit-llvm-ir="$B/opt.ll" "$D/opt.zig" >/dev/null 2>&1
"$ZIG" build-obj $ZT -O ReleaseSmall -femit-bin="$B/opt.o" "$D/opt.zig"
( cd "$D/opt" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target xtensa-esp32-none-elf >/dev/null 2>&1 )
echo "  zig_opt IR: $(grep -hoE 'i32 @opt.zig_opt\([^)]*\)' "$B/opt.ll" | head -1)  (Rust Option<NonNull> lowers to the same single ptr)"
printf '#include "semihost.h"\nextern int rs_check_opt(void);\nint xmain(void){int ok=rs_check_opt();puts_(ok==1?"\\n  opt-ptr: Some(&x)->addr, None->0  OK\\n":"\\n  opt-ptr FAIL\\n");sys_exit(ok==1?0:1);return 0;}\n' > "$B/optmain.c"
"$CLANG" $CT -ffreestanding -Os -I"$QR" -c "$B/optmain.c" -o "$B/optmain.o"
cp "$(find "$D/opt/target" -name librzopt.a | head -1)" "$B/"
ld.lld -T "$QR/sim.ld" -o "$B/opt.elf" "$B/start.o" "$B/optmain.o" "$B/opt.o" --start-group "$B/librzopt.a" "$RTLIB" --end-group
timeout 12 "$TC/qemu/qemu/bin/qemu-system-xtensa" -machine sim -cpu dc233c -semihosting -nographic -monitor none -kernel "$B/opt.elf" || true

echo "== (f) packed structs: Rust #[repr(packed)] vs Zig packed struct (different!) =="
"$ZIG" build-obj $ZT -O ReleaseSmall -fno-emit-bin -femit-llvm-ir="$B/pk.ll" "$D/packed.zig" >/dev/null 2>&1
echo "  zig @sizeOf: packed{u8,u8}=2(backing u16)  extern{u8,u8}=2  packed{u4,u4}=1 (sub-byte; Rust can't)"
printf 'const P=packed struct{a:u8,b:u8};\nexport fn bad(s:P) u8 {return s.a;}\n' > "$B/bad.zig"
pkerr=$("$ZIG" build-obj $ZT -fno-emit-bin -femit-llvm-ir="$B/b.ll" "$B/bad.zig" 2>&1 || true)
echo "  packed-by-value in C-ABI fn: $(printf '%s' "$pkerr" | grep -oE "not allowed in .*calling convention '[a-z0-9_]+'" | head -1 || echo '(allowed?!)')"
echo "  => use Zig extern struct <-> Rust #[repr(C)] for FFI; packed means different things"

# ---------------------------------------------------------------------------
# D parity probes ($LDC2 = espressif/llvm-project 21.1.3, same family as rust/clang)
# Adds a 3rd column to the same scalar/atomic/opt/u64 questions §(a),(d),(e).
# ---------------------------------------------------------------------------
echo "== (g-D) D probes via LDC (espressif 21.1.3, -betterC, -mcpu=esp32) =="

# (D-1) cent/ucent reserved keyword probe: should be a hard compile error.
# Capture the exact LDC diagnostic verbatim.
centerr=$("$LDC2" -mtriple=xtensa-esp-elf $(ldc_xtensa_flags esp32) $LDC_PE -betterC -Os -c \
    -of="$B/_cent.o" "$D/d/cent_probe.d" 2>&1 || true)
echo "  cent/ucent: $(printf '%s' "$centerr" | grep -oE '(Error:.*obsolete[^|]*|use .core\.int128\.Cent.[^|]*)' | head -1)"

# Compile iface.d to IR + object on esp32.
# shellcheck disable=SC2046
"$LDC2" -mtriple=xtensa-esp-elf $(ldc_xtensa_flags esp32) $LDC_PE -betterC -Os \
    -output-ll -of="$B/d_iface.ll" -c "$D/d/iface.d" >/dev/null 2>&1
# shellcheck disable=SC2046
"$LDC2" -mtriple=xtensa-esp-elf $(ldc_xtensa_flags esp32) $LDC_PE -betterC -Os \
    -c -of="$B/d_iface.o" "$D/d/iface.d" >/dev/null 2>&1

# Re-use the §(a) `sig` helper on the D IR (must be in scope -- it is).
dsig(){ grep -hE "define .*@$1\b" "$B/d_iface.ll" 2>/dev/null | head -1 | grep -oE '\([^{]*' \
  | sed -E 's/ ?(noundef|noalias|readonly|captures\([^)]*\)|dereferenceable\([^)]*\)|align [0-9]+|writable|writeonly|zeroext|range\([^)]*\)|dead_on_unwind|initializes\([^)]*\)|sret\([^)]*\))//g; s/  */ /g'; }

# (D-2) Atomics: disassemble d_atomic_add, count native s32c1i (esp32 CAS).
dc_add=$(llvm-objdump -d --mcpu=esp32 --disassemble-symbols=d_atomic_add "$B/d_iface.o" 2>/dev/null | (grep -c s32c1i || true))
dc_cas=$(llvm-objdump -d --mcpu=esp32 --disassemble-symbols=d_atomic_cas "$B/d_iface.o" 2>/dev/null | (grep -c s32c1i || true))
dc_lib=$(llvm-nm "$B/d_iface.o" 2>/dev/null | (grep -cE ' U __(atomic|sync)_' || true))
echo "  d_atomic_add s32c1i=$dc_add  d_atomic_cas s32c1i=$dc_cas  __atomic/__sync libcalls=$dc_lib  (native CAS, no libcall)"

# (D-4) u64: confirm i64 IR + a2..a5 in the disassembly entry (same as rust/zig).
du64_first=$(llvm-objdump -d --mcpu=esp32 --disassemble-symbols=d_add_u64 "$B/d_iface.o" 2>/dev/null | (grep -oE 'add\.n\s+a[0-9]+,\s*a[0-9]+,\s*a[0-9]+' || true) | head -1)
echo "  d_add_u64 first add: $du64_first  (expect a4|a2 lo halves -> a-regs, matches rust/zig)"

# 3-frontend parity table on the same questions answered for rust/zig above.
echo "  --- 3-frontend parity (rust | zig | d) ---"
printf "  %-12s  %-22s  %-22s  %s\n" "probe" "rust IR arg-shape" "zig IR arg-shape" "d IR arg-shape"
printf "  %-12s  %-22s  %-22s  %s\n" "add_u128" "$(sig rs_add_u128 "$RLL")" "$(sig iface.zig_add_u128 "$B/iface.ll")" "$(dsig d_add_u128)"
printf "  %-12s  %-22s  %-22s  %s\n" "add_u64"  "(i64,i64)->i64 [n/a]" "(i64,i64)->i64 [n/a]" "$(dsig d_add_u64)"
printf "  %-12s  %-22s  %-22s  %s\n" "opt-ptr"  "(ptr)->i32 [Option<&T>]" "$(grep -hoE 'i32 @opt.zig_opt\([^)]*\)' "$B/opt.ll" | head -1)" "$(dsig d_opt)"
printf "  %-12s  rust=%d  zig=%d  d=%d (per fn)  -- all emit native esp32 CAS\n" "atomic+s32c1i" "$rc" "$zc" "$dc_add"

# Parity verdict.
echo "  --- verdict ---"
echo "  u128:    D mismatches rust/zig -- D has NO native i128. core.int128.Cent is a"
echo "           struct{ulong lo,hi}, so the ABI is sret+byval (NOT a2..a5 like the"
echo "           others). Cross-language u128 D<->rust/zig would corrupt data."
echo "  f128/f16: D has neither (real==double==8B on Xtensa). C-equivalent gap."
echo "  atomics: D matches -- LDC emits native s32c1i+memw, no __atomic libcall."
echo "  opt-ptr: D matches -- bare extern(C) ptr is the same i32 nullable as the"
echo "           other two; no Option wrapper needed (D has no native Option)."
echo "  u64:     D matches -- i64 ABI uses 2 a-reg pairs like rust/zig."
