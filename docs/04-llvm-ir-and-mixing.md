# 04 — LLVM IR comparison & mixing

## Same target, same datalayout (every LLVM frontend, since docs/23/24)

Every LLVM frontend now emits the identical datalayout for the Xtensa esp32
target; only the triple differs:

```
clang  : target datalayout = "e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32"
         target triple      = "xtensa-esp-unknown-elf"
rust   : target datalayout = "e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32"
         target triple      = "xtensa-unknown-none-elf"
zig    : target datalayout = "e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32"
         target triple      = "xtensa-unknown-unknown-unknown"
D/LDC  : target datalayout = "e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32"
         target triple      = "xtensa-esp-unknown-elf"
TinyGo : target datalayout = "e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32"
         target triple      = "xtensa"               [docs/24 §c]
```

Byte-identical → same memory model, mutually linkable in
theory. The old upstream-LLVM-22 LDC used to differ (`i8:8:32-i16:16:32` instead
of `v1:8:8-i128:128`); `llvm-link` warned but merged. The espressif-fork LDC
(LLVM 21.1.3) drops the warning; TinyGo (LLVM 20.1.1, its own bundled fork)
agrees on every byte even though its LLVM is two minor versions behind. See
[docs/23](23-ldc-espressif-fork.md) §(e) and [docs/24](24-tinygo.md) §c for the
side-by-side. (TinyGo *triple* drops the `-esp-elf` suffix; it's still a
recognized Xtensa target at the LLVM level.)

## Where the frontends lower the ABI differs (but the backend often reconciles)

`scripts/analyze.sh esp32` dumps `build/analysis/ir-signatures-esp32.txt`. The
revealing rows:

| function | clang IR | rust IR | zig IR | D/LDC IR | TinyGo IR |
|----------|----------|---------|--------|----------|-----------|
| `add_i32` | `i32 (i32,i32)` | `i32 (i32,i32)` | `i32 (i32,i32)` | `i32 (i32,i32)` | `i32 (i32,i32)` |
| `mul_f64` | `i64 (i64,i64)` | `double (double,double)` | `double (double,double)` | `double (double,double)` | `double (double,double)` |
| `make_point` (8B) | `[2 x i32] (i32,i32)` | `[2 x i32] (i32,i32)` | `%Point (i32,i32)` | `sret ptr (Point), i32, i32` | `[2 x i32] (i32,i32)` (or flattened: `(i32,i32)→{i32,i32}`) |
| `point_dot` (8B) | `i32 ([2xi32],[2xi32])` | `i32 ([2xi32],[2xi32])` | `i32 (%Point,%Point)` | `i32 (byval ptr, byval ptr)` | `i32 (i32 %a.X, i32 %a.Y, i32 %b.X, i32 %b.Y)` |
| `blob_sum` (24B) | `i32 ([6 x i32])` | `i32 ([6 x i32])` | `i32 (%Blob)` | `i32 (byval ptr)` | `i32 ([24 x i8])` |
| `make_blob` (24B) | `void (sret ptr, i8)` | `void (sret ptr, i8)` | `%Blob (i8)` | `void (sret ptr, i8)` | `void (sret ptr, i8)` |

Three strategies: **clang and rust** coerce in-frontend to
`[N x i32]` (C-ABI match); **Zig** hands raw aggregate types to the backend;
**D/LDC** always pointer-indirects (`byval`/`sret`); **TinyGo** flattens
struct-of-scalars to the scalar fields (`a.X`, `a.Y`, …) but leaves byte-array
aggregates as `[N x i8]`. The first wins; the next three each fail somewhere
on Xtensa (docs/05/19/24).

Two lessons:

1. **clang and rust implement the Xtensa C ABI in the frontend** — explicit
   `[N x i32]` coercion, explicit `sret`, even coercing `double`→`i64`. **They
   match each other exactly.**
2. **Zig hands raw aggregate / scalar types to the backend.** Sometimes the
   backend's default agrees with the C ABI (it does for `mul_f64` — `i64` vs
   `double` both end up in `a2:a3`; and for the 8-byte `Point`); sometimes it
   does not (the 24-byte by-value argument, §05). **IR difference ≠ ABI
   difference — the disassembly is the source of truth.**

## Can you mix IR across frontends? Three mechanisms, tested

### (a) Feed any frontend's IR to the one backend — ✓
`llc -mcpu=esp32` from espressif's clang compiles `.ll` emitted by clang, rust
and zig alike. They genuinely share one backend.

### (b) `llvm-link` (merge modules) — now works with the LLVM-22 binutils
`llvm-link` merges the modules into one. espressif's clang ships no
`llvm-link`/`opt`/`llvm-dis`/`llvm-as` (only `llc` + `ld.lld`), and the host's are
LLVM **18**, which reject the LLVM-21 constructs the frontends emit:

```
llvm-link: driver.ll: error: expected type
  %107 = getelementptr inbounds nuw %struct.Point, ptr %10, i32 0, i32 0
```

(`nuw` on `getelementptr`, plus rust's `captures(none)`/`initializes(...)`, are
post-18 IR.) **This was a tooling gap, not a fundamental limit — now closed.**
Adding the matching **LLVM 22.1.2** binutils (`ldc-developers/llvm-project`
`ldc-v22.1.2`, the LLVM LDC is built on; `$LDC_LLVM_DIR`, `setup.sh LLVM22=1`)
reads all of it. `experiments/llvm-ir-mix/run.sh`:

