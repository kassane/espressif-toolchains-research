#!/usr/bin/env bash
# safety.sh - D/LDC exclusive features, preview/edition flags, and @safe parity
# with Rust. Companion to run.sh; see docs/20.
#   (a) -preview= feature list + -preview=safer (default-safety, like Rust)
#   (b) --edition= (D's edition axis; analogous to Rust editions)
#   (c) @safe rejection battery: D @safe vs Rust safe (same unsafe ops)
#   (d) DIP1000 escape analysis vs Rust's borrow checker (return &local)
#   (e) LDC-exclusive features on Xtensa: @fastmath, @section, @weak, inline LLVM IR
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
B=build/dsafe; mkdir -p "$B"
LT="-mtriple=xtensa-esp-elf -mcpu=esp32"
# zig c++ caches successful compiles and does NOT replay diagnostics on cache
# hit, so the C++ warning probes (§h) would silently disappear on re-runs.
# Use a per-run fresh cache dir.
export ZIG_GLOBAL_CACHE_DIR="$PWD/$B/zcache"; rm -rf "$ZIG_GLOBAL_CACHE_DIR"

echo "== (a) -preview= upcoming language changes (safety-relevant ones marked *) =="
"$LDC2" -preview=h 2>&1 | grep -E '=(all|dip1000|dip1008|safer|systemVariables|in|bitfields)' \
  | sed -E 's/\(http[^)]*\)//; s/^/  /'
printf 'module m;\nint f(int* p){ return *(p+1); }\n' > "$B/dflt.d"
o0=$("$LDC2" -betterC -c "$B/dflt.d" -of="$B/d.o" 2>&1 || true)
o1=$("$LDC2" -preview=safer -betterC -c "$B/dflt.d" -of="$B/d.o" 2>&1 || true)
printf "  default safety   : %s\n" "$(printf '%s' "$o0" | grep -oiE 'not allowed.*' | head -1 || echo 'builds (functions are @system by default)')"
printf "  -preview=safer   : %s\n" "$(printf '%s' "$o1" | grep -oiE 'pointer arithmetic.*' | head -1)"
echo "  => -preview=safer (in -preview=all) rejects the dangerous ops in DEFAULT-safety"
echo "     functions — D's step toward Rust's safe-by-default."

echo "== (b) --edition= (DIP1052; like Rust's 2015/2018/2021/2024) =="
printf 'extern(C) void f(){}\n' > "$B/e.d"
for ed in 2022 2023 2024 2025 2026; do
  "$LDC2" --edition=$ed -betterC -c "$B/e.d" -of="$B/e.o" 2>/dev/null && st=accepted || st=REJECTED
  printf "  --edition=%s : %s\n" "$ed" "$st"
done
echo "  => valid range 2023-2025; an edition is a coherent opt-in bundle of mature"
echo "     breaking changes (per-module: \`module m 2025;\`), interoperable across"
echo "     editions — exactly Rust's model. It does NOT flip default @safe here;"
echo "     that is the orthogonal -preview=safer axis above. See docs/20."

echo "== (c) @safe rejection battery: D @safe vs Rust safe =="
dprobe(){ printf 'module m;\n%s\n' "$2" > "$B/t.d"; local out r v; \
  out=$("$LDC2" -betterC -c "$B/t.d" -of="$B/t.o" 2>&1 || true); \
  r=$(printf '%s' "$out" | grep -oiE 'not allowed in a `@safe`|cannot call `@system`|without `@trusted`' | head -1 || true); \
  if [ -n "$r" ]; then v="REJECTED ($r)"; else v="ALLOWED"; fi; \
  printf "  %-30s D @safe: %s\n" "$1" "$v"; }
