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

echo "== Runtime miscompile tests on qemu-system-xtensa: #161 + #177 + #278 =="
RT=experiments/esp-rs-issues/runtime; QR=experiments/qemu-run; RB=build/esp-rs-rt; mkdir -p "$RB"
RTLIB="$ESP_CLANG_DIR/../lib/clang-runtimes/xtensa-esp-unknown-elf/esp32/lib/libclang_rt.builtins.a"
( cd "$RT" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target xtensa-esp32-none-elf >/dev/null 2>&1 )
"$CLANG" $CTX -ffreestanding -Os -I"$QR" -c "$RT/rt_main.c" -o "$RB/rt_main.o"
"$CLANG" $CTX -ffreestanding -Os -c "$QR/start.S" -o "$RB/start.o"
# #278 frontend callers in their own TUs (so xmain can't inline + constant-
# propagate the literal args into widened s32i stores, sidestepping the bug).
# Callee in rt_callee.c is built by clang with FULL u32 params (the "third-
# party C library" stand-in); each caller declares it with NARROW types
# (u8/u16) so the call-site codegen emits the per-frontend store width.
"$CLANG" $CTX -ffreestanding -Os -c "$RT/rt_callee.c" -o "$RB/rt_callee.o"
"$CLANG" $CTX -ffreestanding -Os -c "$RT/rt_clang.c"  -o "$RB/rt_clang.o"
XTENSA_GNU_CONFIG="$(xtensa_cfg esp32)" "$GCC" -ffreestanding -Os -c "$RT/rt_gcc.c" -o "$RB/rt_gcc.o"
# zig cc: clang 22.1.4 (Zig 0.17 bundle), drop-in replacement for esp-clang
# 21.1.3 on the same Xtensa backend. -lunwind requested at link time; here
# we just compile to .o, but the flag carries through the driver to record
# the libunwind dependency on the resulting object's .note (no-op for -c).
"$ZIG" cc --target=xtensa-freestanding-none -mcpu=esp32 -ffreestanding -Os -lunwind -c "$RT/rt_zigcc.c" -o "$RB/rt_zigcc.o"
"$ZIG" build-obj -target xtensa-freestanding-none -mcpu=esp32 -O ReleaseSmall -femit-bin="$RB/rt_zig.o" "$RT/rt_zig.zig"
"$LDC2" -mtriple=xtensa-esp-elf -mcpu=esp32 $LDC_PE -betterC -Os -c "$RT/rt_d.d" -of="$RB/rt_d.o"
# Legacy lanes: $ZIG_016 (Zig 0.16 / LLVM 21.1.0) and $LDC2_UPSTREAM (LDC
# 1.42-git on upstream LLVM 22.1.2, pre-2026-05-30 fork fix). Verifies
# whether the narrow-vs-wide stack-arg-store policy is version-dependent.
"$ZIG_016" build-obj -target xtensa-freestanding-none -mcpu=esp32 -O ReleaseSmall -femit-bin="$RB/rt_zig016.o" "$RT/rt_zig016.zig"
"$LDC2_UPSTREAM" -mtriple=xtensa-esp-elf -mcpu=esp32 $LDC_PE -betterC -Os -output-s -of="$RB/rt_d_up.s" "$RT/rt_d_up.d"
sed -E -i '/^[[:space:]]*\.cfi_/d' "$RB/rt_d_up.s"
"$CLANG" $CTX -c "$RB/rt_d_up.s" -o "$RB/rt_d_up.o"
cp "$RT/target/xtensa-esp32-none-elf/release/librt.a" "$RB/"
$LLD -T "$QR/sim.ld" -o "$RB/rt.elf" "$RB/start.o" "$RB/rt_main.o" \
    "$RB/rt_callee.o" "$RB/rt_clang.o" "$RB/rt_gcc.o" "$RB/rt_zig.o" "$RB/rt_d.o" \
    "$RB/rt_zig016.o" "$RB/rt_d_up.o" "$RB/rt_zigcc.o" \
    --start-group "$RB/librt.a" "$RTLIB" --end-group
timeout 12 "$TC/qemu/qemu/bin/qemu-system-xtensa" -machine sim -cpu dc233c -semihosting -nographic -monitor none -kernel "$RB/rt.elf" || true

# Alternative link path: zig cc as the linker driver (instead of bare $LLD)
# with -lunwind from zig's bundled libunwind. Verifies that zig cc can act as
# a drop-in replacement for esp-clang on the entire link step too — useful
# for matrix consumers who don't want to depend on the esp-clang prefix at
# all. Strips .eh_frame from objects that emit it (zig/D/zigcc default;
# sim.ld doesn't place it).
echo "== Alt link path: zig cc -nostdlib -Wl,-T,sim.ld (replaces esp-clang + bare LLD) =="
for o in rt_zig.o rt_d.o rt_zig016.o rt_zigcc.o; do
    "$ESP_CLANG_DIR/llvm-objcopy" --remove-section=.eh_frame --remove-section=.eh_frame_hdr "$RB/$o" "$RB/${o%.o}_noeh.o"
done
"$ZIG" cc --target=xtensa-freestanding-none -mcpu=esp32 -nostdlib -nodefaultlibs \
    -Wl,-T,"$QR/sim.ld" \
    -o "$RB/rt_zigcc_link.elf" \
    "$RB/start.o" "$RB/rt_main.o" \
    "$RB/rt_callee.o" "$RB/rt_clang.o" "$RB/rt_gcc.o" "$RB/rt_zig_noeh.o" "$RB/rt_d_noeh.o" \
    "$RB/rt_zig016_noeh.o" "$RB/rt_d_up.o" "$RB/rt_zigcc_noeh.o" \
    -Wl,--start-group "$RB/librt.a" "$RTLIB" -Wl,--end-group 2>&1 | head -5
timeout 12 "$TC/qemu/qemu/bin/qemu-system-xtensa" -machine sim -cpu dc233c -semihosting -nographic -monitor none -kernel "$RB/rt_zigcc_link.elf" || true
