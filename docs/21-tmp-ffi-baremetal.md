# 21 — Embedded template-metaprogramming FFI across every FFI-matrix toolchain

All FFI-matrix toolchains — **gcc, esp-clang, zig, ldc2, rustc** — can
participate in the **same C++-templated FFI on Xtensa**, linked into one esp32
ELF, because the Itanium C++ ABI is shared (and matches the shared LLVM Xtensa
backend). The bridge is the *raw mangled symbol*: every consumer language has a
syntax to reference an exact Itanium name, so a C++ template instantiation
becomes a normal linker-resolved symbol that any of them can call. TinyGo
(docs/24) is excluded — Go has no template/generic-as-Itanium-symbol story
and TinyGo's `.o`s carry their own runtime; the matrix pattern doesn't apply.

Reproduce with `experiments/dlang/tmpffi.sh`. All output below is real.

## 1. The sample: a zero-cost embedded "shim" template

```cpp
namespace shims {
    template<int Pin>
    class Gpio {
    public:
        static int state;
        static void set()    noexcept { state = 1; }
        static void clear()  noexcept { state = 0; }
        static int  read()   noexcept { return state; }
        static int  toggle() noexcept { state ^= 1; return state; }
    };
    template<int Pin> int Gpio<Pin>::state = 0;
    template class Gpio<5>;
    template class Gpio<13>;
}
```

This is the embedded-canonical *shim* pattern: a header-only class template
parameterized by a slot/pin/instance index. Each instantiation `Gpio<N>` has its
own static `state`, so dispatch on the pin number is purely compile-time. No
vtable, no runtime branch, no overhead. Common uses: register-bank
abstractions, peripheral wrappers, per-channel counters/locks/queues.

## 2. Five toolchains, one ELF — the FFI matrix

The C++ producer's mangling is the same Itanium across compilers:
`_ZN5shims4GpioILi5EE3setEv` = `shims::Gpio<5>::set()`. (`Li5E` = literal int 5.)
Every other language references the symbol verbatim, no glue:

| role | language | toolchain | how the symbol is named |
|---|---|---|---|
| provider | C++ | **esp-clang 21.1.3** | `template class Gpio<5>;` (explicit instantiation) |
| provider (alt) | C++ | **gcc 15.2.0** | same source compiles to *byte-identical* Itanium symbols |
| consumer | D | **LDC 1.42-git (espressif LLVM 21.1.3; docs/23)** | `extern(C++,"shims") extern(C++,class) struct Gpio(int Pin)` |
| consumer | Rust | **rustc 1.95-nightly (LLVM 21.1.3)** | `#[link_name="_ZN5shims4GpioILi5EE3setEv"] fn pin5_set();` |
| consumer | Zig | **Zig 0.16 (LLVM 21.1.0)** | `extern fn @"_ZN5shims4GpioILi5EE3setEv"() callconv(.c) void;` |

Link with `ld.lld -T experiments/ffi-matrix/xtensa.ld` and the result is one esp32
ELF with **0 undefined symbols**:

```
tmpffi.elf: undefined=0  (5 toolchains, one image: gcc could swap in for clang)
```

The D side uses the syntax the user-provided sample shows — `extern(C++,
"namespace")` + `extern(C++, class) struct T(int Slot)` + an `alias` for each
instantiation — and LDC produces the byte-identical Itanium mangling. For the
cases D's template language can't express (partial specialization, SFINAE,
defaulted args, overloads), `pragma(mangle, "_ZN…")` on a plain `extern(C++)`
declaration spells the symbol literally — the fallback you reach for when
auto-mangling can't. The Rust analog is `#[link_name = "_ZN…"]`; the Zig analog
is `extern fn @"_ZN…"` (string-identifier syntax).

## 3. Baremetal advantages — why TMP for embedded?

Two things matter on a 320-KB-RAM micro: code size and dispatch cost.
`llvm-nm --print-size` on the esp-clang object:

```
   4 B  _ZN5shims4GpioILi13EE5stateE   (static int per instantiation)
   4 B  _ZN5shims4GpioILi5EE5stateE
  12 B  _ZN5shims4GpioILi13EE4readEv   (read())
  12 B  _ZN5shims4GpioILi5EE4readEv
  14 B  _ZN5shims4GpioILi13EE3setEv    (set())
  14 B  _ZN5shims4GpioILi13EE5clearEv
```