dprobe "pointer index p[i]"      '@safe int f(int* p,size_t i){ return p[i]; }'
dprobe "pointer arithmetic p+1"  '@safe int f(int* p){ return *(p+1); }'
dprobe "int->ptr cast + deref"   '@safe int f(size_t x){ return *cast(int*)x; }'
dprobe "ptr reinterpret deref"   '@safe float f(int* p){ return *cast(float*)p; }'
dprobe "__gshared mutable global" '__gshared int g;@safe int f(){ return g; }'
dprobe "call @system fn"         '@system int s(){return 1;}@safe int f(){ return s(); }'
dprobe "inline asm"              '@safe void f(){ asm { "nop"; } }'
dprobe "union pointer pun"       'union U{int* p;size_t n;}@safe size_t f(int* x){U u;u.p=x;return u.n;}'
echo "  --- Rust safe (same ops; E0133 = requires unsafe) ---"
cat > "$B/rs.rs" <<'EOF'
#![allow(dead_code,unused)]
fn idx(p:*const i32,i:usize)->i32{ *p.add(i) }
fn arith(p:*const i32)->i32{ *p.wrapping_add(1) }
fn i2p(x:usize)->i32{ *(x as *const i32) }
fn reint(p:*const i32)->f32{ *(p as *const f32) }
static mut G:i32=0; fn gs()->i32{ G }
unsafe fn sy()->i32{1} fn callu()->i32{ sy() }
union U{p:*const i32,n:usize} fn pun(x:*const i32)->usize{ U{p:x}.n }
EOF
rout=$("$RUSTC" --edition 2021 --crate-type lib "$B/rs.rs" -o "$B/rs.rlib" 2>&1 || true)
printf "  Rust safe rejects EVERY op (E0133 'requires unsafe'): %s diagnostics across the 7\n" "$(printf '%s' "$rout" | grep -cE 'requires unsafe' || true)"
echo "  => parity: D @safe rejects 7/8; the lone gap is same-size pointer REINTERPRET"
echo "     (Rust needs unsafe for it too). Everything else needs @trusted / unsafe."

echo "== (d) escape analysis: D @safe + DIP1000 vs Rust borrow checker =="
printf '@safe int* f(){ int x=3; return &x; }\n' > "$B/esc.d"
e0=$("$LDC2" -betterC -c "$B/esc.d" -of="$B/e.o" 2>&1 || true)
e1=$("$LDC2" -preview=dip1000 -betterC -c "$B/esc.d" -of="$B/e.o" 2>&1 || true)
printf "  D @safe (no dip1000):     %s\n" "$(printf '%s' "$e0" | grep -oiE 'taking the address of stack-allocated.*' | head -1)"
printf "  D @safe -preview=dip1000: %s\n" "$(printf '%s' "$e1" | grep -oiE 'escapes a reference to local.*' | head -1)"
printf "fn f<%s>() -> &%s i32 { let x=3; &x }\n" "'a" "'a" > "$B/esc.rs"
er=$("$RUSTC" --edition 2021 --crate-type lib "$B/esc.rs" -o /dev/null 2>&1 || true)
printf "  Rust borrow ck:           %s\n" "$(printf '%s' "$er" | grep -oiE 'cannot return reference to local.*' | head -1)"

echo "== (e) LDC-exclusive features on Xtensa (esp32) =="
cat > "$B/ldcx.d" <<'EOF'
import ldc.attributes;
import ldc.llvmasm;
extern(C) @fastmath double dot(double* a, double* b, int n) @trusted {
  double s = 0; foreach (i; 0 .. n) s += a[i]*b[i]; return s;   // relaxed FP
}
extern(C) @weak int weak_sym() { return 1; }
extern(C) @section(".iram1.text") void hot() {}
extern(C) int add_ir(int a, int b) @trusted {
  return __ir!(`%r = add i32 %0, %1
                ret i32 %r`, int)(a, b);                        // inline LLVM IR
}
EOF
"$LDC2" $LT $LDC_PE -betterC -O2 -output-ll -of="$B/ldcx.ll" "$B/ldcx.d" 2>/dev/null
"$LDC2" $LT $LDC_PE -betterC -O2 -c "$B/ldcx.d" -of="$B/ldcx.o"
printf "  @fastmath -> %s   @section -> %s   @weak -> %s\n" \
  "$(grep -oE 'f(mul|add) (fast|reassoc)[a-z ]*' "$B/ldcx.ll" | head -1)" \
  "$(llvm-readobj --sections "$B/ldcx.o" 2>/dev/null | grep -oE '\.iram1[a-z0-9._]*' | head -1)" \
  "$(llvm-nm "$B/ldcx.o" 2>/dev/null | grep -iE 'weak_sym' | grep -oiE '^[0-9a-f]* W' | head -1)"
