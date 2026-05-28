# 19 — D / LDC as a 5th LLVM frontend (deep dive)

LDC (the LLVM D compiler) is a **third non-C LLVM frontend** for Xtensa,
alongside Rust and Zig. How does D's C/C++ FFI and its ABI lowering compare on
the espressif backend? Reproduce with `experiments/dlang/run.sh`; the runtime
PASS/FAIL matrix (D added to all four other languages) is `scripts/run-qemu.sh`.

## 1. Identity — now on the espressif fork (see docs/23 for the swap)

| | value |
|---|---|
| compiler | **LDC 1.42.0-git-04a6c8b** (DMD v2.112.1 frontend) |
| backend | **espressif/llvm-project LLVM 21.1.3** — same family as esp-clang and rustc |
| source | [`kassane/esp-idf-dlang`](https://github.com/kassane/esp-idf-dlang/releases/tag/xtensa-toolchain) `xtensa-toolchain` (static-musl); the upstream `ldc-developers/ldc` CI build (LLVM 22.1.2) remains as `$LDC2_UPSTREAM` for the comparison in docs/23 |
| Xtensa | **first-class** in the espressif fork: `-mcpu=esp32`/`s2`/`s3` all recognized natively |
| bare-metal | **`-betterC`** (no druntime/Phobos/GC/ModuleInfo) — D's analogue of Rust `no_std` / Zig `freestanding` |
| invocation | `ldc2 -mtriple=xtensa-esp-elf -mcpu=esp32 -betterC -c` |

D is a *systems* language with first-class C and C++ interop, so the FFI surface
is the richest in this matrix (see §5). With the espressif-fork LDC it now rides
the **same backend family** as clang/rust/zig (all 21.1.x); the
upstream-LLVM-22 path is documented in [docs/23](23-ldc-espressif-fork.md).

## 2. The headline: D mis-lowers **every** by-value aggregate

D's frontend marks **all** struct arguments `byval(ptr)` and **all** struct
returns `sret` — i.e. *explicitly indirect* in the IR — then defers the actual
ABI to the LLVM backend. The Xtensa (and RISC-V) backends lower `byval`/`sret`
**by memory**, which does **not** match the platform C ABI's register passing.
This is the same *root cause* as Zig (frontend defers to the backend instead of
implementing the C ABI), but D's divergence is **broader** because it marks the
aggregates indirect unconditionally.

The three frontends emit three different IRs for the same `Point`/`Blob`:

| fn | **clang** (C-ABI reference) | **Zig** | **D / LDC** |
|----|------|-----|---|
| `point_dot(Point,Point)` | `([2 x i32],[2 x i32])` → regs | `(%Point,%Point)` direct | `(ptr byval(%Point), ptr byval(%Point))` |
| `make_point→Point` | `→[2 x i32]` regs | `→%Point` direct | `(ptr sret(%Point), …)` |
| `blob_sum(Blob)` | `([6 x i32])` → a2..a7 | `(%Blob)` direct | `(ptr byval(%Blob))` |

clang flattens in-frontend (`[N x i32]` → registers); Zig hands LLVM a *direct*
aggregate value (the backend matches the C ABI for align-4, breaks align-1); D
hands LLVM an *indirect* pointer, which the backend always passes in memory.

**Machine ABI, Xtensa esp32 (disassembly).** clang's `c_point_dot` multiplies
straight out of registers — `mull a8, a5, a3` (Point `b`=a4/a5, `a`=a2/a3). D's
`d_point_dot` instead does `l32i.n a8, a1, 32` — it reads the arguments off the
**incoming stack** (`a1`=SP), where nothing was placed. `d_make_point` treats
`a2` as a hidden `sret` pointer and stores `x`/`y` through it, while clang
returns the 8-byte Point in `a2:a3` (no pointer) — so a C caller's `x` value is
misread as a destination address.

### Runtime (qemu) — D added to the full matrix

```
Xtensa (sim/dc233c)                       RISC-V (esp32c3, virt)
  scalar add      c cpp rs zig d   all ok   scalar add    all ok incl. d
  point_dot       c rs zig ok; d FAIL(4548) point_dot     c rs ok; zig FAIL; d SKIP*
  blob_sum        c cpp rs ok; zig FAIL;     blob_sum      c cpp rs zig ok; d OK(300)
                  d FAIL(695)
  blob_sum BY PTR c zig d  all ok            blob_sum BYPTR  all ok
```

- **Xtensa**: D fails **both** `point_dot` (align-4) *and* `blob_sum` (align-1) —
  Zig fails only the align-1 one. D's break is alignment-*independent*.
- **RISC-V** (`*` D's small-struct `byval` becomes a real pointer arg; it would
  dereference clang's register *value* `1` as an address → wild load + fault, so
  the harness gates `d_point_dot` to Xtensa). But D's **`blob_sum` PASSES** on
  RISC-V: a >16-byte struct is passed **by reference in the RISC-V C ABI itself**,
  so D's `byval` pointer *matches* clang there. The asymmetry is the proof: D is
  correct exactly when the C ABI is *also* indirect (RISC-V large struct; Xtensa
  >16-byte `sret` return), and wrong when the C ABI uses registers.

**Mitigation (runtime-verified): pass structs by pointer.** A pointer is a plain
scalar in `a2`, so `blob_sum_ptr(const Blob*)` returns `300` for C, Zig **and**
D on both arches. Across any D↔{C,Rust,Zig} boundary, pass aggregates by pointer.

**Bitfields fall in the same trap.** D supports C-style bitfield syntax
natively inside `extern(C) struct { uint a : 4; uint b : 4; uint c : 8; }`
(no `-preview=bitfields` flag needed on LDC 1.42-git), but the IR for a
caller forwarding such a struct is `byval(%s.T) align <N>` — same as every
other aggregate. clang for the same 16/32/64-bit bitfield total flattens to
a single `i32`/`i32`/`[1 x i64]` scalar arg, and Zig's `packed struct(uN)`
with explicit backing matches clang. `experiments/abi-structs/sweep.sh`'s
bitfield rows pin this empirically. So the docs/05 universal-aggregate
rule applies to bitfields too — pass them by pointer across an FFI boundary.

## 3. The LDC-Xtensa literal-pool bug — fixed on the espressif fork

On the **upstream-LLVM-22** LDC a direct `ldc2 -c` Xtensa object failed to
link: `ld.lld: … R_XTENSA_SLOT0_OP: … is not aligned to 4 bytes`. The LLVM-22
integrated assembler mis-laid the `l32r` literal pool under function-sections:
the `__muldf3` address that `d_mul_f64` loads was emitted into the *preceding*
function's `.text.d_mul_f32` section at an unaligned offset (`+0x11`), and
`l32r` requires a 4-aligned target. The workaround was to emit textual asm
(`ldc2 -output-s`), strip `.cfi_*` (the espressif Xtensa assembler rejects
CFI), and re-assemble with esp clang's LLVM-21 MC.

The **canonical espressif-fork LDC** (LLVM 21.1.3) lays the `.literal.<fn>`
section correctly under function-sections, so direct `ldc2 -c` produces a
linkable object — `scripts/build-ffi.sh:ldc_xtensa_obj()` is now a one-liner.
`experiments/ldc-fork-comparison §(c)` reproduces both behaviors side by side
([docs/23](23-ldc-espressif-fork.md)). RISC-V has no literal pool
(`auipc`/`jalr`), so a direct object always linked there.

## 4. Scalars & linking — full parity

For every scalar in the C contract (`i32`/`i64`/`f32`/`f64`/pointer/callback) D
agrees at the machine level: host runs PASS and qemu scalars PASS for every
FFI-matrix language. `double` multiply is the soft-float `__muldf3` libcall on esp32 (HW
float is single-precision only) — the same libcall clang/zig/rust emit, resolved
from `libclang_rt.builtins.a`. The D object **links into the one Xtensa ELF with
the other four** (clang/gcc/rust/zig) under `ld.lld`, GNU `ld`, and the mixed
combos — **0 undefined symbols** across all three linker variants.

## 5. C and C++ FFI — the richest surface in the matrix

D selects linkage with `extern(...)`. Verified emitted/mangled symbols:

| D declaration | symbol | demangled |
|---|---|---|
| `extern(C) d_c_add` | `d_c_add` | (C, unmangled) |
| `extern(C++) cpp_add` | `_Z7cpp_addii` | `cpp_add(int, int)` |
| `extern(C++, "espffi") ns_add` | `_ZN6espffi6ns_addEii` | `espffi::ns_add(int, int)` |
| `extern(C++) vec_dot(ref const Vec2, …)` | `_Z7vec_dotRK4Vec2S1_` | `vec_dot(Vec2 const&, Vec2 const&)` |

So D emits **byte-identical Itanium C++ mangling** (`_Z…`, namespaced `_ZN…`,
`const&` refs with `S1_` substitution) — the same names C++ and the docs/12
mangled-FFI work link against. Two D-specific rules:

- A D **`struct` is a value type**, a D **`class` is a reference type** — matching
  C++ `struct`/`class` value-vs-polymorphic semantics. For `extern(C++, class)`
  vs `extern(C++, struct)` you pick the aggregate kind for mangling (use `class`
  if the C++ type has virtual functions, `struct` if none).
- `--extern-std=` (`c++98`…`c++23`, **default** `c++11`) sets the C++ standard for
  mangling compatibility; basic signatures mangle identically across them
  (`f(S)` → `_Z1f1S`), it matters for `std::` types.

**`-HC`: D generates a C++ header from its `extern(C++)` decls** — `extern "C"`
prototypes, `namespace espffi { … }`, and a real `struct Vec2 final { float x,
y; Vec2(); … };` with constructors and `const Vec2&` refs. Round-trip verified:
a C++ TU that `#include`s the generated header **calls back into D** and prints
`cpp_add=42 espffi::ns_add=42 vec_dot=12.5`. (Templates differ syntactically —
C++/Rust `<T,N>`, D `(T,N)` — but that's source, not ABI.)

## 6. Cross-language LTO — D + clang works (and now with no skew)

Unlike clang↔zig (blocked by a 21.1.0-vs-21.1.3 bitcode skew, docs/04/17),
**clang + D LTO links and inlines across the boundary** — and on the
canonical espressif-fork LDC there's no skew at all (both producers are
LLVM 21.1.3). The `ld.lld` LTO reader merges `d_lto`+`c_lto` and constant-folds
to `addi.n a2, a2, 2` (`x+2`). The same test on the upstream-LDC arm (LLVM 22.1.2
bitcode → 21.1.3 LTO reader) historically also worked despite the version skew —
see [docs/23](23-ldc-espressif-fork.md). Object-level FFI, as always, has no
version constraint. The **LLVM 22.1.2 binutils** (`$LDC_LLVM_DIR`,
`setup.sh LLVM22=1`) remain in the box only for the upstream-LDC arm of the
comparison; for canonical IR work, esp-clang's 21.1.x binutils handle every
frontend's post-18 IR (datalayout is now byte-identical across all four
LLVM frontends — no llvm-link warning).

