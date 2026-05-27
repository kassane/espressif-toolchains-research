# 04 — LLVM IR comparison & mixing

## Same target, same datalayout

All three LLVM frontends emit the identical datalayout for the Xtensa esp32
target; only the triple differs:

```
clang : target datalayout = "e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32"
        target triple      = "xtensa-esp-unknown-elf"
rust  : target datalayout = "e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32"
        target triple      = "xtensa-unknown-none-elf"
zig   : target datalayout = "e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32"
        target triple      = "xtensa-unknown-unknown-unknown"
```

Identical datalayout means the IRs describe the same memory model and are, in
principle, mutually linkable.

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

### (b) `llvm-link` (merge modules) — blocked by tooling, not by IR
`llvm-link` would merge the modules into one, but espressif's clang ships no
`llvm-link`/`opt`/`llvm-as` — only `llc` and `ld.lld`. The host's `llvm-link` is
LLVM **18** and rejects LLVM-21 constructs the frontends emit:

```
llvm-link: driver.ll:187: error: expected type
  %107 = getelementptr inbounds nuw %struct.Point, ptr %10, i32 0, i32 0
```

(`nuw` on `getelementptr`, plus rust's `captures(none)`/`initializes(...)`, are
post-18 IR.) Get a version-matched `llvm-link` and this works; it is not a
fundamental limitation.

### (c) Cross-language LTO via `ld.lld` — ✓ within a matching LLVM version
The practical IR-merge path: compile to bitcode (`clang -flto`, `rustc
--emit=llvm-bc`, `zig -femit-llvm-bc`) and let `ld.lld --lto-O2` merge it.

- **clang ↔ rust** (both 21.1.3): **links (rc=0)** — a single image where C calls
  Rust, IR merged at link time. (`experiments/llvm-ir-mix/mix2.c` + `mix_rs`.)
- **clang ↔ zig** (21.1.3 vs 21.1.0): **fails** —
  `ld.lld: error: …/mix_zig.bc: Invalid record`. Zig's bitcode is a different
  LLVM point release than the LTO reader.

> Takeaway: IR portability is real (shared datalayout + shared backend). The only
> practical constraint on *merging* IR is keeping the `llvm-link`/LTO tool at the
> exact LLVM version of the bitcode producers. Object-level FFI (docs 03/05) has
> no such constraint and is the robust default.