printf "  inline LLVM IR add_ir -> %s (real Xtensa insn from embedded IR)\n" \
  "$(llvm-objdump -d --mcpu=esp32 --disassemble-symbols=add_ir "$B/ldcx.o" 2>/dev/null | grep -oE '\badd\b|add\.n' | head -1)"
echo "  (@fastmath/@section/@weak via ldc.attributes; __ir embeds LLVM IR — all"
echo "   LDC-only, no DMD/GDC equivalent. Cross-compile is -mtriple/-mcpu/-mattr.)"

echo "== (f) must-use parity: D @mustuse / Rust #[must_use] / C++ [[nodiscard]] =="
printf 'import core.attribute:mustuse;@mustuse int f(){return 42;}\n' > "$B/muf.d"
o=$("$LDC2" -betterC -c "$B/muf.d" -of="$B/x.o" 2>&1 || true)
printf "  D @mustuse on FUNCTION : %s\n" "$(printf '%s' "$o" | grep -oiE 'reserved for future use.*' | head -1)"
printf 'import core.attribute:mustuse;@mustuse struct R{int v;}R make(){return R(42);}extern(C) void use(){make();}\n' > "$B/mut.d"
o=$("$LDC2" -betterC -c "$B/mut.d" -of="$B/x.o" 2>&1 || true)
printf "  D @mustuse on TYPE     : %s\n" "$(printf '%s' "$o" | grep -oiE 'ignored value of `@mustuse` type.*' | head -1)"
cat > "$B/mu.rs" <<'EOF'
#[must_use] fn f() -> i32 { 42 }
#[must_use] struct R { v: i32 }
pub fn caller() { f(); R{v:42}; }
EOF
o=$("$RUSTC" --edition 2021 --crate-type lib "$B/mu.rs" -o /dev/null 2>&1 || true)
printf "  Rust #[must_use] fn+type: %s 'must be used' warnings (warn-by-default)\n" "$(printf '%s' "$o" | grep -cE 'must be used' || true)"
cat > "$B/nd.cpp" <<'EOF'
[[nodiscard]] int f(){return 42;}
struct [[nodiscard("check it")]] R { int v; };
int main(){ f(); R{42}; return 0; }
EOF
o=$("$ZIG" c++ -std=c++26 -fexperimental-library "$B/nd.cpp" -o /dev/null 2>&1 || true)
printf "  C++26 [[nodiscard]]    : %s warnings (incl. C++20 'reason')\n" "$(printf '%s' "$o" | grep -cE 'nodiscard|unused-result' || true)"
echo "  => D @mustuse is TYPE-only (fn 'reserved for future use'); Rust + C++ allow both."

echo "== (g) @live (DIP1021 ownership) ⇄ Rust borrow checker — memory-safety parity =="
cat > "$B/live.d" <<'EOF'
import core.stdc.stdlib:malloc,free;
@live @trusted void uaf()   { int* p=cast(int*)malloc(4); free(p); *p=1; }
@live @trusted void dbl()   { int* p=cast(int*)malloc(4); free(p); free(p); }
@live @trusted void leak()  { int* p=cast(int*)malloc(4); }
@live @trusted int* dangle(){ int x; return &x; }
EOF
o=$("$LDC2" -preview=dip1021 -betterC -c "$B/live.d" -of="$B/x.o" 2>&1 || true)
echo "  D @live -preview=dip1021 rejects:"
printf '%s' "$o" | grep -oE 'has undefined state|is not Owner, cannot consume|is not disposed of before return|escapes a reference' | sort -u | sed 's/^/    /'
cat > "$B/rb.rs" <<'EOF'
#![allow(unused)]
fn uaf(){ let b=Box::new(0); let r=&*b; drop(b); let _=*r; }
fn dbl(){ let b=Box::new(0); drop(b); drop(b); }
fn dangle<'a>()->&'a i32{ let x=3; &x }
fn leak(){ let b=Box::new(0); std::mem::forget(b); }
EOF
o=$("$RUSTC" --edition 2021 --crate-type lib "$B/rb.rs" -o /dev/null 2>&1 || true)
printf "  Rust borrow checker rejects: %s\n" "$(printf '%s' "$o" | grep -oE 'E0[0-9]+' | sort -u | tr '\n' ' ')"
printf "  Rust LEAK errors: %s   (mem::forget is SAFE — Rust allows leaks by design)\n" "$(printf '%s' "$o" | grep -c 'leak' || true)"
echo "  C++ static: NONE (no borrow analog; runtime via -fsanitize=address)."
echo "  => D @live catches UAF + double-free + dangling + LEAK; Rust catches first 3"
echo "     but allows leaks (mem::forget safe); C++ has no static borrow equivalent."

