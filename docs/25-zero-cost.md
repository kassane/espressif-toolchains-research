# 25 — Zero-cost abstractions across D, C++, Rust on Xtensa esp32

Stroustrup's claim — *"what you do use, you couldn't hand code any better"* —
deep-dived against the three statically-monomorphizing LLVM frontends in
this matrix on `xtensa-esp-elf -mcpu=esp32 -Os`. Reproduce with
`experiments/zero-cost/run.sh`.

User context for the experiment: D `class` in `-betterC` needs
`malloc`/`free` or a `Mallocator`-style explicit allocator (no druntime →
no GC → no `new` keyword), so §(d) probes what the resulting machine code
looks like vs C++ `new` + ctor and Rust `malloc` + raw write.

## TL;DR

| abstraction category | zero-cost? | best Xtensa code |
|---|---|---|
| monomorphized generic / template (`sum<int>`) | ✓ — identical to C hand-loop modulo frame-pointer policy | 10-11 insns / 23-25 B |
| higher-order: lambda / functor / Fn-trait / D template | ✓ — body inlined to a `slli`-by-1 at -Os even via fn-ptr (clang devirtualizes) | 3-4 insns / 8-10 B |
| static dispatch (CRTP / impl Trait / D struct template) | ✓ — the closed-form `n*Step` loop is constant-folded to one `mull` | 6-7 insns / 15-17 B |
| dynamic dispatch (C++ virtual / Rust `dyn Trait` / D class) | ✗ — extra `l32i`+`callx8` per call, no fold | +2-3 insns/iter; ~+12 B total |
| heap allocation (`new T(args)` / `Box::new` / D class on `malloc`) | n/a — these are not abstractions, they're system calls; identical machine code in all three | ~10-11 insns / 24-26 B |
| D value-type alternative: `struct CounterStruct` | ✓ — stack-allocated, struct-returned in registers | 4 insns / 9 B |

## §(a) Monomorphization: the foundation

The same i32 accumulator written three ways per language:

```
sum_c(int*, int)                C baseline                       11 insn 25 B
sum_cpp_loop(int*, int)         C++ hand-loop                    11 insn 25 B
sum_cpp_tmpl<int>(int*, int)    C++ template instantiated at int 11 insn 25 B  ← same!
sum_rs_loop                     Rust while-loop                  10 insn 23 B (ICF-merged with...
sum_rs_iter                     Rust .iter().copied().fold       10 insn 23 B
sum_rs_generic_i32              Rust generic over T: Add+Copy    10 insn 23 B
sum_d_loop                      D hand-loop                      10 insn 23 B
sum_d_tmpl!int                  D template instantiated at int   10 insn 23 B
```

C/C++ is one Xtensa instruction (2 B) bigger than Rust/D because clang at
`-Os` still emits the `mov.n a7,a1` frame-pointer setup; rustc and LDC
default to `-fomit-frame-pointer`. That's a driver policy difference, not
abstraction overhead — flip `clang -fomit-frame-pointer` and the numbers
match exactly.

**The Rust ICF (Identical Code Folding) observation** is its own win: the
linker recognizes `sum_rs_loop`, `sum_rs_iter`, and `sum_rs_generic_i32` as
emitting *byte-identical* `.text` sections and folds them into one body
under whichever symbol name happens to win the merge. `llvm-size -A` will
report `.text.sum_rs_loop` as missing; the symbol still resolves, it just
shares the section with `.text.sum_rs_generic_i32`. See
`experiments/zero-cost/run.sh` `text_bytes()` helper for how the test
suite handles this — counting bytes from the symbol's own disasm instead
of looking up the section size.

## §(b) Higher-order functions: lambda parity

```cpp
// C++ template — the lambda type F is part of the function name, so the
// body is visible at the instantiation site and inlines.
template <typename F> int apply_cpp_tmpl(F f, int x) { return f(x); }
int call_apply_cpp_tmpl(int x) { return apply_cpp_tmpl([](int y){ return y+y; }, x); }
```

```rust
fn apply_rs_generic<F: Fn(i32) -> i32>(f: F, x: i32) -> i32 { f(x) }
extern "C" fn call_apply_rs_generic(x: i32) -> i32 {
    apply_rs_generic(|y| y.wrapping_add(y), x)
}
```

```d
int apply_d_tmpl(F)(F f, int x) { return f(x); }
struct DoublerD { static int call(int x) { return x + x; } }
int call_apply_d_tmpl(int x) {
    return apply_d_tmpl!(typeof(&DoublerD.call))(&DoublerD.call, x);
}
```

