# 20 — D/LDC: exclusive features, preview/edition axes, and `@safe` ⇄ Rust parity

docs/19 added D/LDC as a 5th frontend and looked at its FFI/ABI. This doc goes
deeper into what makes LDC *distinct*: its LLVM-exclusive features, its two
language-evolution axes (`-preview` and `--edition` — the latter mirroring Rust
editions), and its memory-safety model (`@safe`), compared head-to-head with
Rust. Reproduce with `experiments/dlang/safety.sh` (all output below is real).

## 1. LDC-exclusive features (the LLVM bridge)

LDC exposes LLVM in ways stock DMD/GDC can't. Verified present in the installed
LDC 1.42 (`ldc/attributes.di`, `ldc/llvmasm.di`, `ldc/intrinsics.di`):

| feature | form | what it does |
|---|---|---|
| fast-math | `@fastmath` / `--ffast-math` | sets LLVM fast-math flags on FP ops |
| code placement | `@section(".iram1.text")` | put a symbol in a named section (ESP IRAM/DRAM) |
| weak symbols | `@weak`, `pragma(LDC_extern_weak)` | weak linkage |
| keep-alive | `@assumeUsed` | pin a symbol against linker GC |
| opt control | `@optStrategy("none"\|"optsize"\|"minsize")`, `@cold` | per-function optimization (`@hot` does *not* exist) |
| raw LLVM attr | `@llvmAttr("key","val")`, `@restrict` (param `noalias`) | unchecked LLVM function/param attributes |
| **inline LLVM IR** | `pragma(LDC_inline_ir)` → `__ir!(code,R,P...)` / `__irEx` | embed raw LLVM IR as a function body |
| LLVM intrinsics | `pragma(LDC_intrinsic,"llvm.…")` (`ldc.intrinsics`) | bind any LLVM intrinsic directly |
| atomics/fences | `LDC_atomic_load/store/rmw/cmp_xchg`, `LDC_fence` | low-level atomic ops |
| sanitizers | `--fsanitize=address\|thread\|memory\|leak\|fuzzer` | (host; `undefined` rejected on this LLVM-22 build) |
| cross-compile | `-mtriple=` / `-mcpu=` / `-mattr=` | the mechanism used for Xtensa throughout this repo |

**Xtensa-verified** (esp32, `safety.sh` §e): `@fastmath` → `fmul fast double` in
the IR; `@section(".iram1.text")` → an `.iram1.text` section; `@weak` → a `W`
(weak) symbol; and `__ir!("…add i32…")` compiles embedded LLVM IR down to a real
Xtensa `add`. None of these have a DMD/GDC equivalent — they're why an
LLVM-backed D compiler is interesting for an LLVM-backend FFI study.

## 2. Two evolution axes: `-preview` (à la carte) vs `--edition` (bundled)

D evolves breaking changes on two orthogonal axes — and the second is *exactly*
Rust's edition model.