```
LLVM-22 llvm-link driver+C+Rust+Zig+D -> 1 module: 42 defines (exit 0)
opt -O2 over the merge: d_use -> `add i32 %x_arg, 2`  (D's d_inc inlined, x+2)
llvm-dis reads LDC's LLVM-22 bitcode: producer "ldc version 1.42.0-git-c8305d0"
```

So **true module-merge across every LLVM frontend works** (the host LLVM-18 fails
on the same input), and `opt -O2` then inlines across the merge. Two caveats:
(1) cross-*frontend* inlining via `opt` is gated by matching `target-features`
(clang carries espressif's full esp32 set, D the upstream set) — the `ld.lld`
LTO path (c) inlines clang↔D regardless (docs/19 §6); (2) **esp32 *codegen* of the
merged/LLVM-22 IR still needs the espressif backend** — upstream LLVM-22 has no
`esp32` CPU model, so these tools are for IR merge/inspect/optimize, not the
final Xtensa object.

### (c) Cross-language LTO via `ld.lld` — ✓ within a matching LLVM version
The practical IR-merge path: compile to bitcode (`clang -flto`, `rustc
--emit=llvm-bc`, `zig -femit-llvm-bc`) and let `ld.lld --lto-O2` merge it.

- **clang ↔ rust** (both 21.1.3): **links (rc=0)** — a single image where C calls
  Rust, IR merged at link time. (`experiments/llvm-ir-mix/mix2.c` + `mix_rs`.)
- **clang ↔ zig** (esp 21.1.3 LTO reader vs zig 0.17 / LLVM 22.1.4 bitcode):
  **fails** — `ld.lld: error: …/mix_zig.bc: Invalid record`. The skew got
  *bigger* with the 0.16 → 0.17 flip (was patch-level 21.1.0 vs 21.1.3, now
  major-level 22 vs 21), and `ld.lld` 21.1.3's bitcode reader still rejects
  post-21 modules. The legacy `$ZIG_016` lane has the same failure for the
  patch-level reason. Both upstream Zig 0.16.0 (`pip install ziglang`) and the
  0.16 bootstrap ship LLVM 21.1.0; 0.17.0-xtensa bundles LLVM 22.1.4.
- **C ↔ zig, both via `zig cc -flto`** (riscv32, `build/lto-rv`): **works** —
  compile C with `zig cc -flto` and Zig with `zig … -femit-llvm-bc`, then link
  with `zig cc -flto` (one consistent LLVM — Zig's bundled lld matches its
  bundled clang). LTO not only merged the modules but **inlined the Zig
  `zigsq` into the C `sum_sq`** and constant-folded the result: the linked
  `_start` just stores `0x181` (= 385 = Σ1..10²) — zero residual calls.
  Cross-language inlining across a C↔Zig boundary is the strongest proof of
  IR-level mixing.
- **clang ↔ zig via `$LDC_LLVM_DIR`'s LLVM-22 `llvm-link`** (opt-in,
  `LLVM22=1`): **merges (rc=0)**. The forward-compatible LLVM-22 binutils read
  esp-clang 21.1.3 bitcode AND zig 0.17 22.1.4 bitcode and emit one combined
  module (verified at the shell against
  `experiments/llvm-ir-mix/build/zig17-parity/`). This is module-merge only;
  the matching LLVM-22 `ld.lld` still rejects the post-21 modules from a
  21.1.3 input. So cross-cluster IR analysis works, full LTO doesn't.

> **Two LLVM clusters now (post-2026-05-30 LDC re-upload)**: the **21.1.3
> cluster** is now just **esp-clang + rust** (both 21.1.3) — the canonical
> LDC moved out when the maintainer republished the
> `kassane/esp-idf-dlang` tarball on LLVM 22.1.4 (docs/05 §"LDC 1.42
> status"). The **22.x cluster** now contains **canonical LDC 1.42.0
> (22.1.4) + zig 0.17 (22.1.4) + `$LDC2_UPSTREAM` (22.1.2) + `$LDC_LLVM_DIR`
> binutils (22.1.2)** — the LLVM-22 binutils can `llvm-link` modules
> across 21.1.3 ↔ 22.x (forward-compatible), but `ld.lld` LTO needs the
> caller and callee on the SAME cluster.
>
> Net effect of the swap: **clang ↔ rust LTO still works** (same 21.1.3,
> nothing changed there); **clang ↔ D LTO** that *used to* work via
> esp-clang's 21.1.3 ld.lld now FAILS (`Invalid record`, the same
> failure clang ↔ zig had since PR #18); **D ↔ zig LTO** is *newly
> reachable* via the LLVM-22 lld (use `$LDC_LLVM_DIR/bin/ld.lld` or
> the lld bundled with `$ZIG`). TinyGo (LLVM 20.1.1) sits outside both
> clusters as before.
>
> IR portability is real (shared backend; identical datalayout across
> every LLVM frontend in this matrix since docs/23/24); the rule of thumb
> stays "same LLVM point release for `ld.lld` LTO." Object-level FFI
> (docs 03/05) has no such constraint and is the robust default for any
> toolchain that produces a relocatable `.o`; TinyGo (docs/24) stays
> standalone because its `.o` carries the Go runtime.
