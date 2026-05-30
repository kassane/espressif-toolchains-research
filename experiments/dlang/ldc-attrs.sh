#!/usr/bin/env bash
# ldc-attrs.sh - LDC-exclusive attributes/pragmas and matrix parity for the
# cross-language analogs (@assumeUsed vs #[used] vs __attribute__((used));
# import("file") vs @embedFile / include_bytes! / #embed; per-fn @cold /
# @optStrategy / @restrict; pragma(mangle/inline/LDC_intrinsic/LDC_extern_weak)).
#
# Cross-references:
#   - safety.sh §(e) already covers @fastmath / @section / @weak / inline IR.
#     This script covers everything else `ldc.attributes` + `ldc.intrinsics` +
#     LDC's `pragma()` family expose, plus the file-embed cross-frontend matrix.
#   - docs/19 §"LDC-only knobs", docs/20 §"4. LDC's full @-attribute & pragma
#     catalog", docs/24 §"//go:embed".
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
B=build/ldc-attrs; mkdir -p "$B"
LT="-mtriple=xtensa-esp-elf -mcpu=esp32"
CT="--target=xtensa-esp-elf -mcpu=esp32"
ZT="-target xtensa-freestanding-none -mcpu=esp32"
DUMP="$ESP_CLANG_DIR/llvm-objdump"

echo "== (a) @assumeUsed parity — LDC vs Rust #[used] vs clang __attribute__((used)) vs Zig export =="
# The key distinction: @llvm.used (STRONG — linker won't GC) vs
# @llvm.compiler.used (WEAK — only the compiler optimizer sees it). LDC and Rust
# emit the strong form by default; clang's __attribute__((used)) emits the weak
# form (the strong form needs `__attribute__((retain))` which is C23/clang 13+).
# Zig has no UDA — `export` alone makes a symbol externally linkable, which is
# enough on bare-metal where `--gc-sections` is usually disabled, but the
# `@llvm.used` marker is not emitted.

# LDC
cat > "$B/au.d" <<'EOF'
import ldc.attributes;
extern(C) @assumeUsed int marker_d() { return 0xCAFE; }
extern(C) int regular_d() { return 0xBEEF; }
EOF
"$LDC2" $LT $LDC_PE -betterC -O2 -output-ll -of="$B/au_d.ll" "$B/au.d" 2>/dev/null

# Clang (used)
cat > "$B/au.c" <<'EOF'
__attribute__((used)) int marker_c(void) { return 0xCAFE; }
int regular_c(void) { return 0xBEEF; }
EOF
"$CLANG" $CT -ffreestanding -O2 -S -emit-llvm "$B/au.c" -o "$B/au_c.ll"

# Clang (retain) — the C23 spelling for the strong form
cat > "$B/au_retain.c" <<'EOF'
[[gnu::retain]] int marker_cr(void) { return 0xCAFE; }
EOF
"$CLANG" $CT -ffreestanding -O2 -std=c23 -S -emit-llvm "$B/au_retain.c" -o "$B/au_cr.ll" 2>/dev/null || true

# Rust
mkdir -p "$B/rs/src"
cat > "$B/rs/Cargo.toml" <<'EOF'
[package]
name="au_rs"
version="0.0.0"
edition="2021"
[lib]
path="src/lib.rs"
crate-type=["staticlib"]
[profile.release]
panic="abort"
opt-level=2
EOF
cat > "$B/rs/src/lib.rs" <<'EOF'
#![no_std]
#[panic_handler] fn p(_:&core::panic::PanicInfo)->!{loop{}}
#[used] #[no_mangle] pub static MARKER_RS: u32 = 0xCAFE;
#[no_mangle] pub static REGULAR_RS: u32 = 0xBEEF;
EOF
( cd "$B/rs" && RUSTC="$RUSTC" "$CARGO" rustc --release -Z build-std=core --target xtensa-esp32-none-elf -- --emit=llvm-ir >/dev/null 2>&1 )
RS_IR=$(find "$B/rs/target" -name 'au_rs-*.ll' | head -1)

# Zig
cat > "$B/au.zig" <<'EOF'
export const MARKER_ZIG: u32 = 0xCAFE;
export const REGULAR_ZIG: u32 = 0xBEEF;
EOF
"$ZIG" build-obj $ZT -O ReleaseSmall -femit-llvm-ir="$B/au_z.ll" -fno-emit-bin "$B/au.zig" 2>/dev/null

