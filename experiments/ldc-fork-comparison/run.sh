#!/usr/bin/env bash
# run.sh - LDC: espressif/llvm-project fork vs upstream LLVM-22. Same compiler
# frontend (LDC 1.42-git, DMD 2.112.1), two different LLVM backends; pin which
# behaviors are backend-driven (and got fixed) vs frontend-driven (still broken).
#
#   $LDC2          -> kassane/esp-idf-dlang xtensa-toolchain  (LLVM 21.1.3 fork)
#   $LDC2_UPSTREAM -> ldc-developers/ldc CI                   (LLVM 22.1.2 upstream)
#
# Needs setup.sh LDC_UPSTREAM=1 to fetch the upstream CI LDC. See docs/23.
#
# Sections:
#   (a) version + -mcpu=help — which Xtensa CPUs each LDC knows
#   (b) -vv probe for esp32 / esp32s2 / esp32s3 (user-tip: `ldc2 -betterC empty.d
#       -o- -c --mtriple=<t> -mcpu=<c> -vv`)
#   (c) direct ldc2 -c -> .o: does each emit a properly aligned literal pool?
#       (upstream: "R_XTENSA_SLOT0_OP not aligned to 4 bytes" -> needs -output-s
#        + esp-clang re-assembly + .cfi_* strip; fork: passes ld.lld directly)
#   (d) -mcpu=esp32s2/s3 recognition (upstream rejects; fork accepts; ldc #4919)
#   (e) datalayout string (upstream-22 has `i8:8:32-i16:16:32`; fork-21 matches
#       the clang/rust/zig trio's `v1:8:8-i128:128`)
#   (f) DWARF producer string + section sizes
#   (g) add_i32 codegen disasm — do both reach for compact .n forms now?
#   (h) ABI in the IR: both still emit byval/sret for aggregates (frontend behavior,
#       not backend) — proves runtime FAIL on point_dot/blob_sum is LDC-side.
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh

[ -x "$LDC2" ] || { echo "missing \$LDC2 (espressif fork) — run: ./scripts/setup.sh"; exit 1; }
[ -x "$LDC2_UPSTREAM" ] || { echo "missing \$LDC2_UPSTREAM — run: LDC_UPSTREAM=1 ./scripts/setup.sh"; exit 1; }

M=experiments/ffi-matrix; INC="$PWD/$M/include"; B=build/ldc-cmp; mkdir -p "$B"
LT="-mtriple=xtensa-esp-elf"
RT="$ESP_CLANG_DIR/../lib/clang-runtimes/xtensa-esp-unknown-elf/esp32/lib/libclang_rt.builtins.a"

echo "== (a) version + -mcpu=help =="
for tag in fork upstream; do
    [ "$tag" = fork ] && BIN=$LDC2 || BIN=$LDC2_UPSTREAM
    v=$("$BIN" --version 2>/dev/null | grep -oE 'based on DMD.*LLVM[^,]*' | head -1)
    cpus=$("$BIN" $LT -mcpu=help 2>&1 | grep -E '^\s+(esp|cnl|generic)' | awk '{print $1}' | tr '\n' ' ')
    printf "  %-8s %s\n           CPUs: %s\n" "$tag" "$v" "$cpus"
done

echo "== (b) -vv probe (user tip: ldc2 -betterC empty.d -o- -c -vv) =="
printf 'extern(C) void empty(){}\n' > "$B/empty.d"
for cpu in esp32 esp32s2 esp32s3; do
    for tag in fork upstream; do
        [ "$tag" = fork ] && BIN=$LDC2 || BIN=$LDC2_UPSTREAM
        line=$("$BIN" $LDC_PE -betterC -o- -c $LT -mcpu=$cpu -vv "$B/empty.d" 2>&1 | grep -E "(Targeting|not a recognized)" | head -2 | tr '\n' '|')
        printf "  %-8s -mcpu=%-8s %s\n" "$tag" "$cpu" "$line"
    done
done