echo "== (h) C++26 via zig c++ (canonical \$ZIG = 0.17 → clang 22.1.4 + libc++ 22; -fexperimental-library) =="
"$ZIG" c++ --version 2>/dev/null | head -1 | sed 's/^/  /'
hprobe(){ printf '#include %s\nint main(){return 0;}\n' "$2" > "$B/p.cpp"; \
  o=$("$ZIG" c++ -std=c++26 -fexperimental-library -c "$B/p.cpp" -o /dev/null 2>&1 || true); \
  if printf '%s' "$o" | grep -qE 'fatal|no such|undeclared'; then s="MISSING"; else s="OK"; fi; \
  printf "    %-22s %s\n" "$1" "$s"; }
echo "  libc++ feature headers:"
hprobe "<expected>"  "<expected>"
hprobe "<print>"     "<print>"
hprobe "<flat_map>"  "<flat_map>"
hprobe "<execution>" "<execution>"
hprobe "<simd> (C++26)"     "<simd>"
hprobe "<linalg> (C++26)"   "<linalg>"
hprobe "<contracts> (P2900)" "<contracts>"
hprobe "<hive> (C++26)"     "<hive>"
printf 'int f(int b) pre(b!=0) { return b; }\n' > "$B/ctr.cpp"
o=$("$ZIG" c++ -std=c++26 -fexperimental-library -c "$B/ctr.cpp" -o /dev/null 2>&1 || true)
printf "  contracts syntax (P2900): %s\n" "$(printf '%s' "$o" | grep -oE 'expected function body.*' | head -1 || echo IMPLEMENTED)"
echo "  => -fexperimental-library is a no-op on libc++ 22 too (C++26 <simd>/"
echo "     <linalg>/<contracts>/<hive> all unimplemented); only [[nodiscard]]"
echo "     (must-use) carries. Set ZIG=\$ZIG_016 to probe the legacy libc++ 21"
echo "     row; the only feature delta is P2686R5 (constexpr [a,b])."

echo "== (i) C++26 via esp-g++ 15.2.0 / libstdc++ 15 (xtensa-esp-elf, -ffreestanding) =="
# The matrix has TWO C++ producers: esp-clang 21.1.3 (probed in §h via zig c++)
# and esp-g++ 15.2.0. Probe the GCC arm with the canonical embedded compile
# mode (-ffreestanding + XTENSA_GNU_CONFIG) to record the libstdc++ 15 status
# alongside the libc++ row. Three buckets: (1) freestanding-subset headers
# (parse under -ffreestanding), (2) hosted-only C++23 headers (gated by
# bits/requires_hosted.h), (3) frontier C++26 headers libstdc++ 15 hasn't
# implemented at all. Then the four frontier *features* (P2686/P2900/P2996/P2688).
"$GXX" --version 2>/dev/null | head -1 | sed 's/^/  /'
export XTENSA_GNU_CONFIG=$(xtensa_cfg esp32)
# Two-mode probe: under -ffreestanding (canonical embedded), and hosted (no
# -ffreestanding). Three buckets we want to distinguish in the output:
#   OK                                — parses freestanding (in the subset)
#   freestanding-blocked, parses hosted — shipped, but bits/requires_hosted.h
#                                         rejects it under -ffreestanding
#   MISSING                           — header not in libstdc++ 15 at all
gprobe(){ printf '#include %s\nint main(){return 0;}\n' "$2" > "$B/gp.cpp"; \
  if "$GXX" -std=c++26 -ffreestanding -c "$B/gp.cpp" -o /dev/null 2>/dev/null; then s="OK"; \
  elif "$GXX" -std=c++26 -c "$B/gp.cpp" -o /dev/null 2>/dev/null; then s="freestanding-blocked, parses hosted"; \
  else s="MISSING"; fi; \
  printf "    %-22s %s\n" "$1" "$s"; }