All three produce the same Xtensa body:

```
entry  a1, 32         # windowed-call prologue
slli   a2, a2, 1      # x * 2  (= x + x; the lambda body, inlined)
retw.n
```

A surprising bonus: the **raw fn-pointer** versions
(`call_apply_c`, `call_apply_cpp_fnptr`, `call_apply_d_fnptr`,
`call_apply_rs_fnptr`) also fold to the same body at -Os because clang +
LLVM see the constant `&doubler` at the call site and devirtualize. So
even the C-style "callback with explicit fn-ptr" pattern is zero-cost when
the callee is a *compile-time constant* — only when the pointer is
runtime-determined (from a struct field, function arg) does the
indirect call survive.

## §(c) Static vs dynamic dispatch — where zero-cost FAILS

```cpp
// C++ — template parameter Step is compile-time const, n×Step folds.
template <int Step> struct StaticCounter { int v; int tick(){ v+=Step; return v; } };
int use_static_cpp(int n) {
    StaticCounter<3> c{0};
    int last = 0;
    for (int i = 0; i < n; i++) last = c.tick();
    return last;
}
```

`use_static_cpp` codegen:

```
entry a1, 32
mov.n a7, a1
movi.n a8, 0
max    a8, a2, a8     # last = max(n, 0)
movi.n a9, 3          # Step
mull   a2, a8, a9     # last = n * 3  (closed-form folded out of the loop!)
retw.n
```

The compiler reasoned through the loop, recognized `v += 3` ran n times,
and replaced the entire loop with one `mull`. **D's static struct
template** (`struct StaticCounterD(int Step)`) produces the byte-identical
body — same closed-form fold. Rust `static_loop::<CounterRs>` does the
same thing.

Dynamic dispatch — `use_virtual_cpp` codegen (`Ticker *t`, virtual call):

```
entry a1, 32
mov.n a7, a1
blti  a2, 1, ret_zero
.Lloop:
  l32i.n a8, a3, 0     # load vtable ptr from object[0]
  l32i.n a8, a8, 0     # load tick() pointer from vtable[0]
  mov.n  a10, a3       # this
  callx8 a8            # indirect call — devirt impossible
  addi.n a2, a2, -1
  bnez   a2, .Lloop
ret_zero:
  movi.n a10, 0
ret_done:
  mov.n  a2, a10
  retw.n
```

The two-step vtable load (`object → vtable → method`) is fundamental to
the C++ vtable layout. Rust's `&dyn Trait` is a fat pointer (data ptr +
vtable ptr passed in separate ABI registers), so `use_dynamic_rs` saves
one `l32i.n` per call — 11 insns total vs C++'s 13. Concrete cost
delta vs the static form (per iteration, esp32 -Os):

| form | insns/iter | extra cost vs static |
|---|---|---|
| C++ virtual | 5 (l32i, l32i, mov, callx8, addi/bnez) | +3 over static (closed-form: 0 insns/iter) |
| Rust `dyn Trait` | 4 (l32i, mov, callx8, addi/bnez) | +2 over static |

For 1000 iterations: +3000 cycles (C++ virtual) or +2000 cycles (Rust
dyn). On a 240 MHz esp32 that's 12.5 µs or 8.3 µs of pure dispatch
overhead. Real, measurable, not zero. The static forms have *zero*
iteration overhead because the closed form was solved at compile time.

## §(d) Heap allocation — system call disguised as abstraction

This is where the user's note matters: **D class in `-betterC` needs
malloc/free or a Mallocator-style allocator** because druntime
(`_d_newclass`, GC, etc.) isn't linked. The canonical D pattern:

```d
// experiments/zero-cost/d/heap.d
extern (C):
@nogc nothrow @system void* malloc(size_t);  // hand-declared (core.stdc
                                              // imports break in -betterC
                                              // on xtensa-esp-elf — see
                                              // docs/19 and the source file)

extern(C++) class Counter {   // extern(C++) avoids druntime ClassInfo
    int v = 0;
    int step;
    this(int s) @nogc @system { v = 0; step = s; }
    int tick() @nogc @system { v += step; return v; }
}

Counter make_counter_d(int step) @nogc @system {
    enum sz = __traits(classInstanceSize, Counter);
    auto raw = malloc(sz);
    if (raw is null) return null;
    auto c = cast(Counter) raw;
    c.__ctor(step);               // explicit ctor (what `new` would do)
    return c;
}
```

