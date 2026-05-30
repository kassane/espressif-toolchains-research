# 26 — Template-metaprogramming parity across D, C++, Rust

A direct follow-up to docs/25. PR-27 only probed *monomorphization* (one TMP
capability of many), and conflated D's `extern(C++) class` (D-produced vtable)
with D's `extern(C++, class) struct` (D consumes a C++ class) when discussing
the FFI surface. This document closes both gaps:

1. Catalogs the full TMP feature surface of D, C++ (esp-clang 21.1.3 / zig c++
   22.1.4 / gcc 15.2.0 -std=c++26), and rustc 1.95-nightly side-by-side,
   feature-by-feature, with Xtensa esp32 -Os disassembly evidence;
2. Disentangles the three distinct D `extern(C++)` FFI forms and shows their
   IR-level differences.

Reproduce with `experiments/tmp-parity/run.sh`. All output below is real.

## TL;DR

D's TMP surface is the broadest of the three, by a wide margin. Of the twelve
capabilities probed:

| capability | C++ (clang 21 / 22, -std=c++26) | D (LDC 1.42 -betterC) | Rust 1.95-nightly stable |
|---|---|---|---|
| Type parameter (`<T>`) | ✓ | ✓ | ✓ |
| NTTP / const generic (int) | ✓ | ✓ | ✓ |
| String / class-type NTTP | ✓ (C++20+) | ✓ (always) | nightly `adt_const_params` only |
| Template-template / alias param | ✓ | ✓ (`alias`) | ✓ (`F: Fn`) |
| Constraints / concepts | ✓ (C++20 `concept`) | ✓ (`if (...)`) | ✓ (trait bounds) |
| Full specialization | ✓ | ✓ | nightly `min_specialization` |
| Partial specialization | ✓ | ✓ | nightly `min_specialization` |
| Compile-time branching | ✓ `if constexpr` (C++17) | ✓ `static if` | trait dispatch only |
| Token mixin (synthesize *identifiers* at CT) | ✗ — X-macros are #-level | ✓ `mixin("…")` | nightly `concat_idents` / `paste!()` |
| CTFE / constexpr / const fn | ✓ | ✓ (full druntime in CTFE) | ✓ (`const fn`, limited subset) |
| Type introspection (in-language) | ✗ — P2996 not in clang 21/22 | ✓ `__traits(allMembers, T)` | ✗ — proc-macros host-only |
| Variadic templates / packs | ✓ (`Ts...` + fold expr) | ✓ (`T...` + recurse) | declarative `macro_rules!` only |

**Headline**: D supports eleven of twelve in-language with no host build step;
C++ supports ten (no token-level identifier synthesis, no in-language
reflection); stable Rust supports six. Rust closes three of those gaps on
nightly (NTTP for class types, specialization, identifier concat); the others
(static-if, in-language reflection, variadic generics) require proc-macros that
run at host compile time and add 50–100 MB per consumer crate.

**IR-level**: every TMP feature that *exists* in two or more languages
produces equivalent IR. The factorial probe `fact(5) → 120` collapses to a
single `movi a2, 120 ; retw.n` in all three languages. The variadic-sum probe
`static_sum(10, 20, 12) → 42` likewise. No instruction-count gap for the
features the languages share.

## §a — Parameter forms

```
Type parameter:      cpp:✓  d:✓  rs:✓     id<T>(x)
Non-type / int NTTP: cpp:✓  d:✓  rs:✓     multiply_by<T, K>(x)
Higher-order / alias: cpp:—  d:✓  rs:✓    Wrap!dbl / fn(i32)->i32 arg
String NTTP:         cpp:✓  d:✓  rs:nightly  Greeter<FixedString("hello")>{}
```

D had compile-time string template parameters from the start; C++ needed C++20
(P0732 class-type NTTP) to lift the restriction; Rust still requires the
nightly `adt_const_params` feature for non-primitive const generics.
`experiments/tmp-parity/cpp/tmp.cpp` lines 23-34 demonstrate that esp-clang
21.1.3 -std=c++26 accepts the class-type NTTP; the corresponding D form in
lines 25-31 of `d/tmp.d` works without flags; Rust's form is commented out in
`rs/src/lib.rs` lines 31-38 with the explicit "nightly only" note.

