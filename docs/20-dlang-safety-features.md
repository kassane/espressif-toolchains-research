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
| sanitizers | `--fsanitize=address\|thread\|memory\|leak\|fuzzer` | (host only; on the canonical 21.1.3 fork `--fsanitize=undefined` is also REJECTED — `Error: Unrecognized -fsanitize value 'undefined'`, same gap docs/23 recorded for the LLVM-22 upstream build, so it's an LDC frontend gap, not LLVM-version-dependent) |
| cross-compile | `-mtriple=` / `-mcpu=` / `-mattr=` | the mechanism used for Xtensa throughout this repo |

**Xtensa-verified** (esp32, `safety.sh` §e): `@fastmath` → `fmul fast double` in
the IR; `@section(".iram1.text")` → an `.iram1.text` section; `@weak` → a `W`
(weak) symbol; and `__ir!("…add i32…")` compiles embedded LLVM IR down to a real
Xtensa `add`. None of these have a DMD/GDC equivalent — they're why an
LLVM-backed D compiler is interesting for an LLVM-backend FFI study.

**Broader LDC attribute/pragma probe** (`experiments/dlang/ldc-attrs.sh` §c/d/e,
all IR-verified at the shell against the canonical 21.1.3 fork):

| LDC form | IR effect | parity analog |
|---|---|---|
| `@cold` | `cold` function attribute | clang/gcc `__attribute__((cold))`; Rust `#[cold]` |
| `@optStrategy("none")` | `noinline optnone` | clang `__attribute__((optnone))`; Rust `#[optimize(none)]` (nightly) |
| `@optStrategy("optsize")` | `optsize` | clang `__attribute__((minsize))` is "minsize"; "optsize" is the `-Os`-level default |
| `@optStrategy("minsize")` | `minsize` | clang `__attribute__((minsize))`; Rust `#[optimize(size)]` |
| `@naked` | `naked` function attribute | clang/gcc `__attribute__((naked))`; Rust `#[naked]` |
| `@llvmAttr("k","v")` | raw `"k"="v"` LLVM attribute | (no first-class parity — clang attrs are spelled, not raw) |
| `@restrict` on params | `ptr noalias` parameter | C99 `restrict`; clang `__restrict__`; Rust `&mut` (uniqueness) |
| `pragma(mangle, "name")` | symbol renamed to literal | Rust `#[link_name="…"]`; Zig `extern fn @"…"`; clang `asm("…")` |
| `pragma(inline, false)` | `noinline` function attribute | `__attribute__((noinline))`; `#[inline(never)]`; Zig `inline never` (no Zig builtin — workaround) |
| `pragma(inline, true)` | `alwaysinline` function attribute | `__attribute__((always_inline))`; `#[inline(always)]`; Zig `inline fn` |
| `pragma(LDC_intrinsic, "llvm.bswap.i32")` | direct call to `@llvm.bswap.i32` | clang `__builtin_bswap32`; Rust `u32::swap_bytes`; Zig `@byteSwap` (all compile to the same intrinsic) |
| `pragma(LDC_extern_weak)` | `declare extern_weak …` | clang `__attribute__((weak))` + extern; Rust `extern { #[linkage="extern_weak"] }` (nightly) |

The IR effect column is from `ldc-attrs.sh §(c)/(d)`. `@hidden`, `@noplt`, and
`@allocSize` are present in `ldc.attributes` but their IR effect is hard to
read at `-O2` (DCE removes never-called declarations); they're listed in the
catalog above by code, just not in this verification table.

### 1.1 `@assumeUsed` parity — `@llvm.used` (strong) vs `@llvm.compiler.used` (weak)

`@assumeUsed` (the D analog of Rust's `#[used]` and clang's
`__attribute__((used))`) pins a symbol against linker DCE. The non-obvious
finding from `ldc-attrs.sh §a`: LDC and Rust emit the **strong** form;
clang's classic `__attribute__((used))` emits the **weak** form. The strong
form survives `--gc-sections`; the weak form only stops the LLVM optimizer
from dropping the function, but the linker can still GC it.

| frontend | source | IR marker emitted |
|---|---|---|
| **LDC** | `@(ldc.attributes.assumeUsed) extern(C) int marker() {…}` | `@llvm.used = appending global [1 x ptr] [ptr @marker]` — **STRONG** |
| **Rust** | `#[used] #[no_mangle] pub static MARKER: u32 = 0xCAFE;` | `@llvm.used = appending global [1 x ptr] [ptr @MARKER]` — **STRONG** |
| **clang** | `__attribute__((used)) int marker() {…}` | `@llvm.compiler.used = appending global [1 x ptr] [ptr @marker]` — **WEAK** |
| **clang C23** | `[[gnu::retain]] int marker() {…}` | `@llvm.used = appending global [1 x ptr] [ptr @marker]` — **STRONG** (the spelling that yields the strong form on clang 13+) |
| **Zig** | `export const MARKER: u32 = 0xCAFE;` | (no `@llvm.used` marker — relies on `export` external visibility; safe on bare-metal links without `--gc-sections`) |

**Practical implication**: when you want a symbol kept across `--gc-sections`
(common for static dispatch tables, ISR vector entries, link-stamped data),
LDC's `@assumeUsed` and Rust's `#[used]` give you that directly. For clang
you need C23's `[[gnu::retain]]` — the legacy `((used))` is not enough.

**LLD version caveat (PR #24 finding).** The strong/weak split above holds
for **function symbols** under both LLD 21.1.3 (esp-clang's `ld.lld`) and
LLD 22.1.4 (`$LLD` = `$ZIG ld.lld`, the canonical linker in this repo).
For **data symbols**, however, LLD 22.1.4 GCs Rust's `#[used] pub static
MARKER` under `--gc-sections` *even though* the IR has `@llvm.used` — LLD
21.1.3 keeps it. The behaviour difference is reproducible in
`experiments/dlang/ldc-attrs.sh §f`: override the linker explicitly via
`LLD=$ESP_CLANG_DIR/ld.lld` to recover the 21.1.3 outcome. On the canonical
`$LLD` 22.1.4, `MARKER_RS` is reported as GC'd while `marker_d`
(LDC `@assumeUsed`, *function*) and `marker_cr` (clang
`[[gnu::retain]]`, *function*) both survive. Practical fallout for ISR
vector tables and similar function-symbol use cases: nothing changes. For
*data*-symbol pinning under LLD 22, wrap the data in a function (return
a `static` reference) or use a `KEEP()` directive in the linker script.

### 1.2 Compile-time file embed — `import("file")` parity matrix

D's `import("file.bin")` is a *string import* — the file content is read at
compile time and substituted as a literal. Cross-language analogs verified at
the shell against an esp32 build (`ldc-attrs.sh §b`):

| frontend | spelling | section the bytes land in (xtensa-esp-elf, `-O2`) |
|---|---|---|
| **LDC** | `static immutable string p = import("payload.bin");` (`-J <path>`) | `.rodata._D<mangled>.<sym>` (per-symbol) |
| **Zig** | `const p = @embedFile("payload.bin");` | `.rodata.str1.1` (string pool) |
| **Rust** | `pub static P: &[u8] = include_bytes!("payload.bin");` | `.rodata..Lanon.<hash>.0` (anonymous static) |
| **clang (C23)** | `const unsigned char p[] = { #embed "payload.bin" };` | `.rodata` |
| **TinyGo** | `//go:embed payload.bin\nvar p string` | `.rodata` of the linked ELF, **but only if the variable is referenced from a non-DCE-d path** — TinyGo's whole-program LTO drops unreferenced embed bytes silently (`experiments/dlang/ldc-attrs.sh` §b records this empirically) |

The mechanism is identical at the bitcode level (a constant byte-array
global); the only ergonomic difference is *what unit you embed at*: LDC and
clang see a string, Rust + Zig + Go give you a slice/array with a known
length. For the embedded-firmware case (assets, certificates, fonts, signed
blobs, baked-in config), all five give you the same thing — a `const`
`.rodata` blob with no run-time allocation.

## 2. Two evolution axes: `-preview` (à la carte) vs `--edition` (bundled)

D evolves breaking changes on two orthogonal axes — and the second is *exactly*
Rust's edition model.

### 2.0 The canonical `$LDC2` invocation: `$LDC_PE = "-preview=all --edition=2025"`

Every `$LDC2` invocation in this repo's experiments + build scripts (with the
intentional exception of the safety-probe sections in `safety.sh` §a/§b/§d/§g
that *test* a specific flag) passes the bundle defined in `env.sh`:

```bash
export LDC_PE="-preview=all --edition=2025"
```

That's `-preview=all` (every upcoming language change: dip1000/dip1008/
dip1021/safer/systemVariables/in/bitfields/fieldwise/fixAliasThis/
rvaluerefparam/nosharedaccess/fixImmutableConv/inclusiveincontracts) plus
`--edition=2025` (the highest edition LDC 1.42 accepts — 2026 was added to
DIP1052 but isn't in this build yet; `safety.sh` §b records that as
"REJECTED"). The bundle was stress-tested at the shell against every `.d`
source in the repo; the only source-level fix needed was `@system` on raw-
pointer-indexing kernels (e.g. `experiments/simd/vadd.d`) — the honest
annotation for a C-ABI buffer consumer, satisfying `-preview=safer`'s
default-safety pointer-arithmetic check.

The bundle compiles cleanly on both LDC variants: the canonical 21.1.3 fork
(`$LDC2`) AND the upstream LLVM-22 LDC (`$LDC2_UPSTREAM`) — verified in
`experiments/ldc-fork-comparison/run.sh`. So the comparison-only arm
preserves the same source surface as the canonical arm.

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

## 6. Relevant DIPs (DIP1000–DIP1052)

The [canonical DIP index](https://github.com/dlang/DIPs/blob/master/DIPs/README.md)
covers DIP1000 through DIP1052 (DIP1050 is skipped). The ones with direct
bearing on safety, FFI and editions in this doc:

| DIP | title | status | note |
|---|---|---|---|
| [1000](https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1000.md) | Scoped Pointers | Superseded¹ | escape analysis; `-preview=dip1000` (§4) |
| [1008](https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1008.md) | Exceptions and `@nogc` | Postponed | `-preview=dip1008` |
| [1021](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1021.md) | Argument Ownership | Accepted (2.092) | the *only* formal piece of `@live`; `-preview=dip1021` gates the checker (§8) |
| [1028](https://github.com/dlang/DIPs/blob/master/DIPs/rejected/DIP1028.md) | **Make `@safe` the Default** | **Rejected** | the `extern(C)`-can't-be-`@safe` FFI soundness problem (§5) |
| [1035](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1035.md) | `@system` Variables | Accepted (2.102) | `-preview=systemVariables` |
| [1038](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1038.md) | **`@mustuse`** | **Accepted** | type-only (no fns); compile-error (§7) |
| [1051](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1051.md) | Bitfields | Accepted | `-preview=bitfields` |
| [1052](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1052.md) | **Editions** | **Accepted** | the `--edition=` mechanism (§2) |

Other notable outcomes in the range: DIP1003 (remove `body` keyword), 1009
(expression-contract syntax), 1010 (`static foreach`), 1014 (struct move),
1018 (copy ctor), 1024 (shared atomics), 1029 (`throw` as fn attr), 1030 (named
args), 1034 (bottom type reboot), 1043 (shortened method syntax), 1046 (`ref` var
decls) all **Accepted**; 1027/1036 (string interpolation) **Rejected/Withdrawn**
(the implemented design came later through a separate proposal).

¹ "Superseded" is index bookkeeping — the spec text moved into the language spec;
the feature ships behind `-preview=dip1000`.

## 7. Must-use parity: `@mustuse` (DIP1038) / `#[must_use]` / `[[nodiscard]]`

Three-way comparison of "don't silently discard a return value" (`safety.sh` §f):

| | **D `@mustuse`** | **Rust `#[must_use]`** | **C++ `[[nodiscard]]`** |
|---|---|---|---|
| applies to **function** | ✗ `Error: @mustuse on functions is reserved for future use` | ✓ warns | ✓ warns (C++17) |
| applies to **type** | ✓ `Error: ignored value of @mustuse type` | ✓ warns | ✓ warns |
| `"reason"` text | — | (impl-defined) | ✓ `[[nodiscard("…")]]` (C++20) |
| severity | **compile-error** | warning (warn-by-default) | warning |
| suppress | `cast(void) expr;` | `let _ = …;` | `(void)expr;` |

D's `@mustuse` (DIP1038, Accepted; `import core.attribute : mustuse;`) is the
**strictest** — it's an error, not a warning — but the **narrowest** (type-only,
no functions). Wrap a must-use return in a `@mustuse struct Result { … }`. Rust
and C++26 are functionally equivalent to each other.

## 8. `@live`: ownership/borrow checker — what Rust's misses

`@live` (per [`spec/ob.html`](https://dlang.org/spec/ob.html) "Live Functions",
Walter Bright 2019) is D's experimental Owner/Borrowed/Readonly pointer model — a
borrow-checker-ish data-flow analysis per `@live` function. **No standalone DIP**
introduced it; [DIP1021](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1021.md)
"Argument Ownership and Function Calls" is the only formally accepted piece.

> **Empirical caveat on LDC 1.42.** The spec says the `@live` attribute alone
> enables the checker. On the LDC 1.42 / DMD 2.112 frontend bundled here, the
> checker is **silent without a preview flag** and only activates under
> `-preview=dip1021` (or `-preview=all`). Use that to see the diagnostics
> (`safety.sh` §g).

Memory-bug coverage (`safety.sh` §g — real diagnostics from each compiler):

| memory bug | **D `@live` -preview=dip1021** | **Rust safe (borrow checker)** | **C++26 static** |
|---|---|---|---|
| use-after-free | ✓ *"has undefined state and cannot be read"* | ✓ `E0505 cannot borrow … because previously dropped` | ✗ (runtime: `-fsanitize=address`) |
| double-free / double-move | ✓ *"is not Owner, cannot consume its value"* | ✓ `E0382 use of moved value` | ✗ |
| dangling ref / return-&local | ✓ *"escapes a reference to local"* | ✓ `E0515 cannot return reference to local` | ✗ |
| **leak** (forget to free) | ✓ *"is not disposed of before return"* | **✗ ALLOWED** (`std::mem::forget` is `safe` — "leaking memory is memory-safe") | ✗ |

So **D `@live` catches LEAKS that Rust's borrow checker deliberately doesn't.**
That's a genuine D-stronger-than-Rust point on the specific axis. But `@live`'s
*scope* is much narrower than Rust's: per-function, opt-in, with documented holes
(no aliasing calculus, no Rust-style generic lifetimes; exceptions defeat the
analysis — a throw between `malloc` and `free` is a leak it won't see; lambdas
escape checking; const-scope pointers aren't Owners; callers don't enforce
DIP1021 rules across the call). Walter himself calls it "minimum viable." Rust's
borrow checker runs **on all safe code**, has a full lifetime calculus + NLL,
and keeps running around `unsafe` blocks.

C++26 has **no upstream static analog** — P3081 "Core safety profiles" was *not*
adopted into C++26 (whitepaper track instead), and the alternative borrow-checker
proposal (P3390 "Safe C++") was rejected. Runtime detection via `-fsanitize=address`
remains the C++ tool.

## 9. C++26 third leg via `zig c++` (clang 21 / clang 22 reality)

C++26 was feature-frozen at **Sofia, June 2025** with Contracts (P2900),
Reflection (P2996), and the static-reflection family adopted; pattern matching
(P2688R5) was deferred to C++29; safety Profiles (P3081) went to a whitepaper
track. **Implementations lag.** Probed at the shell against three rows:

- `$ZIG c++` (canonical Zig 0.17 bundle, **clang 22.1.4 / libc++ 22**) — the
  current default in this matrix.
- `$ZIG_016 c++` (legacy Zig 0.16 bundle, **clang 21.1.0 / libc++ 21**) — the
  historical clang-21 row, kept here so the 21→22 deltas are explicit.

What each delivers on `-std=c++26 -fexperimental-library` (`safety.sh` §h):

| feature | status on clang 21 / libc++ 21 (`$ZIG_016`) |
|---|---|
| `[[nodiscard("reason")]]` | ✓ (unchanged from C++17/20) — the only safety carry-through |
| Contracts (`pre`/`post`/`contract_assert`, P2900) | ✗ *"expected function body after function declarator"* — not in clang 21 (or 22) |
| Reflection (`^^`/`std::meta::…`, P2996) | ✗ (Bloomberg `clang-p2996` fork only) |
| Pattern matching (`match`, P2688R5) | ✗ (also deferred to C++29) |
| Safety profiles (P3081) | ✗ (whitepaper track, no compiler flag) |
| **P2686R5** constexpr decomposition declarations | ✗ on clang 21 (`"cannot be declared 'constexpr'"`); **✓ on clang 22** (see re-probe below) |
| `<expected>` / `<print>` / `<flat_map>` / `<execution>` / `<ranges>` / `<format>` | ✓ (available without `-fexperimental-library`) |
| `<simd>` (P1928) / `<linalg>` (P1673) / `<hive>` (P0447) / `<contracts>` / `<generator>` | ✗ MISSING (libc++ 21 hasn't implemented them) |

**Re-probed against the canonical `$ZIG c++` (Zig 0.17, clang 22.1.4,
libc++ 22).** Only one delta moves relative to the 0.16/clang-21 column:
**P2686R5 (constexpr decomposition declarations) now compiles cleanly**
on clang 22 — the
`constexpr auto [a,b] = P{1,2};` and `pre/post`/`[[pre:]]` contracts repros
from `safety.sh` §h flip from `"cannot be declared 'constexpr'"` to rc=0.
The libc++ 22 ships `<ranges>`/`<format>` cleanly but `<simd>`/`<linalg>`/
`<contracts>`/`<hive>`/`<generator>` are still MISSING; Contracts P2900
syntax still errors (`error: Unknown Clang option: '-fcontracts'`);
Reflection P2996 (`^^S`/`std::meta::…`) still rejected
(`error: Unknown Clang option: '-freflection'`). So the C++26 frontier
(Contracts/Reflection/Pattern Matching/Profiles) **is still not in clang
22 mainline** — only Bloomberg's `clang-p2996` fork carries P2996. The
0.16 → 0.17 / clang-21 → clang-22 bump is a single-feature step (P2686),
not a frontier shift.

### esp-g++ 15.2.0 (libstdc++ 15) — the GCC side of the matrix

The Xtensa C++ producer in this repo's FFI matrix isn't only clang; **esp-g++
15.2.0** (`xtensa-esp-elf-g++` from `espressif/crosstool-NG esp-15.2.0_20251204`)
is the other one (`docs/21` §2 row 2). Probed directly at the shell with
`XTENSA_GNU_CONFIG=$(xtensa_cfg esp32) $GXX -std=c++26 -ffreestanding -c …`
(safety.sh §i records the same numbers):

| feature | esp-g++ 15.2.0 / libstdc++ 15 (freestanding, xtensa-esp-elf) |
|---|---|
| `<expected>` / `<ranges>` / `<stdfloat>` | ✓ parses (in the freestanding subset) |
| `<print>` / `<format>` / `<flat_map>` / `<flat_set>` / `<execution>` / `<generator>` / `<stacktrace>` / `<spanstream>` / `<syncstream>` / `<experimental/simd>` | ✗ *under `-ffreestanding`* — `bits/requires_hosted.h` errors `"This header is not available in freestanding mode."`; the headers DO ship on disk and parse fine without `-ffreestanding`, but `xtensa-esp-elf` is the bare-metal cross, so hosted-libstdc++ I/O won't link to newlib anyway |
| `<simd>` (P1928) / `<linalg>` (P1673) / `<hive>` (P0447) / `<contracts>` / `<mdspan>` | ✗ MISSING in libstdc++ 15 at all (not implemented upstream — same gap as libc++ 22) |
| **P2686R5** constexpr decomposition declarations | ✗ `"structured binding declaration cannot be 'constexpr'"` — same regression as clang 21 |
| Contracts P2900 (`pre`/`post`) | ✗ `"expected initializer before 'pre'"` (no `-fcontracts` flag — `unrecognized command-line option`) |
| Reflection P2996 (`^^S`) | ✗ `"unrecognized command-line option '-freflection'"` |
| Pattern matching P2688R5 (`match`) | ✗ `"expected ';' before 'match'"` |

Two findings worth pinning. **First**, both C++ producers in the matrix
(esp-clang 21.1.3 and esp-g++ 15.2.0) **agree** on every C++26-frontier
feature: P2686R5, Contracts, Reflection, Pattern Matching are all
rejected by both. The single-feature delta on clang 22 (P2686) doesn't
apply on the GCC side — esp-g++ stays on the regression. **Second**,
the C++23 hosted-library headers (`<print>`/`<format>`/`<flat_map>`/`<execution>`/
`<generator>`/`<stacktrace>`/`<spanstream>`/`<syncstream>`) **parse** under
hosted mode but are blocked under `-ffreestanding` by libstdc++'s
`bits/requires_hosted.h` — and `-ffreestanding` is the canonical embedded
compile mode. The "header is there but you can't include it" failure mode
is purely the libstdc++ freestanding subset, not GCC 15. The C++26 outright
gaps (`<simd>`/`<linalg>`/`<hive>`/`<contracts>`/`<mdspan>`) are libstdc++
15 features that haven't been implemented yet upstream — same gap libc++ 22
has on the clang side.

**What `-fexperimental-library` actually gates** (per the
[libc++ user docs](https://libcxx.llvm.org/UserDocumentation.html)): `<execution>`
(PSTL), `std::chrono::tzdb`/time zones, `<syncstream>`, and libc++'s **hardening
assertion semantics** (`ignore`/`observe`/`quick-enforce`/`enforce` —
contracts-shaped, but *not* P2900). It does **not** gate `<expected>`/`<print>`/
`<flat_map>`/`<hive>`/`<simd>`; those are individual `Cxx2cPapers.csv` line items
shipped (or not) on their own. On this LDC-adjacent clang 21 build, the flag is
effectively a no-op for everything we tried — but it is the correct flag for any
of the four it does gate, and is forward-compatible.

So the third leg gives us only `[[nodiscard]]` for the parity battery; the
borrow-checker / static-safety story remains D `@live` vs Rust.

## Verdict — Rust × D × C++26 memory safety

| | **Rust** | **D / LDC** | **C++26 (clang 21 reality)** |
|---|---|---|---|
| default | **safe** | `@system` (unchecked) | unchecked (Profiles not in C++26) |
| opt-out / bridge | `unsafe` block (scoped) | `@trusted` (whole-function) | — (no annotation; `-fsanitize=` runtime) |
| escape/lifetimes | full borrow checker (aliasing ⊕ mutability + NLL) | DIP1000 escape only; `@live` adds per-fn Owner/Borrowed | none upstream |
| **leak** detection | ✗ (`mem::forget` is safe) | ✓ (`@live` requires disposal) | ✗ |
| unsafe-op battery (§3) | rejects 8/8 | rejects 7/8 (reinterpret gap) | none rejected statically |
| must-use (§7) | warn (fn+type) | error (type-only) | warn (fn+type) |

Rust is **broadest** (safe-by-default, full borrow checker on all safe code,
block-scoped `unsafe`); D is **narrower but strictest where it bites** (compile-
error `@mustuse`, leak-catching `@live`) — but opt-in, whole-function `@trusted`,
and a documented-incomplete OB checker. C++26 in clang 21 is the **weakest** in
practice: the safety paper trail (Contracts, Reflection, Profiles) hasn't landed,
so it's still effectively C++17/20 — `[[nodiscard]]` and runtime sanitizers. For
this repo's cross-language FFI the conclusion stands: D `@safe` can't cover the
FFI boundary (DIP1028 / §5), so `@trusted` the foreign calls and `@safe` the rest.

