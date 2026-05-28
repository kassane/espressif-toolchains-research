# 13 — Re-testing & porting esp-rs/rust issues across frontends

Taking reported `esp-rs/rust` (Rust Xtensa fork) issues, re-testing them on the
current toolchain (rustc 1.95.0-nightly / LLVM 21.1.3), and **porting the
reproducer to every frontend** (clang, gcc, zig, D/LDC) to see whether each is
a Rust-specific bug, a shared-backend bug, or fixed. Sources +
`experiments/esp-rs-issues/run.sh` + `ports.d`. TinyGo sits outside this
matrix (whole-program, docs/24) and most reproducers wouldn't survive its
runtime dependencies anyway. Status legend: ✓ ok · ✗ broken · — n/a.

## Summary

| issue | what | upstream state | rustc 1.95 today | ported to C (clang/gcc) | ported to Zig | ported to D/LDC |
|-------|------|----------------|------------------|-------------------------|---------------|-----------------|
| **#95** | enum/match `Not supported instr` (LLVM 12) | CLOSED | ✓ compiles (fixed) | ✓ compiles | ✓ compiles | ✓ compiles (D `final switch`) |
| **#137** | `u128` miscompile at `opt-level=z` | CLOSED | ✓ compiles | **— `__int128` unsupported on xtensa** | ✓ compiles | **✗** frontend rejects: `'cent' and 'ucent' types are obsolete, use core.int128.Cent instead` — no native 128-bit int in `-betterC` |
| **#270** | force-frame-pointers register-scavenge ICE | **OPEN** (rustc + `compiler_builtins`) | ✗ reproduces (regalloc) | ✓ compiles | ✓ compiles | ✓ compiles clean with `--frame-pointer=all -Os` — no ICE |
| **#277** | ICE `Cannot select XtensaISD::PCREL_WRAPPER` (serde `Vec<f32>`) | **OPEN** ([root cause: espressif/llvm-project #127](https://github.com/espressif/llvm-project/issues/127)) | narrowed to the **espidf (std) target**; the exact serde repro builds fine on `*-none-elf` | ✓ compiles (float pool fine) | ✓ compiles | not directly portable (no D serde) — but a `[2 x float]` constant pool compiles fine |
| **#278** | narrow stack-arg store width | **OPEN** (rustc/clang narrow, gcc/zig wide) | uses `s8i/s16i` (narrow) | clang narrow / gcc wide | wide `s32i` | wide `s32i.n` (joins gcc + zig — disasm in `ports.d` at `d_issue278_callm`) |
| **#161** | `Iterator::position` miscompile at `opt-level=s` | CLOSED | ✓ **fixed** (runtime: index 1) | ✓ (manual loop, index 1) | — | — |
| **#177** | C variadics garbage on Xtensa | CLOSED | ✓ **fixed** (runtime: sum 100) | ✓ baseline (sum 100) | — | — |

## Per-issue notes

### #95 — enum/match "Not supported instr" — fixed everywhere
The 4-variant enum + `match` that emitted `LLVM ERROR: Not supported instr` on the
old toolchain (rustc 1.56 / LLVM 12) now compiles cleanly on rustc 1.95 / LLVM 21.
The equivalent tagged-union `switch` compiles in clang **and** gcc for xtensa too.
A long-fixed early-backend bug.

### #137 — `u128` — a Rust/Zig type C doesn't have on xtensa
The `(a as u128) * 10` reproducer compiles on rustc 1.95 (the old `-Os` miscompile
is gone). The interesting cross-frontend result: **`__int128` is rejected by both
clang and gcc on xtensa** (`error: __int128 is not supported on this target`),
while **Rust and Zig both support 128-bit ints** and lower them *identically* —
`i128 @issue137_u128(i32)` in both. So 128-bit-integer FFI on xtensa is a
Rust↔Zig affair; you cannot exchange a `u128` with C there.

### #277 — PCREL_WRAPPER ICE (OPEN) — root cause is now public

The serde reproducer ICEs with `Cannot select … XtensaISD::PCREL_WRAPPER` on a
`[2 x float] [-1.0, 1.0]` constant pool. We'd narrowed it to the
`xtensa-esp32s3-espidf` (std) target only (clean on `*-none-elf`); the actual
*backend* defect now has its own upstream report:
[**espressif/llvm-project #127**](https://github.com/espressif/llvm-project/issues/127)
— the DAG combiner folds `select(fcmp, FP_const_A, FP_const_B)` into a
constant-pool lookup, the legalizer inserts an `ADD` between the `LOAD` and
the `PCREL_WRAPPER`, and existing ISel patterns only match `PCREL_WRAPPER`
when it's the **direct** operand of `LOAD`. Proposed fix in the issue: a
custom `Select()` in `XtensaISelDAGToDAG.cpp` plus a standalone tablegen
pattern that emits `L32R` for a bare `PCREL_WRAPPER`. So this is an ISel
pattern miss, not a target-config gap — espidf vs none-elf just changes what
constants end up in the pool. (`experiments/esp-rs-issues/issue277` still
reproduces the no-ICE behavior on `*-none-elf`.)

### #161 / #177 — runtime miscompiles, both now fixed (qemu)

These are *runtime* miscompiles, not compile errors, so they're tested by
execution on `qemu-system-xtensa` (`experiments/esp-rs-issues/runtime`, built into
the bare-metal semihosting harness). Both are **fixed** on rustc 1.95 / LLVM 21:

```
#177 C variadics on Xtensa:
  c_vsum(10,20,30,40)  = 100  ok          (C baseline)
  rs_vsum(10,20,30,40) = 100  ok          (Rust C-variadic, #[feature(c_variadic)])
#161 Iterator::position (opt=s):
  c_find_pos  = 1  ok                      (C manual loop)
  rs_find_pos = 1  ok                      (Rust .iter().position())
```

- **#177**: a C caller invoking a Rust `unsafe extern "C" fn(n, ...)` variadic now
  reads its args correctly on Xtensa (historically garbage). Rust's c_variadic
  va-list lowering matches the C ABI. Note Rust c_variadic is nightly-only
  (`#![feature(c_variadic)]`); Zig has no portable C-variadic *definition*, so the
  port is C↔Rust here.
- **#161**: `Iterator::position(...).unwrap()` at `opt-level=s` returns the correct
  index (1), matching the C loop. The old wrong-index/None miscompile is gone.

## How to reproduce

`experiments/esp-rs-issues/run.sh` (compile/codegen ports) and the runtime build
in `experiments/esp-rs-issues/runtime` (built + run via the qemu harness, same as
`scripts/run-qemu.sh`). Net: of the five issues, four are fixed on the current
toolchain and behave identically across the applicable frontends; **#277** is the
only one still open, and only under its specific serde/espidf configuration.
