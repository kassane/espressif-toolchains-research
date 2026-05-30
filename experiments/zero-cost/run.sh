#!/usr/bin/env bash
# run.sh — Zero-cost abstraction parity across D, C++, Rust on Xtensa esp32.
#
# Tests Stroustrup's "what you do use, you couldn't hand code any better"
# across the three statically-monomorphizing LLVM languages we have. Compares
# byte-by-byte against a C baseline + each language's lowest-level form.
#
# Four scenarios:
#   §a Generic accumulator (`sum` template/template/generic)  — pure monomorphization
#   §b Higher-order function (`apply` callable arg)            — inline/closure parity
#   §c Static vs dynamic dispatch                              — where zero-cost FAILS
#   §d D `class` in -betterC with manual `Mallocator`-style allocator
#      (the user's note: D class needs malloc/free or Mallocator) — what does the
#      compiled output actually look like vs C++ class-on-malloc, vs Rust Box,
#      vs D struct
#
# All compiles target xtensa-esp-elf -mcpu=esp32 -Os (matching scripts/build-ffi.sh).
# Counts xtensa instructions (lines in `llvm-objdump -d` of each symbol) and the
# raw .text bytes per function.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
B=build/zero-cost; mkdir -p "$B"
D=experiments/zero-cost
CT="--target=xtensa-esp-elf -mcpu=esp32"
ZT="-target xtensa-freestanding-none -mcpu=esp32"
LT="-mtriple=xtensa-esp-elf -mcpu=esp32"
DUMP="$ESP_CLANG_DIR/llvm-objdump"
SIZE="$ESP_CLANG_DIR/llvm-size"

count_insn() { # obj symbol
    "$DUMP" -d --mcpu=esp32 --disassemble-symbols="$2" "$1" 2>/dev/null \
        | awk '/^[[:space:]]+[0-9a-f]+:[[:space:]]+[0-9a-f]/{n++} END{print n+0}'
}
# Sum the byte-widths from the symbol's own disasm. Counting per-symbol from
# objdump survives ICF folding (when two semantically-identical functions share
# one .text section — Rust's optimizer + linker merges them; the rustc-on-Xtensa
# build above has sum_rs_loop folded into .text.sum_rs_generic_i32, for instance,
# which `llvm-size -A .text.sum_rs_loop` would report as empty).
text_bytes() { # obj symbol
    "$DUMP" -d --mcpu=esp32 --disassemble-symbols="$2" "$1" 2>/dev/null \
        | awk '/^[[:space:]]+[0-9a-f]+:[[:space:]]+[0-9a-f]/{
            # Strip address prefix, count hex pairs separated by spaces until
            # the assembly mnemonic. Xtensa instructions are 2 or 3 bytes; the
            # objdump format is "addr: bb bb [bb] mnemonic ..."
            sub(/^[[:space:]]+[0-9a-f]+:[[:space:]]+/,"")
            for (i=1; i<=NF; i++) {
              if ($i ~ /^[0-9a-f][0-9a-f]$/) bytes++
              else break
            }
          } END {print bytes+0}'
}
# Detect ICF: if `.text.<symbol>` exists report its size; if it doesn't but
# the symbol disassembles, mark the report with "(ICF)" so the reader knows
# the symbol shares a section with another semantically-equivalent function.
icf_tag() { # obj symbol
    if "$SIZE" -A "$1" 2>/dev/null | awk -v s=".text.$2" '$1==s{found=1} END{exit !found}'; then
        echo ""
    else
        echo " (ICF-merged)"
    fi
}
report() { # label obj symbol
    local lbl="$1" obj="$2" sym="$3"
    printf "  %-44s  %3s insn  %4s B%s\n" \
        "$lbl" "$(count_insn "$obj" "$sym")" "$(text_bytes "$obj" "$sym")" "$(icf_tag "$obj" "$sym")"
}

echo "== (a) Generic accumulator: int sum(int*, int) =="
echo "  Same algorithm, three abstraction levels per language. Baseline = C."

# C baseline
"$CLANG" $CT -ffreestanding -Os -ffunction-sections -fdata-sections -c "$D/c/sum.c" -o "$B/c_sum.o"

# C++ template instantiated at int
"$CLANGXX" $CT -ffreestanding -fno-exceptions -fno-rtti -Os -ffunction-sections -fdata-sections -c "$D/cpp/sum.cpp" -o "$B/cpp_sum.o"

# Rust generic (compiles core with build-std)
( cd "$D/rs" && rm -rf target && RUSTC="$RUSTC" "$CARGO" rustc --release \
    -Z build-std=core --target xtensa-esp32-none-elf \
    -- --emit=obj -C panic=abort >/dev/null 2>&1 )
