# 04 — LLVM IR comparison & mixing

## Same target, same datalayout (all five LLVM frontends, since docs/23/24)

All five LLVM frontends now emit the identical datalayout for the Xtensa esp32
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

Byte-identical across all five → same memory model, mutually linkable in
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

| function | clang IR | rust IR | zig IR |
|----------|----------|---------|--------|
| `add_i32` | `i32 (i32,i32)` | `i32 (i32,i32)` | `i32 (i32,i32)` |
| `mul_f64` | `i64 (i64,i64)` | `double (double,double)` | `double (double,double)` |
| `make_point` (8B) | `[2 x i32] (i32,i32)` | `[2 x i32] (i32,i32)` | `%Point (i32,i32)` |
| `point_dot` (8B) | `i32 ([2xi32],[2xi32])` | `i32 ([2xi32],[2xi32])` | `i32 (%Point,%Point)` |
| `blob_sum` (24B) | `i32 ([6 x i32])` | `i32 ([6 x i32])` | `i32 (%Blob)` |
| `make_blob` (24B) | `void (sret ptr, i8)` | `void (sret ptr, i8)` | `%Blob (i8)` |

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

So **true module-merge across all five frontends works** (the host LLVM-18 fails
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
- **clang ↔ zig** (esp 21.1.3 LTO reader vs zig 21.1.0 bitcode): **fails** —
  `ld.lld: error: …/mix_zig.bc: Invalid record`. Both the espressif-bootstrap and
  *upstream* (`pip install ziglang`) Zig 0.16.0 ship LLVM 21.1.0, so neither mixes
  with the esp 21.1.3 tools.
- **C ↔ zig, all on upstream Zig 21.1.0** (riscv32, `build/lto-rv`): **works** —
  compile C with `zig cc -flto` and Zig with `zig … -femit-llvm-bc`, then link
  with `zig cc -flto` (one consistent LLVM). LTO not only merged the modules but
  **inlined the Zig `zigsq` into the C `sum_sq`** and constant-folded the result:
  the linked `_start` just stores `0x181` (= 385 = Σ1..10²) — zero residual calls.
  Cross-language inlining across a C↔Zig boundary is the strongest proof of
  IR-level mixing.

> Takeaway: IR portability is real (shared backend; identical datalayout across
> all five LLVM frontends since docs/23/24), and both merge paths work —
> `llvm-link` (LLVM-22 binutils for the upstream-LDC comparison; esp-clang's
> own 21.1.3 binutils for the canonical fork-LDC) merges across frontends, and
> `ld.lld` LTO merges + inlines. The LTO reader (esp 21.1.3 `ld.lld`) accepts
> clang/rust/**D** (all 21.1.3) — no skew. Zig (21.1.0) and TinyGo (20.1.1) are
> the version-skew outliers; "same LLVM point release" remains the LTO rule of
> thumb. Object-level FFI (docs 03/05) has no such constraint and is the robust
> default for the five toolchains that produce relocatable `.o`; TinyGo
> doesn't (docs/24) so it stays standalone.
