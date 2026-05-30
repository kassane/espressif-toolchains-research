#!/usr/bin/env bash
# run.sh - re-test esp-rs/rust issue reproducers on the current toolchain and
# port the equivalent code to all frontends (clang/gcc/zig). See docs/13.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
D=experiments/esp-rs-issues; B=build/esp-rs-issues; mkdir -p "$B"
CTX="--target=xtensa-esp-elf -mcpu=esp32"

echo "== Rust crate (xtensa-esp32-none-elf, opt-level=z): #95 + #137 + #277(min) =="
( cd "$D" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target xtensa-esp32-none-elf 2>&1 | tail -1 )
echo "   -> compiles: #95 enum/match FIXED, #137 u128 OK, #277 float-pool min does NOT ICE"

echo "== Port #95/#277 to C (clang + gcc, xtensa) =="
"$CLANG" $CTX -ffreestanding -Os -c "$D/ports.c" -o "$B/pc.o"   && echo "   clang OK"
XTENSA_GNU_CONFIG="$(xtensa_cfg esp32)" "$GCC" -ffreestanding -Os -c "$D/ports.c" -o "$B/pg.o" && echo "   gcc   OK"
echo "   (#137 u128 OMITTED for C: __int128 is unsupported by clang & gcc on xtensa)"

echo "== Port #95/#137/#277 to Zig (xtensa) =="
"$ZIG" build-obj -target xtensa-freestanding-none -mcpu=esp32 -O ReleaseSmall -femit-bin="$B/pz.o" "$D/ports.zig" && echo "   zig   OK (u128 supported, like Rust)"

echo "== D ports =="
LDC_FLAGS_E32="-mtriple=xtensa-esp-elf $(ldc_xtensa_flags esp32) $LDC_PE -betterC -Os"
# (a) #137-style: ucent. Reserved keyword but unimplemented in DMD/LDC.
#     Compile the isolated fragment in its own object and capture the diagnostic.
echo "   #137 ucent: compiling ports_ucent.d ..."
ucent_log=$("$LDC2" $LDC_FLAGS_E32 -c "$D/ports_ucent.d" -of="$B/pd_ucent.o" 2>&1 || true)
echo "$ucent_log" | sed -n '1,3p' | sed 's/^/      /'
if echo "$ucent_log" | grep -qi 'cent.*obsolete\|cent.*not implemented\|cent.*deprecated'; then
    echo "      -> verdict: D rejects ucent at the frontend ('obsolete' / 'not implemented')."
else
    echo "      -> verdict: ucent compiled? (unexpected; see log above)"
fi
echo "   #270 frame-pointer: compiling ports.d with --frame-pointer=all -Os ..."
"$LDC2" $LDC_FLAGS_E32 --frame-pointer=all -c "$D/ports.d" -of="$B/pd_fp.o" \
    && echo "      OK - no ICE; small reg-heavy fn compiles with forced FP (matches clang/gcc, not Rust's compiler_builtins case)" \
    || { echo "      FAIL - LDC ICE'd with --frame-pointer=all"; exit 1; }
# (b) Plain build of ports.d (for the #278 disasm and as the canonical D port object).
"$LDC2" $LDC_FLAGS_E32 -c "$D/ports.d" -of="$B/pd.o" && echo "   ldc   OK (ports.d compiles; ucent skipped per above)"
echo "   #278 disasm — caller stack-arg store widths (callm: 6 reg + 5 narrow stack args):"
ldc_widths=$(llvm-objdump -d --mcpu=esp32 --disassemble-symbols=d_issue278_callm "$B/pd.o" 2>/dev/null | grep -oE 's(8|16|32)i' | sort | uniq -c | tr '\n' ' ')
echo "      ldc caller stores: ${ldc_widths:-<none>}"
echo "   #278 ubyte-callback disasm (1 reg arg, sanity probe):"
llvm-objdump -d --mcpu=esp32 --disassemble-symbols=d_issue278_emit_byte_call "$B/pd.o" 2>/dev/null \
    | awk '/<d_issue278_emit_byte_call>:/{p=1} p{print "      "$0; if(/retw/)exit}'

echo "== Runtime miscompile tests on qemu-system-xtensa: #161 + #177 =="
RT=experiments/esp-rs-issues/runtime; QR=experiments/qemu-run; RB=build/esp-rs-rt; mkdir -p "$RB"
RTLIB="$ESP_CLANG_DIR/../lib/clang-runtimes/xtensa-esp-unknown-elf/esp32/lib/libclang_rt.builtins.a"
( cd "$RT" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target xtensa-esp32-none-elf >/dev/null 2>&1 )
"$CLANG" $CTX -ffreestanding -Os -I"$QR" -c "$RT/rt_main.c" -o "$RB/rt_main.o"
"$CLANG" $CTX -ffreestanding -Os -c "$QR/start.S" -o "$RB/start.o"
cp "$RT/target/xtensa-esp32-none-elf/release/librt.a" "$RB/"
$LLD -T "$QR/sim.ld" -o "$RB/rt.elf" "$RB/start.o" "$RB/rt_main.o" --start-group "$RB/librt.a" "$RTLIB" --end-group
timeout 12 "$TC/qemu/qemu/bin/qemu-system-xtensa" -machine sim -cpu dc233c -semihosting -nographic -monitor none -kernel "$RB/rt.elf" || true
