#!/usr/bin/env bash
# run.sh - 5-frontend × N-ordering atomic memory-order parity battery on esp32.
#
# For each language, emit `atomic_store(*p, v, <order>)` and `atomic_load(*p,
# <order>)` for every memory ordering that language's atomic API supports, then
# disassemble and tally:
#   - memw       Xtensa "memory wait" fence (the only fence the LX6/LX7 ISA has)
#   - s32c1i     native CAS slot ("store 32-bit, conditional, 1-issue")
#   - l32ai/s32ri "acquire load" / "release store" — only on cores with the
#                Cache option; absent on esp32 (LX6) and -s2/-s3 (LX7)
#   - libcall    __atomic_load_*/__atomic_store_* fallback (heavyweight; pulls
#                in espressif/libatomic from libclang_rt.builtins.a)
#
# Subset by language (the atomic-stores axis has the most variation):
#   C / clang  __atomic_*       relaxed consume acquire release acq_rel seq_cst
#   Rust       Ordering          Relaxed       (Acquire-load only) Release           SeqCst
#   Zig        @atomicStore      unordered monotonic    release       seq_cst
#   D / LDC    ldc.intrinsics    Unordered Monotonic Acquire Release AcquireRelease SequentiallyConsistent
#
# Aim is not to spread the matrix wide; it's to pin which orderings actually
# lower to native esp32 instructions vs which fall through to the runtime
# libcalls — the rule of thumb for embedded designers.
#
# References: docs/02 (Xtensa atomics ISA), docs/17 §atomics (the original
# single-order probe).

set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh

D=experiments/atomics-orders; B=build/atomics-orders; mkdir -p "$B"
CT="--target=xtensa-esp-elf -mcpu=esp32"

mkdir -p "$B"