echo "== (c) direct ldc2 -c -> ld.lld with the FFI linker script =="
for tag in fork upstream; do
    [ "$tag" = fork ] && BIN=$LDC2 || BIN=$LDC2_UPSTREAM
    out=$B/lib_d_$tag.o; err=$B/lib_d_$tag.err
    if ! "$BIN" $LT -mcpu=esp32 $LDC_PE -betterC -Os -c -of="$out" "$M/d/lib_d.d" 2>"$err"; then
        printf "  %-8s direct -c   FAILED (%s)\n" "$tag" "$(head -1 "$err")"
        continue
    fi
    # Provide the rest of the FFI matrix object set so ld.lld has a real graph.
    if $LLD -T "$M/xtensa.ld" -o "$B/ffi_$tag.elf" \
        build/xtensa-esp32/driver.o build/xtensa-esp32/entry.o \
        build/xtensa-esp32/lib_cpp.o build/xtensa-esp32/lib_zig.o \
        "$out" build/xtensa-esp32/lib_c_clang.o \
        --start-group build/xtensa-esp32/libffi_rs.a "$RT" --end-group 2>"$err"; then
        printf "  %-8s direct -c + ld.lld -T xtensa.ld: OK (.elf %s B, 0 undef)\n" "$tag" "$(stat -c%s "$B/ffi_$tag.elf")"
    else
        printf "  %-8s direct -c + ld.lld -T xtensa.ld: FAIL — %s\n" "$tag" \
            "$(grep -oiE 'not aligned to [0-9]+ bytes|out of range' "$err" | head -1)"
    fi
done

echo "== (d) -mcpu=esp32s2/s3 recognition (upstream: ldc #4919) =="
for cpu in esp32s2 esp32s3; do
    for tag in fork upstream; do
        [ "$tag" = fork ] && BIN=$LDC2 || BIN=$LDC2_UPSTREAM
        line=$("$BIN" $LT -mcpu=$cpu $LDC_PE -betterC -o- -c "$B/empty.d" 2>&1 | grep -E "not a recognized" | head -1)
        if [ -n "$line" ]; then printf "  %-8s -mcpu=%-8s REJECTED ('not a recognized processor')\n" "$tag" "$cpu"
        else printf "  %-8s -mcpu=%-8s accepted\n" "$tag" "$cpu"; fi
    done
done

echo "== (e) datalayout string parity =="
"$CLANG" --target=xtensa-esp-elf -mcpu=esp32 -ffreestanding -Os -S -emit-llvm -I"$INC" "$M/c/lib_c.c" -o "$B/lib_c.ll" 2>/dev/null
cdl=$(grep -oE 'target datalayout = "[^"]*"' "$B/lib_c.ll" | head -1 | sed -E 's/target datalayout = "([^"]*)"/\1/')
for tag in fork upstream; do
    [ "$tag" = fork ] && BIN=$LDC2 || BIN=$LDC2_UPSTREAM
    "$BIN" $LT -mcpu=esp32 $LDC_PE -betterC -Os -output-ll -of="$B/d_$tag.ll" "$M/d/lib_d.d" 2>/dev/null
    ddl=$(grep -oE 'target datalayout = "[^"]*"' "$B/d_$tag.ll" | head -1 | sed -E 's/target datalayout = "([^"]*)"/\1/')
    [ "$ddl" = "$cdl" ] && verdict="MATCHES clang" || verdict="DIFFERS"
    printf "  %-8s %s   [%s]\n" "$tag" "$ddl" "$verdict"
done
printf "  clang ref %s\n" "$cdl"