## 7. Tooling parity with clang

- **`--help-hidden`** lists **2784** options — the full clang/LLVM-style hidden
  help (the goal's note: "like clang has `--help-hidden`").
- **`--link-internally`** links with LDC's **in-process LLD** (no external
  linker): the `lld:` diagnostics confirm it runs (only host libs are missing in
  this sandbox). LDC also forwards bare LLVM `cl::opt`s directly (no `-mllvm`).

## 8. Known LDC-Xtensa issues (tracked upstream)

- **ldc #5091 "ICE with xtensa backend"** (OPEN): the Xtensa
  backend ICEs when optimization (`-O1`, needed for code size) is combined with
  **exception handling** (`-mtriple=xtensa-none-elf -mattr=+density,+mul16,
  +mul32,+div32,+windowed -O1`). Avoid by disabling EH (`-betterC` does) or opt.
- **ldc #4919 "Missing default LLVM `cpu-features` in some targets"** (OPEN
  upstream; **fixed for esp32-s2/s3 on the espressif fork**): the upstream-LLVM
  LDC only knows `-mcpu=esp32`; `esp32s2`/`s3` are *"not a recognized
  processor"* and fall back to generic Xtensa, so `a*b` becomes an `__mulsi3`
  libcall. The fork ships LLVM with all three esp32 CPUs as first-class values
  (`experiments/ldc-fork-comparison §(d)`); `env.sh:ldc_xtensa_flags` still
  pins an explicit `-mattr=` mirroring esp-clang's feature set for
  self-documentation and to make the same flag string drive both LDC arms in
  the comparison.