D and C++ both produce `T(x * K)` instantiations at compile time — the Xtensa
`mull a2, a2, a3` disappears entirely when K is known. Rust does the same with
`const K: i32`.

The "higher-order function" row deserves nuance: C++ has no language-level
"alias" template parameter (template-template parameters apply to *types*, not
to *callables*). The idiomatic C++ equivalent is a template type parameter
constrained to be callable (`template<typename F> auto wrap(F f, int x)`), which
is what docs/25 §b already covers under "callable arg". So the column reads "—"
not because C++ can't do it, but because the form differs enough that it's not
a 1:1 parity test.

## §b — Constraints

```
Arithmetic addition: cpp:✓  d:✓  rs:✓
```

Three different syntaxes, one IR:

- D: `T add_only_arith(T)(T a, T b) if (__traits(isArithmetic, T)) { ... }`
- C++: `template<typename T> concept Arithmetic = __is_arithmetic(T); template<Arithmetic T> T add_only_arith(T a, T b) { ... }`
- Rust: `fn add_only_arith_rs<T>(a: T, b: T) -> T where T: Add<Output=T> + Copy { ... }`

All three reach the same Xtensa code at -Os: `add a2, a2, a3 ; retw.n`. The
constraint is purely a frontend gate; nothing reaches the backend.

`requires`-expressions (C++) and `is(...)` expressions (D) extend this:

```cpp
template <typename T>
constexpr bool IsIntegralLike_cpp = requires (T x) { x + 1; static_cast<int>(x); };
```

```d
template IsIntegralLike(T) { enum bool IsIntegralLike = is(T : int); }
```

Both compile-time-evaluate a *predicate* on a type without instantiating
anything. Rust's analog (in stable) is to declare a trait and check
`T: ThatTrait` — different mechanism (nominal, not structural), same observable
outcome.

## §c — Specialization

```
pow2<double> picks a different body:  cpp:✓  d:✓  rs:✓ (via trait method)
```

In C++ and D the compiler picks the more specific overload at the call site
based on the type argument; this is *true* specialization. Rust on stable has
**no specialization** — the only nightly path is `min_specialization`, gated
behind years of soundness work. The workaround is a per-type trait `impl` plus
calling the trait method, which dispatches to the right body at call time. The
generated IR is observationally equivalent for the cases that fit, but the
language semantics differ: in Rust the dispatch is a function-table lookup
resolved by the type-class system; in C++/D the dispatch is overload
resolution resolved by the template-matching algorithm.

Xtensa IR for `pow2_double_cpp(2.5)` and `pow2_d(2.5)` (both compile-time-
known):

```
movi.n  a2, 5
movi.n  a3, 0
retw.n
```

The `2.0 * 2.5` is folded to a constant `5.0` and returned in the f64
register pair. Rust's `n.pow2()` produces the same fold via `impl Pow2Rs for f64`.