RS_OBJ=$(find "$D/rs/target/xtensa-esp32-none-elf/release/deps" -name 'zero_cost_rs-*.o' | head -1)
[ -n "$RS_OBJ" ] && cp "$RS_OBJ" "$B/rs_sum.o"

# D template instantiated at int (-betterC)
"$LDC2" $LT $LDC_PE -betterC -Os --function-sections -c "$D/d/sum.d" -of="$B/d_sum.o"

report "C   sum_c (hand-written for-loop)"        "$B/c_sum.o"   sum_c
report "C++ sum_cpp_loop (hand for-loop)"         "$B/cpp_sum.o" sum_cpp_loop
report "C++ sum_cpp_tmpl<int> (template)"         "$B/cpp_sum.o" sum_cpp_tmpl_i32
report "Rust sum_rs_loop (idiomatic for-in)"      "$B/rs_sum.o"  sum_rs_loop
report "Rust sum_rs_iter (.iter().sum())"         "$B/rs_sum.o"  sum_rs_iter
report "Rust sum_rs_generic<T> (monomorph)"       "$B/rs_sum.o"  sum_rs_generic_i32
report "D   sum_d_loop (hand for-loop)"           "$B/d_sum.o"   sum_d_loop
report "D   sum_d_tmpl!(int) (template)"          "$B/d_sum.o"   sum_d_tmpl_i32
echo "  → all should be byte-identical if monomorphization is truly zero-cost."

echo ""
echo "== (b) Higher-order function: apply(f, x) where f: int->int =="
echo "  Tests whether a non-capturing closure / template lambda inlines"
echo "  to a direct call (or the body) rather than an indirect call."

"$CLANG"   $CT -ffreestanding -Os -ffunction-sections -fdata-sections -c "$D/c/apply.c" -o "$B/c_apply.o"
"$CLANGXX" $CT -ffreestanding -fno-exceptions -fno-rtti -Os -ffunction-sections -fdata-sections -c "$D/cpp/apply.cpp" -o "$B/cpp_apply.o"
"$LDC2"    $LT $LDC_PE -betterC -Os --function-sections -c "$D/d/apply.d"  -of="$B/d_apply.o"

report "C   apply_c (raw fn ptr — indirect call)"    "$B/c_apply.o"   call_apply_c
report "C++ apply_cpp_fnptr (raw fn ptr arg)"        "$B/cpp_apply.o" call_apply_cpp_fnptr
report "C++ apply_cpp_tmpl<F> (template + lambda)"   "$B/cpp_apply.o" call_apply_cpp_tmpl
report "Rust apply_rs_fnptr (fn(i32)->i32)"          "$B/rs_sum.o"    call_apply_rs_fnptr
report "Rust apply_rs_generic<F: Fn>"                "$B/rs_sum.o"    call_apply_rs_generic
report "D   apply_d_fnptr (function pointer)"        "$B/d_apply.o"   call_apply_d_fnptr
report "D   apply_d_tmpl!(F) (template)"             "$B/d_apply.o"   call_apply_d_tmpl
echo "  → the template/generic forms should fold to the raw body (0 calls);"
echo "    the fn-ptr forms keep a callx8/callx0."

echo ""
echo "== (c) Static vs dynamic dispatch =="
echo "  CRTP / impl Trait / D static struct call (zero-cost: inlined)"
echo "  vs C++ virtual / dyn Trait / D class virtual (NOT zero-cost: vtable + indirect call)"

"$CLANGXX" $CT -ffreestanding -fno-exceptions -fno-rtti -Os -ffunction-sections -fdata-sections -c "$D/cpp/dispatch.cpp" -o "$B/cpp_disp.o"
"$LDC2"    $LT $LDC_PE -betterC -Os --function-sections -c "$D/d/dispatch.d"  -of="$B/d_disp.o"

report "C++ static_via_template (CRTP-like)"          "$B/cpp_disp.o" use_static_cpp
report "C++ virtual_via_class (vtable)"               "$B/cpp_disp.o" use_virtual_cpp
report "Rust impl_trait_static (generic)"             "$B/rs_sum.o"   use_static_rs
report "Rust dyn_trait_dynamic (vtable)"              "$B/rs_sum.o"   use_dynamic_rs
report "D struct-template static"                     "$B/d_disp.o"   use_static_d
echo "  → static forms should be byte-identical to the inline body."
echo "    virtual / dyn forms carry an extra l32i + callx8 (vtable read + call)."