## Verdict

D/LDC slots in as a **5th frontend on the shared backend** and is a strong C/C++
FFI citizen: scalars at parity, object-level linking with all four others (0
undef), **byte-identical Itanium mangling**, C++-header generation (`-HC`) with a
verified C++→D round-trip, and **working cross-language LTO with clang**
(same-21.1.3 since docs/23, so no skew). The caveat that survives is
**by-value aggregates** — D marks *every* struct `byval`/`sret`, so it diverges
from the register-based Xtensa C ABI more broadly than Zig (both `point_dot` and
`blob_sum`; on RISC-V the small struct even faults). Pass structs **by
pointer**. Crucially, this bug is **frontend-side**: both the canonical
espressif-fork LDC (LLVM 21.1.3) and the upstream-22 LDC produce the identical
broken IR ([docs/23](23-ldc-espressif-fork.md) §(h)), and the same family of
narrow-target-blind frontend bug shows up on MOS 6502 too
([kassane/dlang-mos-hello-world#1](https://github.com/kassane/dlang-mos-hello-world/issues/1),
wontfix). So the fix would need to land in LDC's DMD-ABI lowering, not in a
downstream LLVM fork. The historical literal-pool link bug is **gone** on the
fork — direct `ldc2 -c` works (§3).

**See also [docs/20](20-dlang-safety-features.md)** for LDC's exclusive features
(`@fastmath`/`@section`/`@weak`/inline LLVM IR), the `-preview=`/`--edition=`
evolution axes (the latter mirrors Rust editions), and a head-to-head `@safe` ⇄
Rust memory-safety comparison (incl. why DIP1028 keeps `@safe` off-by-default at
the FFI boundary).