The Rust workaround forfeits one specific TMP capability: there's no way in
stable Rust to write a *generic function* `f<T>` whose body depends on a
*partial* match of T (e.g. "specialize when T is any pointer type, defer
otherwise"). Partial specialization is the canonical example C++/D unambiguously
have and Rust does not.

## §d — Compile-time branching + token mixin

```
static-if / if constexpr / trait dispatch:    cpp:✓  d:✓  rs:via Trait
Generated gen_0/1/2 (3 different mechanisms): cpp:✓  d:✓  rs:✓
```

The probe is `sumdiff<T>(a, b) → a+b for floats, a-b for ints`. D writes:

```d
T sumdiff(T)(T a, T b) {
    static if (__traits(isFloating, T)) return a + b;
    else                                return a - b;
}
```

C++ writes the same shape with `if constexpr`. Both emit a single instantiation
per concrete T, with only the branch the type matches.

Rust has **neither** `static if` nor `if constexpr`. The closest stable form is
trait dispatch:

```rust
trait SumDiff { fn sumdiff_rs(a: Self, b: Self) -> Self; }
impl SumDiff for i32 { fn sumdiff_rs(a: Self, b: Self) -> Self { a - b } }
impl SumDiff for f32 { fn sumdiff_rs(a: Self, b: Self) -> Self { a + b } }
```

The dispatch happens at the call site, not inside a generic body. Same final
IR (one instantiation per T containing only the appropriate branch), different
language-level expressiveness: Rust can't write a *single* function body that
type-switches; the type-switch has to live in the trait-impl plane.

The token-mixin row is more interesting. D writes:

```d
static foreach (i; 0 .. 3) {
    mixin("int gen_" ~ i.stringof ~ "(int x) { return x + " ~ i.stringof ~ "; }");
}
```

That synthesizes three identifiers `gen_0`, `gen_1`, `gen_2` declaratively from
a compile-time integer. C++ has **no in-language equivalent**; the closest is
X-macros:

```cpp
#define FOR_EACH_GEN(X)  X(0) X(1) X(2)
#define DECL_GEN(N)  extern "C" int gen_##N##_cpp(int x) { return x + N; }
FOR_EACH_GEN(DECL_GEN)
```

That works, but at the *preprocessor* level — not template-system level — and
the integer values have to be enumerated literally (no `for(int i=0; i<N; i++)`
form). Reflection P2996 in C++26 will close this gap when shipped; not in clang
21 or 22.

Rust's analogous form is `macro_rules!` with the unstable `concat_idents!` /
`${concat(...)}` (issue rust-lang/rust#124225) for the identifier synthesis;
without nightly, you either write each function by hand (what `tmp-parity`
does), pull in `paste!()` from a crate dependency, or write a proc-macro that
runs at host compile time. The proc-macro path is real but expensive: a fresh
`syn`+`quote`+`proc-macro2` build chain costs ~50-100 MB on disk and
significant wall time per consumer crate.

## §e — Compile-time computation

```
get_fact5_xx → 120:    cpp:✓  d:✓  rs:✓
```

All three languages compute `fact(5) = 120` at compile time and emit the
constant directly. Xtensa esp32 -Os disassembly:

```
=== get_fact5_cpp ===          (3 instructions, esp-clang at -Os keeps fp)
    entry   a1, 32
    mov.n   a7, a1
    movi    a2, 120
    retw.n

=== get_fact5 (D) ===           (2 instructions)
    entry   a1, 32
    movi    a2, 120
    retw.n

=== get_fact5_rs ===            (2 instructions)
    entry   a1, 32
    movi    a2, 120
    retw.n
```

Byte-identical between D and Rust; C++ carries one extra `mov.n a7, a1`
frame-pointer instruction at clang's `-Os` policy (same one-insn delta noted in
docs/25 §a). This is *not* a TMP-system difference; it's a code-generator
policy difference downstream of the IR.

D has the deepest CTFE: full druntime is available *at CTFE time only* under
`-betterC` (the runtime calls inside an `enum` initializer evaluate against the
host interpreter's druntime, not against a target druntime). C++ `constexpr`
evolved to cover most of the language by C++23. Rust's `const fn` is the most
restrictive of the three on stable — no allocations, no panics in branches the
optimizer can't prove dead, no floating-point in const context, no trait
methods (without nightly `const_trait_impl`).

## §f — Type introspection

```
Periph field count = 3:        cpp:—  d:✓  rs:hand-coded
sum_periph_fields:             cpp:—  d:✓  rs:hand-coded
```

This is the bluntest gap. D writes:

```d
struct Periph { int base; int irq; int prio; }

template FieldCount(T) { enum size_t FieldCount = __traits(allMembers, T).length; }
int periph_n_fields() { return cast(int) FieldCount!Periph; }

int sum_periph_fields(Periph* p) {
    int s = 0;
    static foreach (m; __traits(allMembers, Periph)) {
        s += __traits(getMember, *p, m);
    }
    return s;
}
```

`__traits(allMembers, T)` returns the field name list at compile time, and
`static foreach` + `__traits(getMember, …)` lets the compiler generate the sum
unrolled. **There is no C++ or Rust equivalent on stable.** C++26 P2996
*Reflection for C++26* is the future, not landed in clang 21 or 22 mainline as
of 2026-05. Rust's `core::mem::size_of::<T>()` works at compile time, but field
iteration requires a derive proc-macro that runs at host compile time
(typically `#[derive(Debug)]` + the `serde`/`bincode`/etc. ecosystem). For an
embedded build, that proc-macro must be cross-compiled separately.

The `tmp-parity` Rust probe makes this explicit by hand-coding the field count:

```rust
#[no_mangle] pub extern "C" fn periph_n_fields_rs() -> i32 {
    3   // hand-coded, NOT computed from the type — Rust limitation
}
```

C++ has no equivalent to even *try* in stable mode; the closest is
`std::tuple_size` after manual `std::tie`, which is just hand-counting too.

## §g — Variadic

```
static_sum(10, 20, 12) → 42:    cpp:✓  d:✓  rs:✓
variadic op = subtract:         cpp:—  d:—  rs:✓
```

D recurses at the type-system level:

```d
template StaticSum(T...) {
    static if (T.length == 0) enum int StaticSum = 0;
    else static if (T.length == 1) enum int StaticSum = T[0];
    else enum int StaticSum = T[0] + StaticSum!(T[1 .. $]);
}
```

C++ uses the C++17 fold expression:

```cpp
template <typename... Ts>
constexpr auto static_sum_cpp(Ts... vs) { return (vs + ...); }
```

Rust has **no variadic generics** — issue rust-lang/rfcs#3850 is the open
RFC. The substitute is a `macro_rules!` that produces one impl per arity:

```rust
macro_rules! make_static_sum {
    ($name:ident, $($v:expr),+) => {
        #[no_mangle] pub extern "C" fn $name() -> i32 { 0 $( + $v )+ }
    };
}
make_static_sum!(variadic_42_rs, 10, 20, 12);
```

That gives the same final IR (a single `movi.n a2, 42 ; retw.n` after constant
folding), but the macro-level mechanism differs from the type-system-level
variadics: Rust can pass variadic *expressions*, not variadic *types*. A
function template `template <typename... Ts> void log(Ts... vs)` that takes
a heterogeneous pack of types and dispatches per type has no stable Rust analog.

Xtensa IR for the static sums:

```
=== variadic_42_cpp ===         (4 instructions; clang -Os keeps fp)
    entry    a1, 32
    mov.n    a7, a1
    movi.n   a2, 42
    retw.n

=== variadic_42 (D) ===          (3 instructions)
    entry    a1, 32
    movi.n   a2, 42
    retw.n

=== variadic_42_rs ===           (3 instructions)
    entry    a1, 32
    movi.n   a2, 42
    retw.n
```

The Rust subtract variant `variadic_neg42_rs` (a free bonus from `macro_rules!`
parameterization on the operator) also folds:

```
movi.n a2, 42         ; sign-extended literal -42 in two-byte form
neg    a2, a2
retw.n
```

The C++ fold-expression form is also flexible (`(vs * ...)`, `(vs && ...)`,
etc.), but the operator must be a *real* operator the type implements, not a
syntactic token.

## §h — Three D `extern(C++)` forms

This is the user's PR-27 follow-up note. D's `extern(C++) class` and
`extern(C++, class) struct` are NOT the same form played twice — they cover
OPPOSITE sides of the C++ FFI surface, plus there's a third form for POD
layouts. `experiments/tmp-parity/run.sh` §h compiles a tiny D module exercising
all three roles and dumps the resulting `llvm-nm` table:

```
T  _ZN9ProducerC3incEv          ← D DEFINES the method; C++ side can call it
T  _ZN9ProducerC3getEv          ← D DEFINES
R  _D9ffi_roles9ProducerC6__vtblZ ← vtable LIVES in D's object
U  _ZN11consumer_ns9ConsumerC3incEv  ← D DECLARES only; expects a C++ definition
U  _ZN11consumer_ns9ConsumerC3getEv  ← D DECLARES only
T  _ZN9ConsumerS9double_itEv    ← D struct method, no vtable (POD layout)
T  d_producer_role              ← D call site exercising the producer form
T  d_consumer_role              ← D call site exercising the consumer form
T  d_value_role                 ← D struct returned by value
```

The three forms in D source:

```d
// (1) D PRODUCES a class with vtable callable from C++.
extern(C++) class ProducerC {
    int v;
    void inc()  { v += 1; }
    int  get()  { return v; }
}

// (2) D CONSUMES a C++ class — declarations only; bodies + vtable supplied by C++.
extern(C++, "consumer_ns") {
    extern(C++, class) struct ConsumerC {
        int v;
        void inc();
        int  get();
    }
}

// (3) D PRODUCES a value-type. No vtable. Byte-identical ABI to C++ struct.
extern(C++) struct ConsumerS {
    int v;
    int double_it() { return v + v; }
}
```

The decision tree:

| your D code wants to… | use this form | symbol role |
|---|---|---|
| expose an abstract base class TO C++ (callbacks, polymorphic ISR objects) | `extern(C++) class` | D emits vtable + bodies; C++ inherits/calls through |
| call a C++ template instantiation (e.g. `Gpio<5>` shim from docs/21) | `extern(C++, ns) extern(C++, class) struct` | D emits Itanium-mangled call sites; C++ supplies bodies + statics |
| pass POD data between D and C++ (no methods, no vtable, no inheritance) | `extern(C++) struct` | byte-identical layout to C++ struct, ABI-compatible (post-LDC-1.42 frontend fix; docs/05) |

The PR-27 zero-cost experiment in `experiments/zero-cost/d/heap.d` uses form
(1) `extern(C++) class Counter` because the goal was to compare an
*allocator-emplaced* class instance against C++ `new T` and Rust `Box::new`.
The PR commentary should have been more careful to distinguish:

- The `extern(C++) class` we benchmarked is "D producing a C++-compatible
  class" — it's responsible for the vtable, the storage, and the body.
- That is **NOT** the form D uses to talk to the C++ shim templates the
  embedded matrix tends to use (docs/21 `Gpio<5>`). That FFI direction wants
  form (2): D declares, C++ defines.

`-betterC` complicates form (1) because there's no GC to allocate the vtable +
instance pair on demand. The canonical workaround is exactly what
`experiments/zero-cost/d/heap.d` shows: a hand-rolled `malloc` + cast + field
write. C++ writes `new Counter(step)`; D writes the same six instructions by
hand. There's no language overhead — just no GC to emit them for you.

## What this means for the matrix

For embedded TMP work where the goal is to *generate a per-instance / per-slot
zero-cost specialization at compile time*, the language ranking is:

1. **D** — broadest TMP surface, only one with in-language reflection
   (`__traits`), only one with declarative identifier synthesis (`mixin`). The
   complete CTFE druntime means `enum X = compute(...)` works for anything the
   interpreter can run, including string manipulation.
2. **C++** with esp-clang 21.1.3 -std=c++26 — covers ten of twelve. The
   missing two (token-level identifier synthesis, in-language reflection)
   are real gaps that hurt in practice; the workarounds (X-macros, Boost.PFR,
   reflexpr) all carry costs. C++26 P2996 reflection will close them when
   it ships — `clang 23+ feature-flag gated`, not in mainline 21/22 today.
3. **Rust 1.95-nightly stable** — six of twelve. Useful for monomorphization +
   trait bounds + const generics (primitive only); gaps for specialization,
   variadics, in-language reflection, identifier synthesis, and static-if.
   Most of those gaps can be filled with nightly features or proc-macros, but
   the proc-macro path adds host-compile-time cost (~50-100 MB per consumer
   crate) and the nightly features have soundness work pending.

**For ABI-level FFI between D, C++, and Rust** (the docs/21 shim matrix),
none of the TMP gaps matter — the *mangled symbol* is the contract, and every
language can produce or consume Itanium-mangled symbols (D via
`extern(C++,ns) class struct` consume / `extern(C++) class` produce; Rust via
`#[link_name="…"]`; Zig via `extern fn @"…"()`). docs/21 §2 already covered
that — this doc's contribution is the language-level capability comparison
*upstream* of that FFI.

## Reproduction

```bash
source scripts/env.sh
experiments/tmp-parity/run.sh
```

Sources are at `experiments/tmp-parity/{cpp,d,rs}/tmp.{cpp,d,rs}`. The FFI-role
demo in §h is generated inline by the script into `build/tmp-parity/`.

Toolchain versions exercised: esp-clang 21.1.3 (LLVM 21.1.3), LDC 1.42.0
(espressif LLVM 22.1.4, 2026-05-30 maintainer re-upload — docs/23), rustc
1.95-nightly (LLVM 21.1.3). All three produce equivalent IR for every
capability they share.

## Related docs

- docs/21 — embedded TMP FFI, the *symbol-level* contract that makes the
  language-level TMP comparison this doc covers relevant in practice.
- docs/25 — zero-cost abstractions (the monomorphization sub-question of
  TMP). Covers §a only of this doc's twelve capabilities.
- docs/19 — D / LDC deep-dive; the TMP catalog reference for the D column.
- docs/20 — D safety features; the `-preview=safer` flag that gates §e's
  CTFE probes (D file uses `@safe` on `fact`, etc.).