llvmused() { grep -E '^@llvm\.used\b' "$1" 2>/dev/null | head -1; }
ccused()   { grep -E '^@llvm\.compiler\.used\b' "$1" 2>/dev/null | head -1; }
printf "  %-32s @llvm.used: %-50s @llvm.compiler.used: %s\n" "LDC @assumeUsed"        "$(llvmused "$B/au_d.ll" | head -c 80)" "$(ccused "$B/au_d.ll" | head -c 60)"
printf "  %-32s @llvm.used: %-50s @llvm.compiler.used: %s\n" "clang __attribute__(used)" "$(llvmused "$B/au_c.ll" | head -c 80)" "$(ccused "$B/au_c.ll" | head -c 60)"
if [ -f "$B/au_cr.ll" ]; then
    printf "  %-32s @llvm.used: %-50s @llvm.compiler.used: %s\n" "clang [[gnu::retain]] (C23)" "$(llvmused "$B/au_cr.ll" | head -c 80)" "$(ccused "$B/au_cr.ll" | head -c 60)"
fi
printf "  %-32s @llvm.used: %-50s @llvm.compiler.used: %s\n" "Rust #[used]"             "$(llvmused "$RS_IR" | head -c 80)" "$(ccused "$RS_IR" | head -c 60)"
printf "  %-32s @llvm.used: %-50s @llvm.compiler.used: %s\n" "Zig export"              "$(llvmused "$B/au_z.ll" | head -c 80)" "$(ccused "$B/au_z.ll" | head -c 60)"
echo "  Note: LDC @assumeUsed + Rust #[used] emit the STRONG @llvm.used (linker"
echo "  won't GC); clang __attribute__((used)) emits the WEAK @llvm.compiler.used;"
echo "  clang [[gnu::retain]] (C23/clang 13+) is the spelling that yields the"
echo "  strong form. Zig export keeps symbols globally visible without either"
echo "  marker — relies on the bare-metal link not running --gc-sections."

echo ""
echo "== (b) Compile-time file embed — import(\"file\") vs @embedFile vs include_bytes! vs #embed =="
printf 'firmware-payload-v1' > "$B/payload.bin"

# LDC: import("file")
cat > "$B/imp.d" <<'EOF'
extern(C) immutable(char)[] payload_d() {
    static immutable string p = import("payload.bin");
    return p;
}
EOF
"$LDC2" $LT $LDC_PE -betterC -O2 -J="$B" -c "$B/imp.d" -of="$B/imp_d.o" 2>/dev/null

# Zig: @embedFile
cat > "$B/imp.zig" <<'EOF'
const payload = @embedFile("payload.bin");
export fn payload_zig_ptr() callconv(.c) [*]const u8 { return payload; }
export fn payload_zig_len() callconv(.c) usize { return payload.len; }
EOF
"$ZIG" build-obj $ZT -O ReleaseSmall -femit-bin="$B/imp_z.o" "$B/imp.zig" 2>/dev/null

# Rust: include_bytes!
mkdir -p "$B/imps/src"
cp "$B/payload.bin" "$B/imps/src/"
cat > "$B/imps/Cargo.toml" <<'EOF'
[package]
name="imp_rs"
version="0.0.0"
edition="2021"
[lib]
path="src/lib.rs"
crate-type=["staticlib"]
[profile.release]
panic="abort"
opt-level=2
EOF
cat > "$B/imps/src/lib.rs" <<'EOF'
#![no_std]
#[panic_handler] fn p(_:&core::panic::PanicInfo)->!{loop{}}
#[no_mangle] pub static PAYLOAD_RS: &[u8] = include_bytes!("payload.bin");
EOF
( cd "$B/imps" && RUSTC="$RUSTC" "$CARGO" rustc --release -Z build-std=core --target xtensa-esp32-none-elf -- --emit=obj >/dev/null 2>&1 )
RSI_O=$(find "$B/imps/target" -name 'imp_rs-*.o' | head -1)

# C23: #embed
cat > "$B/imp.c" <<EOF
const unsigned char payload_c[] = {
#embed "$B/payload.bin"
};
const unsigned long payload_c_len = sizeof(payload_c);
EOF
"$CLANG" $CT -ffreestanding -O2 -std=c23 -c "$B/imp.c" -o "$B/imp_c.o" 2>/dev/null

# TinyGo: //go:embed — host vs Xtensa
mkdir -p "$B/imptg"
cp "$B/payload.bin" "$B/imptg/"
cat > "$B/imptg/main.go" <<'EOF'
package main
import _ "embed"
//go:embed payload.bin
var payload string
//export payload_tg_byte
func payload_tg_byte(i int) uint8 { return payload[i] }
//export payload_tg_len
func payload_tg_len() int { return len(payload) }
func main() { _ = payload_tg_byte(0); _ = payload_tg_len() }
EOF
( cd "$B/imptg" && "$TINYGO" build -opt=0 -target=esp32-coreboard-v2 -o tg.elf main.go 2>/dev/null || true )