echo "  libstdc++ feature headers (probed both -ffreestanding and hosted):"
gprobe "<expected>"          "<expected>"
gprobe "<ranges>"            "<ranges>"
gprobe "<stdfloat>"          "<stdfloat>"
gprobe "<print>"             "<print>"
gprobe "<format>"            "<format>"
gprobe "<flat_map>"          "<flat_map>"
gprobe "<execution>"         "<execution>"
gprobe "<generator>"         "<generator>"
gprobe "<simd> (C++26)"      "<simd>"
gprobe "<linalg> (C++26)"    "<linalg>"
gprobe "<contracts> (P2900)" "<contracts>"
gprobe "<hive> (C++26)"      "<hive>"
gprobe "<mdspan>"            "<mdspan>"
gprobe "<experimental/simd>" "<experimental/simd>"
echo "  frontier core-language features:"
printf 'struct P{int a,b;};constexpr int f(){constexpr auto[a,b]=P{1,2};return a+b;}int main(){return f()-3;}\n' > "$B/g2686.cpp"
o=$("$GXX" -std=c++26 -ffreestanding -c "$B/g2686.cpp" -o /dev/null 2>&1 || true)
printf "    P2686R5 constexpr [a,b]: %s\n" "$(printf '%s' "$o" | grep -oE "structured binding declaration cannot be 'constexpr'" | head -1 || echo IMPLEMENTED)"
printf 'int f(int n)pre(n>0)post(r:r>0){return n;}int main(){return f(1)-1;}\n' > "$B/g2900.cpp"
o=$("$GXX" -std=c++26 -ffreestanding -c "$B/g2900.cpp" -o /dev/null 2>&1 || true)
printf "    P2900 pre/post syntax  : %s\n" "$(printf '%s' "$o" | grep -oE "expected initializer before 'pre'" | head -1 || echo IMPLEMENTED)"
printf 'struct S{int x;};int main(){constexpr auto r=^^S;(void)r;return 0;}\n' > "$B/g2996.cpp"
o=$("$GXX" -std=c++26 -ffreestanding -freflection -c "$B/g2996.cpp" -o /dev/null 2>&1 || true)
printf "    P2996 -freflection flag: %s\n" "$(printf '%s' "$o" | grep -oE "unrecognized command-line option '-freflection'" | head -1 || echo IMPLEMENTED)"
printf 'int f(int x){return x match{0=>0;_=>1;};}int main(){return f(0);}\n' > "$B/g2688.cpp"
o=$("$GXX" -std=c++26 -ffreestanding -c "$B/g2688.cpp" -o /dev/null 2>&1 || true)
printf "    P2688R5 match syntax   : %s\n" "$(printf '%s' "$o" | grep -oE "expected ';' before 'match'" | head -1 || echo IMPLEMENTED)"
echo "  => libstdc++ 15 ships <expected>/<ranges>/<stdfloat> freestanding (header-only"
echo "     constexpr). C++23 hosted headers (<print>/<format>/<flat_map>/<execution>/"
echo "     <generator>/<experimental/simd>) ship on disk but bits/requires_hosted.h"
echo "     rejects them under -ffreestanding ('not available in freestanding mode')."
echo "     C++26 frontier (<simd>/<linalg>/<contracts>/<hive>/<mdspan>) not implemented"
echo "     in libstdc++ 15 at all — same gap libc++ 22 has. P2686/Contracts/Reflection"
echo "     all rejected: esp-g++ 15.2.0 = esp-clang 21.1.3 on the C++26 frontier."
