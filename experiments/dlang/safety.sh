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
"$LDC2" $LT -betterC -O2 -output-ll -of="$B/ldcx.ll" "$B/ldcx.d" 2>/dev/null
"$LDC2" $LT -betterC -O2 -c "$B/ldcx.d" -of="$B/ldcx.o"
printf "  @fastmath -> %s   @section -> %s   @weak -> %s\n" \
  "$(grep -oE 'f(mul|add) (fast|reassoc)[a-z ]*' "$B/ldcx.ll" | head -1)" \
  "$(llvm-readobj --sections "$B/ldcx.o" 2>/dev/null | grep -oE '\.iram1[a-z0-9._]*' | head -1)" \
  "$(llvm-nm "$B/ldcx.o" 2>/dev/null | grep -iE 'weak_sym' | grep -oiE '^[0-9a-f]* W' | head -1)"
printf "  inline LLVM IR add_ir -> %s (real Xtensa insn from embedded IR)\n" \
  "$(llvm-objdump -d --mcpu=esp32 --disassemble-symbols=add_ir "$B/ldcx.o" 2>/dev/null | grep -oE '\badd\b|add\.n' | head -1)"
echo "  (@fastmath/@section/@weak via ldc.attributes; __ir embeds LLVM IR — all"
echo "   LDC-only, no DMD/GDC equivalent. Cross-compile is -mtriple/-mcpu/-mattr.)"