**`-preview=<name>`** turns on individual not-yet-default features (`-preview=all`
enables every one; there's a matching `-revert=`). From `ldc2 -preview=h`, the
safety-relevant ones are `dip1000` (scoped pointers / escape analysis), `safer`
(more checks by default), `nosharedaccess`, `fixImmutableConv`, and
`systemVariables` (DIP1035). Others: `dip1008` (`@nogc` Throwable), `dip1021`
(mutable fn args), `bitfields`, `fieldwise`, `in`, `rvaluerefparam`.

**`--edition=<NNNN>`** (DIP1052 "Editions", *Accepted*) is a coherent, opt-in
*bundle* of mature breaking changes, selectable per-module (`module m 2025;`),
with cross-edition interop and no ecosystem split — conceptually identical to
Rust's 2015/2018/2021/2024 editions. Empirically the valid range is **2023–2025**
(2022 and 2026 are rejected). DIP1052 names default-`@safe` and default-`private`
as *example* future edition changes but does not pin which land in 2024, and on
this build `--edition=2024` does **not** flip default safety — that is currently
the separate `-preview=safer` axis (§3).

```
default safety   : builds (functions are @system by default)
-preview=safer   : pointer arithmetic is not allowed in a function with default safety
--edition=2023..2025 : accepted   2022/2026 : REJECTED
```

## 3. `@safe` ⇄ Rust: the unsafe-op parity battery

D's safety is a function-attribute model: **`@system`** (the default — unchecked),
**`@safe`** (statically checked), **`@trusted`** (a manually-audited bridge that
is `@safe`-callable — the analogue of a vetted `unsafe` block). The same set of
memory-unsafe operations, in D `@safe` vs Rust safe (`safety.sh` §c, real errors):

| operation | D `@safe` | Rust safe |
|---|---|---|
| raw pointer index `p[i]` | ✗ rejected | ✗ `unsafe` (E0133) |
| pointer arithmetic `p+1` | ✗ rejected | ✗ `unsafe` |
| `int`→pointer cast + deref | ✗ rejected | ✗ `unsafe` |
| **same-size pointer reinterpret** `*cast(float*)p` | **✓ ALLOWED** | ✗ `unsafe` |
| mutable global (`__gshared` / `static mut`) | ✗ rejected | ✗ `unsafe` |
| call `@system` / `unsafe fn` | ✗ rejected | ✗ `unsafe` |
| inline asm | ✗ rejected (needs `@trusted`) | ✗ `unsafe` |
| union pointer/field pun | ✗ rejected | ✗ `unsafe` |

**Near-parity: D `@safe` rejects 7 of 8.** The lone gap is the same-size pointer
*reinterpret* (`int*`→`float*` deref), which D `@safe` permits but Rust requires
`unsafe` for. Everything else needs `@trusted` (D) / `unsafe` (Rust). Rust emits
`E0133 "requires unsafe"` for every op in the battery.

## 4. Escape analysis: DIP1000 vs the borrow checker

Returning the address of a local is caught by both, but the models differ
(`safety.sh` §d):

```
D @safe (no dip1000):     taking the address of stack-allocated local `x` is not allowed in a @safe function
D @safe -preview=dip1000:  returning `& x` escapes a reference to local variable `x`
Rust borrow checker:       cannot return reference to local variable `x`  (E0515)
```

`-preview=dip1000` (`scope`/`return scope`/`return ref`) upgrades D from a blunt
"no address-of-locals in `@safe`" to precise *escape* analysis — stack refs/slices
can now be passed `@safe`-ly as long as they don't escape. **But the model is
strictly weaker than Rust's borrow checker:** DIP1000 tracks *escape* only, not
*aliasing* (Rust's aliasing-xor-mutability) and not data-race freedom. And a real
footgun Rust lacks: `scope`/`return scope` annotations are *unchecked* inside
`@system`/`@trusted` bodies yet *assumed* at `@safe` call sites — a `@trusted`
author can silently break the guarantee. Rust's `unsafe` is block-scoped and the
borrow checker still runs around it; D's `@trusted` is whole-function.

## 5. Why `@safe` isn't the default — and the FFI tie-in (DIP1028)

D is `@system`-by-default; **DIP1028 "Make @safe the Default" was *rejected*.** The
decisive objection is *exactly this repo's subject*: marking `extern(C)` /
`extern(C++)` declarations `@safe` by default is **unsound** — function safety is
not part of the symbol mangling, so an unverified foreign prototype (a C/Rust/Zig
function reached over FFI) would silently acquire a `@safe` it never earned. So
the cross-language FFI boundary is precisely where D's safety model cannot be
automatic: you must hand-audit it. The practical rule for an ESP polyglot project
is therefore **mark the D side of each FFI call `@trusted`** (the ABI is already
verified — docs/03/19) and keep the D internals `@safe`. Movement toward
safe-by-default continues via `-preview=safer` and editions (DIP1052 cites it as
a goal), but the FFI-mangling problem is why it can't just be flipped.

## 6. Relevant DIPs

| DIP | title | status | note |
|---|---|---|---|
| [1000](https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1000.md) | Scoped Pointers | Superseded¹ | escape analysis; `-preview=dip1000`, slated to become default |
| [1008](https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1008.md) | Exceptions and `@nogc` | Postponed | `-preview=dip1008` |
| [1021](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1021.md) | Argument Ownership | Accepted (2.092) | `-preview=dip1021` |
| [1028](https://github.com/dlang/DIPs/blob/master/DIPs/rejected/DIP1028.md) | **Make `@safe` the Default** | **Rejected** | the `extern(C)`-can't-be-`@safe` FFI soundness problem (§5) |
| [1035](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1035.md) | `@system` Variables | Accepted (2.102) | `-preview=systemVariables` |
| [1052](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1052.md) | **Editions** | **Accepted** | the `--edition=` mechanism (§2) |

¹ "Superseded" is index bookkeeping — the spec text moved into the language spec;
the feature ships behind `-preview=dip1000`.

## Verdict — Rust vs D memory safety

| | **Rust** | **D / LDC** |
|---|---|---|
| default | **safe** | `@system` (unchecked) |
| opt-out / bridge | `unsafe` block (scoped) | `@trusted` (whole-function) |
| escape/lifetimes | full borrow checker (aliasing ⊕ mutability + lifetimes) | DIP1000 escape only — no aliasing/data-race model |
| toward stricter default | already there | `-preview=safer`, editions (DIP1052) |
| unsafe-op battery (§3) | rejects 8/8 | rejects 7/8 (reinterpret gap) |

Rust is **stronger** (safe-by-default, block-scoped `unsafe`, a real borrow
checker that keeps running around `unsafe`); D is **more gradual / lower-friction**
(opt-in, incremental, `-preview=safer` to tighten the default) but its lifetime
model is escape-only and `@trusted` is coarser. On the concrete operation battery
they are at near-parity. For this repo's cross-language FFI: D `@safe` cannot
cover the FFI boundary by design (DIP1028/§5) — wrap each foreign call in
`@trusted` over an ABI you've verified, and keep the rest `@safe`.