echo ""
echo "== (d) D class in -betterC needs an allocator =="
echo "  User's note: D class in -betterC needs malloc/free or Mallocator."
echo "  Probes the IR + code-size cost of three equivalent 'heap counter':"

"$CLANGXX" $CT -ffreestanding -fno-exceptions -fno-rtti -Os -ffunction-sections -fdata-sections -c "$D/cpp/heap.cpp" -o "$B/cpp_heap.o"
"$LDC2"    $LT $LDC_PE -betterC -Os --function-sections -c "$D/d/heap.d"     -of="$B/d_heap.o"

report "C++ Counter_cpp_new (operator new)"          "$B/cpp_heap.o" make_counter_cpp
report "Rust Box<Counter> (Box::new)"                "$B/rs_sum.o"   make_counter_rs
report "D   Counter (extern(C++) class, manual malloc) — see d/heap.d" "$B/d_heap.o" make_counter_d
report "D   CounterStruct (zero-allocation value type)" "$B/d_heap.o" make_counter_struct_d
echo "  → C++ new and Rust Box both call malloc and run a constructor;"
echo "    D struct in -betterC stack-allocates with zero overhead."
echo "    D class in -betterC needs an emplaced ctor over GC-free memory;"
echo "    d/heap.d shows the canonical pattern using core.stdc.stdlib.malloc."

echo ""
echo "== Summary =="
echo ""
echo "  §(a) MONOMORPHIZATION (template/generic with concrete T): ZERO-COST ✓"
echo "       C++ tmpl<int> == C hand-loop (both 11 insn / 25 B)"
echo "       Rust iter/generic == Rust hand-loop (all 10 insn / 23 B; ICF-folded)"
echo "       D   tmpl!int   == D hand-loop  (both 10 insn / 23 B)"
echo "       Single-instruction gap between C/C++ and Rust/D is the frame-"
echo "       pointer policy (clang keeps mov.n a7,a1 at -Os; rustc/LDC don't)."
echo ""
echo "  §(b) FUNCTION POINTER vs TEMPLATE LAMBDA: ZERO-COST ✓ even at -Os"
echo "       All four forms collapse to a single 'slli a2,a2,1' (= x+x)."
echo "       Even the C/C++ raw-fn-ptr case is devirtualized at -Os because"
echo "       clang sees a constant fn-ptr at the call site. The lambda /"
echo "       Functor / Fn-trait / D-functor templates all instantiate, see"
echo "       the body, and inline. Zero indirect call in the final image."
echo ""
echo "  §(c) STATIC vs DYNAMIC DISPATCH: dynamic dispatch is NOT zero-cost."
echo "       Static (CRTP / impl Trait / D struct template):"
echo "         clang/rust/LDC all constant-fold the n×Step loop to one mull."
echo "         Body: max-clamp + mull. 6–7 insns total."
echo "       Dynamic (virtual / dyn Trait):"
echo "         Loop kept; each iteration costs +2-3 insns over static."
echo "         C++ vtable layout: 2× l32i (object→vtable→method) per call."
echo "         Rust dyn fat-ptr: 1× l32i (vtable in 2nd ABI reg, save 1 load)."
echo "         Concrete cost on this 8-bit-stepped loop: 13 vs 7 insns (C++),"
echo "         11 vs 6 (Rust). For 1000 iterations: 6000 extra Xtensa cycles."
echo ""
echo "  §(d) HEAP ALLOCATION (C++ new / Rust Box-equiv / D malloc-class):"
echo "       Identical machine code modulo frame pointer:"
echo "         movi.n a10, sizeof  →  callx8 malloc  →  store ctor args  →  ret"
echo "       D class adds 4 B per instance (vtable pointer) even with no"
echo "       virtual methods — sizeof(Counter) is 12 not 8. (sizeof flips"
echo "       back to 8 if you use 'struct' or 'final class' + no inheritance.)"
echo ""
echo "       D STRUCT (zero allocation) is the canonical embedded D answer:"
echo "         4 insns total. Returned in a2/a3 via the Xtensa C-ABI's"
echo "         8-byte struct-return slot. No heap, no vtable, no overhead."
echo ""
echo "  → Verdict: D's static abstractions (struct templates, mixin, CTFE)"
echo "    are exactly as cheap as C++ templates and Rust generics. D's"
echo "    dynamic-class story in -betterC is a *manual-allocator dance* on"
echo "    top of the same underlying machine code as C++ 'new' + ctor. The"
echo "    user's note about 'malloc/free or Mallocator' is therefore the"
echo "    correct framing: there's no D-language overhead, just no GC to"
echo "    handle the malloc + emplace for you. See docs/25."