echo "== (f) DWARF: producer DIE + section sizes =="
for tag in fork upstream; do
    [ "$tag" = fork ] && BIN=$LDC2 || BIN=$LDC2_UPSTREAM
    # The upstream LDC produces post-18 IR that the host's LLVM-18 dwarfdump rejects;
    # use esp-clang's 21.1.3 binutils for both (it reads 21.x natively, and 22.x too).
    if [ "$tag" = fork ]; then
        "$BIN" $LT -mcpu=esp32 $LDC_PE -betterC -g -Os -c -of="$B/dbg_$tag.o" "$M/d/lib_d.d" 2>/dev/null
    else
        # Upstream LDC needs the re-assembly workaround for object emission.
        "$BIN" $LT -mcpu=esp32 $LDC_PE -betterC -g -Os -output-s -of="$B/dbg_$tag.s" "$M/d/lib_d.d" 2>/dev/null
        sed -E -i '/^[[:space:]]*\.cfi_/d' "$B/dbg_$tag.s"
        "$CLANG" --target=xtensa-esp-elf -mcpu=esp32 -c "$B/dbg_$tag.s" -o "$B/dbg_$tag.o" 2>/dev/null
    fi
    abbrev=$("$ESP_CLANG_DIR/llvm-readobj" --sections "$B/dbg_$tag.o" 2>/dev/null | awk '/Name: \.debug_abbrev/{f=1} f&&/Size:/{print $2;exit}')
    info=$(  "$ESP_CLANG_DIR/llvm-readobj" --sections "$B/dbg_$tag.o" 2>/dev/null | awk '/Name: \.debug_info /{f=1} f&&/Size:/{print $2;exit}')
    producer=$("$ESP_CLANG_DIR/llvm-dwarfdump" "$B/dbg_$tag.o" 2>/dev/null | grep -oE 'DW_AT_producer.*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"/\1/')
    printf "  %-8s producer: %s\n" "$tag" "${producer:-<not found>}"
    printf "           .debug_abbrev=%-4s .debug_info=%-4s\n" "${abbrev:-?}" "${info:-?}"
done

echo "== (g) add_i32 codegen (Os, esp32) =="
for tag in fork upstream; do
    [ "$tag" = fork ] && BIN=$LDC2 || BIN=$LDC2_UPSTREAM
    if [ "$tag" = fork ]; then
        "$BIN" $LT -mcpu=esp32 $LDC_PE -betterC -Os -c -of="$B/asm_$tag.o" "$M/d/lib_d.d" 2>/dev/null
    else
        "$BIN" $LT -mcpu=esp32 $LDC_PE -betterC -Os -output-s -of="$B/asm_$tag.s" "$M/d/lib_d.d" 2>/dev/null
        sed -E -i '/^[[:space:]]*\.cfi_/d' "$B/asm_$tag.s"
        "$CLANG" --target=xtensa-esp-elf -mcpu=esp32 -c "$B/asm_$tag.s" -o "$B/asm_$tag.o" 2>/dev/null
    fi
    bytes=$("$ESP_CLANG_DIR/llvm-objdump" -d --mcpu=esp32 --disassemble-symbols=d_add_i32 "$B/asm_$tag.o" 2>/dev/null | grep -cE '^\s*[0-9a-f]+:')
    has_n=$("$ESP_CLANG_DIR/llvm-objdump" -d --mcpu=esp32 --disassemble-symbols=d_add_i32 "$B/asm_$tag.o" 2>/dev/null | grep -coE '\b(add\.n|mov\.n|s32i\.n|l32i\.n|retw\.n)\b')
    printf "  %-8s d_add_i32 lines=%-2s compact-(.n) insns=%-2s\n" "$tag" "$bytes" "$has_n"
done

echo "== (h) IR struct ABI (frontend behavior — backend-independent) =="
for tag in fork upstream; do
    [ "$tag" = fork ] && BIN=$LDC2 || BIN=$LDC2_UPSTREAM
    "$BIN" $LT -mcpu=esp32 $LDC_PE -betterC -Os -output-ll -of="$B/abi_$tag.ll" "$M/d/lib_d.d" 2>/dev/null
    pd=$(grep -E 'define.*@d_point_dot\(' "$B/abi_$tag.ll" | grep -oE '\(.*\)' | head -1 \
        | sed -E 's/(noalias|writeonly|readonly|captures\([^)]*\)|initializes\([^)]*\)|align [0-9]+) //g; s/  +/ /g')
    bs=$(grep -E 'define.*@d_blob_sum\(' "$B/abi_$tag.ll" | grep -oE 'byval\([^)]*\)' | head -1)
    mp=$(grep -E 'define.*@d_make_point\(' "$B/abi_$tag.ll" | grep -oE 'sret\([^)]*\)' | head -1)
    printf "  %-8s d_point_dot: %s\n" "$tag" "$pd"
    printf "           d_blob_sum has %s; d_make_point has %s  -- frontend behavior, unchanged\n" "$bs" "$mp"
done
echo "  Runtime: both still FAIL d_point_dot + d_blob_sum on Xtensa (scripts/run-qemu.sh)."
echo "  D's by-value aggregate bug is in the LDC frontend, not the LLVM backend."