Each `Gpio<N>::set/read/clear/toggle` is its **own** small leaf function with
its own static cell — fully inlinable, no `if (pin == …)` branch, no vtable.
Compared with a runtime-polymorphic `class IGpio { virtual void set() = 0; }`
the win is concrete: no vtable, no indirect call (Xtensa `callx8`), no
per-call branch on the pin number. The shim *pattern* is the standard way to
expose a fixed, compile-time-known set of hardware instances at zero cost.

D's `__traits` + `mixin` + `static foreach` give the same compile-time
reflection power C++26 P2996 will offer once it lands. Today:

```d
struct Periph { int base; int irq; int prio; }
pragma(msg, "Periph fields: ", __traits(allMembers, Periph));   // compile-time
static foreach (m; __traits(allMembers, Periph))
    mixin(`printf("p.` ~ m ~ `=%d\n", p.` ~ m ~ `);`);          // codegen
```

prints `Periph fields: AliasSeq!("base", "irq", "prio")` at compile time and
generates per-field code at runtime — exactly what `[: members_of(^^T) :]` is
supposed to do in C++26.

## 4. LLVM-22 binutils: cross-frontend IR merge

The **`ldc-developers/llvm-project`** tarball (`llvm-22.1.2-linux-x86_64.tar.zst`
— **not** `ldc-developers/ldc`, which is the D compiler) ships LLVM 22.1.2 core
binutils (`llvm-link`, `opt`, `llvm-dis`, `llc`) without a clang. esp-clang
doesn't ship `llvm-link`, and the host's is LLVM 18 (rejects post-18 IR), so
this *was* the practical way to merge IR across frontends. With the
espressif-fork LDC (docs/23) now on the same 21.1.3 as esp-clang/rust, the
LLVM-22 binutils are only needed for the upstream-LDC comparison
(`experiments/ldc-fork-comparison`); for canonical 5-frontend merges,
esp-clang's own 21.1.x binutils suffice. The numbers below predate the swap
and are kept for reproducibility. From `tmpffi.sh §g`:

```
llvm-link (LLVM 22.1.2 binutils) rc=0 — merged defines: 11
```

`shims.ll` (clang/Xtensa) + `d_caller.ll` (LDC) + `rust.ll` (rustc) merged into a
single 11-function module — three frontends, one module, ready for `opt` or
`llc` (see docs/04 for the broader IR-mix story).

## 5. C++26 reality on the C++ compilers we have

> `esp-clang 21.1.3 -std=c++26`:
> `decomposition declaration cannot be declared 'constexpr'`

Even the *one* core-language addition clang 22 lands over 21 — **P2686R5
constexpr structured bindings** — is missing from esp-clang. The Sofia-2025
C++26 frontier (Contracts P2900, Reflection P2996, Pattern Matching P2688,
Profiles P3081) is **not** in clang 21 or the 22.x mainline (Bloomberg's
`clang-p2996` fork has reflection only). The `ldc-developers/llvm-project` 22.1.2
tarball ships *no clang at all* (only LLVM core binutils), so even upgrading the
tarball wouldn't put C++26 features on the Xtensa C++ producer — that requires
the official `LLVM-22.1.2-Linux-X64.tar.xz` (1.94 GB), out of scope here.

The pragmatic baremetal-D conclusion: don't wait for C++26 contracts/reflection
to land in clang to write safer embedded code — D ships the same capabilities
**today**:
- **Static borrow-checker**: `@safe` + `@live` + `-preview=dip1021` (docs/20 §8)
  — catches use-after-free, double-free, dangling and **leaks** that Rust's
  borrow checker doesn't.
- **Compile-time reflection**: `__traits(allMembers, T)` + `mixin` + `static foreach`
  — what C++26 P2996 is supposed to provide (docs/20 §3 / this doc §3).
- **Mangled-symbol FFI** to any C++ template instantiation: `extern(C++, class)
  struct T(NTTP)` for the regular cases, `pragma(mangle, "_ZN…")` for what TMP
  can't express.

## Verdict

The shim-template pattern is **cross-language by construction** on the shared
LLVM Xtensa backend — pick any C++ compiler in the matrix as the provider, pick
any of {D, Rust, Zig} as the consumer, and they all link into one esp32 ELF
because they share the Itanium C++ ABI. Templates monomorphize into
per-instantiation symbols with their own state, which is the ideal cost
profile for baremetal. C++26's *would-have-been-nice* safety features aren't
shipping in the compilers we have; D ships its equivalents today, so for an
ESP32 polyglot project the practical safety story runs through D's `@safe` /
`@live` / `__traits`, not through C++26.