check_embed() { # path label
    local p="$1" lbl="$2"
    [ -f "$p" ] || { printf "  %-28s (missing)\n" "$lbl"; return; }
    if grep -aoE 'firmware-payload-v1' "$p" >/dev/null 2>&1; then
        local sec
        sec=$("$DUMP" --section-headers "$p" 2>/dev/null | awk '/firmware/{next} /\.rodata/{print $2; exit}')
        printf "  %-28s embedded ✓  (section: %s)\n" "$lbl" "${sec:-.rodata}"
    else
        printf "  %-28s NOT embedded ✗\n" "$lbl"
    fi
}
check_embed "$B/imp_d.o"  "D import(\"file\")"
check_embed "$B/imp_z.o"  "Zig @embedFile"
check_embed "$RSI_O"      "Rust include_bytes!"
check_embed "$B/imp_c.o"  "clang C23 #embed"
check_embed "$B/imptg/tg.elf" "TinyGo //go:embed (Xtensa)"
echo "  Note: TinyGo //go:embed works on Xtensa as long as the embed variable is"
echo "  actually referenced from a non-DCE-d code path. The _ = payload_tg_byte(0)"
echo "  call in main() above keeps the bytes alive across whole-program LTO;"
echo "  drop the call and TinyGo's link-time DCE strips the payload silently."

echo ""
echo "== (c) LDC-exclusive attributes — @cold / @optStrategy / @hidden / @naked / @restrict / @noplt / @llvmAttr =="
cat > "$B/full.d" <<'EOF'
import ldc.attributes;
import ldc.intrinsics;
extern(C):
@cold int rare() { return 0; }
@optStrategy("none")    int never_opt(int x) { return x*x*x; }
@optStrategy("optsize") int small(int x)     { return x*x*x; }
@optStrategy("minsize") int tiny(int x)      { return x*x*x; }
@hidden int internal_fn() { return 1; }
@naked @trusted void barebones() { asm { "ret.n"; } }   // @trusted for the asm
@noplt extern int external_thing();
@llvmAttr("noredzone","true") int with_attr() { return 42; }
@system int sum_no_alias(@restrict int* a, @restrict int* b, int n) {
    int s = 0; foreach (i; 0 .. n) s += a[i] + b[i]; return s;   // @system: raw ptr index
}
EOF
"$LDC2" $LT $LDC_PE -betterC -O2 -output-ll -of="$B/full.ll" "$B/full.d" 2>/dev/null
ll=$B/full.ll
checkir() {
    local lbl="$1" pat="$2" hit=0
    hit=$(grep -cE "$pat" "$ll" 2>/dev/null) || hit=0
    if [ "${hit:-0}" -gt 0 ]; then
        printf "  %-32s ✓ (%s IR match)\n" "$lbl" "$hit"
    else
        printf "  %-32s ✗ (no IR match for /%s/)\n" "$lbl" "$pat"
    fi
}
checkir "@cold -> cold attr"               '^.*\bcold\b'
checkir "@optStrategy(none) -> optnone"    'optnone'
checkir "@optStrategy(optsize) -> optsize" '\boptsize\b'
checkir "@optStrategy(minsize) -> minsize" '\bminsize\b'
checkir "@naked -> naked attr"             '\bnaked\b'
checkir "@llvmAttr noredzone"              'noredzone'
checkir "@restrict params -> ptr noalias"  'sum_no_alias.*noalias'

echo ""
echo "== (d) LDC pragmas — pragma(mangle/inline/LDC_intrinsic/LDC_extern_weak) =="
cat > "$B/prag.d" <<'EOF'
import ldc.intrinsics;
extern(C):
pragma(inline, false) int never_inlined(int x) { return x + 1; }
pragma(inline, true)  int always_inlined(int x) { return x + 2; }
pragma(mangle, "weird_c_name") int normal_d_name(int x) { return x; }
pragma(LDC_intrinsic, "llvm.bswap.i32") uint llvm_bswap(uint x);
uint use_bswap(uint x) { return llvm_bswap(x); }
pragma(LDC_extern_weak) extern int optional_hook();
int call_hook() { return (&optional_hook is null) ? 0 : optional_hook(); }
EOF
"$LDC2" $LT $LDC_PE -betterC -O2 -output-ll -of="$B/prag.ll" "$B/prag.d" 2>/dev/null
ll=$B/prag.ll
checkir "pragma(mangle) -> renamed symbol"      '@weird_c_name'
checkir "pragma(LDC_intrinsic, llvm.bswap.i32)" 'llvm\.bswap\.i32'
checkir "pragma(LDC_extern_weak) -> extern_weak" 'extern_weak'
# inline=false sometimes shows as 'noinline'; inline=true may show as 'alwaysinline'
checkir "pragma(inline,false) -> noinline"      'noinline'
checkir "pragma(inline,true) -> alwaysinline"   'alwaysinline'