# ---------- C ----------
cat > "$B/a_c.c" <<'EOF'
typedef int i32;
void cs_relaxed(i32 *p, i32 v) { __atomic_store_n(p, v, __ATOMIC_RELAXED); }
void cs_release(i32 *p, i32 v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
void cs_seq_cst(i32 *p, i32 v) { __atomic_store_n(p, v, __ATOMIC_SEQ_CST); }
i32  cl_relaxed(i32 *p)        { return __atomic_load_n(p, __ATOMIC_RELAXED); }
i32  cl_acquire(i32 *p)        { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
i32  cl_seq_cst(i32 *p)        { return __atomic_load_n(p, __ATOMIC_SEQ_CST); }
EOF
"$CLANG" $CT -ffreestanding -Os -c "$B/a_c.c" -o "$B/a_c.o"

# ---------- Zig ----------
cat > "$B/a_zig.zig" <<'EOF'
export fn zs_unordered(p: *i32, v: i32) void { @atomicStore(i32, p, v, .unordered); }
export fn zs_monotonic(p: *i32, v: i32) void { @atomicStore(i32, p, v, .monotonic); }
export fn zs_release(p: *i32, v: i32)   void { @atomicStore(i32, p, v, .release);   }
export fn zs_seq_cst(p: *i32, v: i32)   void { @atomicStore(i32, p, v, .seq_cst);   }
export fn zl_unordered(p: *i32) i32 { return @atomicLoad(i32, p, .unordered); }
export fn zl_monotonic(p: *i32) i32 { return @atomicLoad(i32, p, .monotonic); }
export fn zl_acquire(p: *i32)   i32 { return @atomicLoad(i32, p, .acquire);   }
export fn zl_seq_cst(p: *i32)   i32 { return @atomicLoad(i32, p, .seq_cst);   }
EOF
"$ZIG" build-obj -target xtensa-freestanding-none -mcpu=esp32 -O ReleaseSmall \
    -femit-bin="$B/a_zig.o" "$B/a_zig.zig" 2>/dev/null

# ---------- D / LDC ----------
cat > "$B/a_d.d" <<'EOF'
// LDC's ldc.intrinsics.llvm_atomic_{store,load} signatures require `shared T*`
// — passing a plain `int*` silently lowers to a non-atomic store/load (no fence).
// Found while writing this battery: D's first-attempt non-shared call emitted
// zero memw across all orderings; switching to `shared int*` matches the trio.
import ldc.intrinsics;
extern(C) void ds_unordered(shared int* p, int v) { llvm_atomic_store!int(v, p, AtomicOrdering.Unordered); }
extern(C) void ds_monotonic(shared int* p, int v) { llvm_atomic_store!int(v, p, AtomicOrdering.Monotonic); }
extern(C) void ds_release(shared int* p, int v)   { llvm_atomic_store!int(v, p, AtomicOrdering.Release);   }
extern(C) void ds_seq_cst(shared int* p, int v)   { llvm_atomic_store!int(v, p, AtomicOrdering.SequentiallyConsistent); }
extern(C) int  dl_unordered(shared int* p) { return llvm_atomic_load!int(p, AtomicOrdering.Unordered); }
extern(C) int  dl_monotonic(shared int* p) { return llvm_atomic_load!int(p, AtomicOrdering.Monotonic); }
extern(C) int  dl_acquire(shared int* p)   { return llvm_atomic_load!int(p, AtomicOrdering.Acquire);   }
extern(C) int  dl_seq_cst(shared int* p)   { return llvm_atomic_load!int(p, AtomicOrdering.SequentiallyConsistent); }
EOF
# shellcheck disable=SC2046
"$LDC2" -mtriple=xtensa-esp-elf $(ldc_xtensa_flags esp32) -betterC -Os -c -of="$B/a_d.o" "$B/a_d.d" 2>/dev/null

# ---------- Rust ----------
mkdir -p "$B/a_rs/src"
cat > "$B/a_rs/Cargo.toml" <<'EOF'
[package]
name = "a_rs"
version = "0.0.1"
edition = "2021"
[lib]
crate-type = ["staticlib"]
[profile.release]
opt-level = "s"
panic = "abort"
EOF
cat > "$B/a_rs/src/lib.rs" <<'EOF'
#![no_std]
use core::sync::atomic::{AtomicI32, Ordering};
#[panic_handler] fn p(_: &core::panic::PanicInfo) -> ! { loop {} }
#[no_mangle] pub extern "C" fn rs_relaxed(p: &AtomicI32, v: i32) { p.store(v, Ordering::Relaxed); }
#[no_mangle] pub extern "C" fn rs_release(p: &AtomicI32, v: i32) { p.store(v, Ordering::Release); }
#[no_mangle] pub extern "C" fn rs_seq_cst(p: &AtomicI32, v: i32) { p.store(v, Ordering::SeqCst); }
#[no_mangle] pub extern "C" fn rl_relaxed(p: &AtomicI32) -> i32 { p.load(Ordering::Relaxed) }
#[no_mangle] pub extern "C" fn rl_acquire(p: &AtomicI32) -> i32 { p.load(Ordering::Acquire) }
#[no_mangle] pub extern "C" fn rl_seq_cst(p: &AtomicI32) -> i32 { p.load(Ordering::SeqCst) }
EOF
( cd "$B/a_rs" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core \
    --target xtensa-esp32-none-elf >/dev/null 2>&1 )
cp "$B/a_rs/target/xtensa-esp32-none-elf/release/liba_rs.a" "$B/a_rs.a"

# ---------- inspect: per-fn count of (memw, s32c1i, libcall) ----------
count_in_obj() { # obj fn pattern
    "$ESP_CLANG_DIR/llvm-objdump" -d --mcpu=esp32 --disassemble-symbols="$2" "$1" 2>/dev/null \
        | grep -cE "$3" || true
}
libcall_in_obj() { # obj fn -> count of `__atomic_*` references in any disasm form
    "$ESP_CLANG_DIR/llvm-objdump" -d -r --mcpu=esp32 --disassemble-symbols="$2" "$1" 2>/dev/null \
        | grep -cE '__atomic_(load|store|fetch|compare)_' || true
}
emit_row() { # label fn obj
    local lbl=$1 fn=$2 obj=$3
    local memw scd lib
    memw=$(count_in_obj   "$obj" "$fn" '^\s*[0-9a-f]+:[^\n]*\bmemw\b')
    scd=$(count_in_obj    "$obj" "$fn" '^\s*[0-9a-f]+:[^\n]*\b(s32c1i|l32ai|s32ri)\b')
    lib=$(libcall_in_obj  "$obj" "$fn")
    printf "  %-18s memw=%d  s32c1i/l32ai/s32ri=%d  __atomic_*=%d\n" "$lbl" "$memw" "$scd" "$lib"
}

echo "== STORES — esp32 atomic_store(i32*, i32, <order>) =="
echo "  language    ordering         emitted"
echo "  --------    --------         -------"
emit_row "C   relaxed " cs_relaxed "$B/a_c.o"
emit_row "C   release " cs_release "$B/a_c.o"
emit_row "C   seq_cst " cs_seq_cst "$B/a_c.o"
emit_row "Rust Relaxed" rs_relaxed "$B/a_rs.a"
emit_row "Rust Release" rs_release "$B/a_rs.a"
emit_row "Rust SeqCst " rs_seq_cst "$B/a_rs.a"
emit_row "Zig unordered" zs_unordered "$B/a_zig.o"
emit_row "Zig monotonic" zs_monotonic "$B/a_zig.o"
emit_row "Zig release "  zs_release   "$B/a_zig.o"
emit_row "Zig seq_cst "  zs_seq_cst   "$B/a_zig.o"
emit_row "D   Unordered" ds_unordered "$B/a_d.o"
emit_row "D   Monotonic" ds_monotonic "$B/a_d.o"
emit_row "D   Release  " ds_release   "$B/a_d.o"
emit_row "D   SeqCst   " ds_seq_cst   "$B/a_d.o"

echo
echo "== LOADS — esp32 atomic_load(i32*, <order>) =="
echo "  language    ordering         emitted"
echo "  --------    --------         -------"
emit_row "C   relaxed " cl_relaxed "$B/a_c.o"
emit_row "C   acquire " cl_acquire "$B/a_c.o"
emit_row "C   seq_cst " cl_seq_cst "$B/a_c.o"
emit_row "Rust Relaxed" rl_relaxed "$B/a_rs.a"
emit_row "Rust Acquire" rl_acquire "$B/a_rs.a"
emit_row "Rust SeqCst " rl_seq_cst "$B/a_rs.a"
emit_row "Zig unordered" zl_unordered "$B/a_zig.o"
emit_row "Zig monotonic" zl_monotonic "$B/a_zig.o"
emit_row "Zig acquire " zl_acquire   "$B/a_zig.o"
emit_row "Zig seq_cst " zl_seq_cst   "$B/a_zig.o"
emit_row "D   Unordered" dl_unordered "$B/a_d.o"
emit_row "D   Monotonic" dl_monotonic "$B/a_d.o"
emit_row "D   Acquire  " dl_acquire   "$B/a_d.o"
emit_row "D   SeqCst   " dl_seq_cst   "$B/a_d.o"

echo
echo "== Interpretation =="
echo "  esp32 (LX6) has memw (fence) and s32c1i (CAS) but NO l32ai/s32ri (acquire-load/"
echo "  release-store — those need the Cache option, absent on LX6 and LX7). All 4 LLVM"
echo "  frontends emit memw-bracketed plain l32i/s32i for release+seq_cst, and a bare"
echo "  l32i/s32i for relaxed/unordered/monotonic — no __atomic_* libcall on i32 stores,"
echo "  matching the docs/17 §atomics finding. The s32c1i column is 0 for stores/loads"
echo "  (only RMW ops use it); see experiments/rust-zig for the rs_atomic_cas/rs_atomic_add"
echo "  case where rust/zig/d all emit exactly one s32c1i with native fences."