Compiled vs C++ `new(placement)` + ctor and Rust `malloc` + raw write:

```
make_counter_cpp:    11 insn, 26 B   (sizeof Counter = 8)
make_counter_rs:     10 insn, 24 B   (sizeof = 8)
make_counter_d:      10 insn, 24 B   (sizeof = 12 — adds 4 B for vtable ptr)
```

Side-by-side disasm:

```
C++ make_counter_cpp        D make_counter_d            Rust make_counter_rs
entry a1, 32                entry a1, 32                entry a1, 32
mov.n a7, a1                                                              ← clang FP
movi.n a10, 8               movi.n a10, 12              movi.n a10, 8     ← sizeof
l32r   a8, malloc           l32r   a8, malloc           l32r   a8, malloc
callx8 a8                   callx8 a8                   callx8 a8
beqz   a10, ret_null        beqz   a10, ret_null        beqz   a10, ret_null
s32i.n a2,  a10, +4         s32i.n a2,  a10, +8         s32i.n a2,  a10, +4
movi.n a8, 0                movi.n a8, 0                movi.n a8, 0
s32i.n a8,  a10, +0         s32i.n a8,  a10, +4         s32i.n a8,  a10, +0
                            mov.n  a2,  a10             mov.n  a2,  a10
retw.n                      retw.n                      retw.n
```

Three observations:

1. **The instruction shape is identical across all three.** Every form is
   "alloca size → call malloc → null-check → store ctor args → return".
   There's no D-language overhead. The `@nogc nothrow @system` annotations
   participate in the type system but cost zero bytes of `.text`.

2. **D `extern(C++) class` instances are 12 B not 8 B** because the
   class carries a vtable pointer even when no `virtual` methods are
   declared. The `step` field lands at offset 8 (after the 4-byte vtable
   ptr); `v` lands at offset 4. C++ and Rust use 8-byte structs because
   neither has a vtable.

3. **For the embedded case, `struct CounterStruct` is the right answer**
   (`d/heap.d` includes it as the comparison):

   ```
   make_counter_struct_d:
       entry a1, 32
       mov.n a3, a2       # struct field 1 (step) → a3
       movi.n a2, 0       # struct field 0 (v=0) → a2
       retw.n
   ```

   4 insns / 9 B. No heap, no vtable, no overhead. Returned by value in
   the Xtensa C-ABI's 8-byte struct-return registers (a2/a3). Functionally
   equivalent for a non-polymorphic counter, costs *6 insns less per
   instance* than the class form. The user's note implicitly carries this:
   *if you don't need polymorphism, don't reach for `class` in -betterC*.

## Cross-language summary

| feature | "couldn't hand-code any better"? | machine-level evidence |
|---|---|---|
| compile-time-constant inlining (constants, lambdas at known sites) | ✓ all three | §a/§b — body folds to the inner expr |
| algebraic loop fold (n×K closed form) | ✓ all three | §c static — `mull` replaces the loop |
| iterator chains (Rust `.iter().sum()`, D ranges via UFCS) | ✓ Rust ICF-folds; D inlines | §a — same `.text` as hand-loop |
| static polymorphism (CRTP, impl Trait, D struct template) | ✓ all three | §c — identical to the inline body |
| dynamic polymorphism (virtual / dyn / D class) | ✗ all three | §c — +2 insn/iter (Rust) or +3 (C++) |
| heap allocation primitive | n/a — it's a syscall | §d — same machine code in C++/Rust/D |
| D class in `-betterC` | ✓ for codegen, ✗ for ergonomics | §d — manual malloc + `__ctor` does what `new` would |
| stack-allocated value types | ✓ all three | §d — D struct returns in 4 insns |

The general rule the disasm confirms: **monomorphization is zero-cost**
across all three languages; **vtable indirection is not**. D in `-betterC`
participates in both halves cleanly — the static abstractions cost
nothing, the dynamic ones cost the same as C++/Rust dynamic ones, and the
allocator boilerplate that druntime would hide is a stable 3-4 lines of D
that compiles to the same instructions as the C++ equivalent.

Reproduce: `bash experiments/zero-cost/run.sh`. Inspect the disasm with
`llvm-objdump -d --mcpu=esp32 --disassemble-symbols=<sym>
build/zero-cost/<lang>_<test>.o`.