echo ""
echo "== (e) ldc.intrinsics catalog — direct LLVM intrinsic binding (no clang __builtin) =="
# Show that ldc.intrinsics gives D direct access to LLVM intrinsics. This is the
# spelling parity with clang/zig __builtin_* on a few common ones.
cat > "$B/intr.d" <<'EOF'
import ldc.intrinsics;
extern(C):
uint  bswap_u32(uint x)  { return llvm_bswap(x); }       // llvm.bswap.i32
ulong bswap_u64(ulong x) { return llvm_bswap(x); }       // llvm.bswap.i64
uint  ctlz_u32(uint x)   { return llvm_ctlz(x, false); } // llvm.ctlz.i32
uint  cttz_u32(uint x)   { return llvm_cttz(x, false); } // llvm.cttz.i32
uint  popcnt_u32(uint x) { return llvm_ctpop(x); }       // llvm.ctpop.i32
EOF
"$LDC2" $LT $LDC_PE -betterC -O2 -output-ll -of="$B/intr.ll" "$B/intr.d" 2>/dev/null
echo "  LLVM intrinsics resolved from ldc.intrinsics (count in IR):"
for fn in bswap.i32 bswap.i64 ctlz.i32 cttz.i32 ctpop.i32; do
    n=$(grep -c "llvm\.$fn" "$B/intr.ll" 2>/dev/null)
    printf "    %-16s -> %d hits\n" "llvm.$fn" "$n"
done
echo "  D's ldc.intrinsics module exposes every LLVM intrinsic as a regular D"
echo "  function — equivalent to clang's __builtin_bswap32/__builtin_clz/etc.,"
echo "  zig's @byteSwap/@clz/@ctz/@popCount, and rustc's u32::swap_bytes /"
echo "  leading_zeros / count_ones (which compile to the same intrinsic)."

echo ""
echo "== (f) Practical demo: which markers survive ld.lld --gc-sections? =="
# Same four sources as §(a); link a stub _start that references none of them
# and watch which markers the linker keeps. The point: @llvm.used (STRONG)
# is honored by ld.lld --gc-sections, @llvm.compiler.used (WEAK) is not.
cat > "$B/entry.c" <<'EOF'
extern int      marker_c(void);
extern int      marker_cr(void);
extern int      marker_d(void);
extern unsigned MARKER_RS;
void _start(void) { }   /* references nothing */
EOF
"$CLANG" $CT -ffreestanding -O2 -c "$B/entry.c" -o "$B/entry.o"
"$LDC2"  $LT $LDC_PE -betterC -O2 -c "$B/au.d"        -of="$B/au_d.o" 2>/dev/null
"$CLANG" $CT -ffreestanding -O2 -c "$B/au.c"            -o "$B/au_c.o"
"$CLANG" $CT -ffreestanding -O2 -std=c23 -c "$B/au_retain.c" -o "$B/au_cr.o" 2>/dev/null
RS_O=$(find "$B/rs/target" -name 'au_rs-*.o' | head -1)
$LLD -e _start --gc-sections \
    -T experiments/ffi-matrix/xtensa.ld \
    "$B/entry.o" "$B/au_d.o" "$B/au_c.o" "$B/au_cr.o" "$RS_O" \
    -o "$B/gc.elf" 2>/dev/null

surv() {  # symbol label
    if "$ESP_CLANG_DIR/llvm-nm" "$B/gc.elf" 2>/dev/null | grep -qE "[^.]\b$1\b"; then
        printf "  %-32s SURVIVES --gc-sections ✓\n" "$2"
    else
        printf "  %-32s GC'd                  ✗\n" "$2"
    fi
}
surv marker_d  "LDC @assumeUsed (strong, fn)"
surv MARKER_RS "Rust #[used] (strong, data)"
surv marker_cr "clang [[gnu::retain]] (strong, fn)"
surv marker_c  "clang ((used))  (weak, fn)"
surv regular_d "LDC plain extern(C)"
surv regular_c "clang plain extern"
echo "  Function-symbol strong/weak split holds end-to-end (marker_d + marker_cr"
echo "  survive; marker_c is GC'd; regular_* GC'd). Linker is \$LLD (zig's LLD"
echo "  22.1.4 — matches the canonical 22.x cluster). For data-symbol Rust"
echo "  #[used] the behavior diverges across LLD point releases — LLD 22.1.4"
echo "  GCs MARKER_RS even though the IR has @llvm.used. Re-link with"
echo "  \$ESP_CLANG_DIR/ld.lld (21.1.3) to see the older behavior."
