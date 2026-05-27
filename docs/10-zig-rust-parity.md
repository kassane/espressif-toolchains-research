# 10 — Zig ⇔ Rust parity on ESP, and issue-tracker cross-checks

Both Rust and Zig reach the ESP architectures through the *same* espressif LLVM 21
backend, both expose the C ABI (`#[no_mangle] extern "C"` / `export fn`), and both
link cleanly with clang/gcc objects (docs 03/09). Where they differ is **C-ABI
completeness**, and it is measurable.

## The parity gap: C-ABI struct lowering

Rust implements the per-target C ABI in the compiler (`rustc_target`'s
`abi/call/{xtensa,riscv}.rs`, explicitly written to match clang's
`TargetInfo.cpp` — see esp-rs/rust #18). Zig's *experimental* ESP targets hand
aggregates to LLVM's default lowering instead, which is not the platform C ABI.
Result, verified by disassembly **and** qemu runtime (docs 05/08/09):

| by-value struct argument | Rust | clang | gcc | **Zig** |
|--------------------------|:----:|:-----:|:---:|:-------:|
| Xtensa: `{i32,i32}` 8 B | ok | ok | ok | ok |
| Xtensa: `[24]u8` 24 B (align 1) | ok | ok | ok | **wrong** (stack, not `[6 x i32]` regs) |
| RISC-V: `{i32,i32}` 8 B | ok | ok | n/a | **wrong** (`[2 x i64]`, wrong regs) |
| RISC-V: `[24]u8` 24 B | ok | ok | n/a | ok (by-ref) |

So **Rust is at parity with clang/gcc on the C ABI for both ESP architectures;
Zig is not** — it has a different struct-argument bug on each. Everything else
tested (scalars, `i64`, `f32`/`f64`, pointers, callbacks, small/large struct
*returns*) is at parity across all four toolchains.

Practical parity guidance for Rust↔Zig (or C↔Zig) FFI on ESP: pass structs **by
pointer** across any Zig boundary; scalars/pointers/callbacks are always safe.
Rust↔C/clang/gcc need no such caveat.

### `-lc` is libc, not the C ABI

A natural question: does linking libc (`-lc`) give Zig C-ABI compatibility the way
Rust has it? **No.** `-lc` is a *linker* choice — it provides the C *library*
(`printf`, `malloc`, `memcpy`, …). The C *calling convention* (how args/structs
are passed) is a *codegen* decision fixed when the object is built
(`export fn` / `callconv(.c)` / `extern struct`), and is independent of `-lc`.
Verified: `zig_point_dot` is lowered to the buggy `[2 x i64]` **identically**
with `-lc`, without it, and even on `riscv32-linux-musl` with a real libc. Rust,
by contrast, gets the C ABI right from rustc's own per-target ABI tables — even in
`#![no_std]` with no libc at all. So `-lc` buys you libc symbols, not Rust-grade
ABI correctness; the fix for the struct gaps has to come from Zig's codegen.

### Cross-language LTO works when one LLVM version is used (docs/04)

C↔Zig cross-language LTO **does** work on RISC-V when the whole pipeline is one
LLVM version: compile C with upstream `zig cc -flto` and Zig with `zig
-femit-llvm-bc`, link with `zig cc -flto`. The Zig `zigsq` is inlined into the C
caller and constant-folded (the linked `_start` just stores `385`). It fails only
when mixing zig's LLVM 21.1.0 bitcode with the esp 21.1.3 LTO reader
("Invalid record") — a version-skew constraint, not a language one.

> These specific Zig cases do not appear in the issue trackers (below); they look
> unreported. A minimal repro lives in `experiments/abi-structs` + the qemu
> harness.

## Issue-tracker cross-checks (tested on this exact toolchain)

Reproduced/checked selected issues from `espressif/llvm-project` and `esp-rs/rust`
against clang 21.1.3 / rustc 1.95-nightly(LLVM 21.1.3) / zig 0.16(LLVM 21.1.0) /
gcc 15.2:

- **llvm-project #66** — "calling convention for stack args narrower than 32 bits
  is incorrect" (CLOSED). **Fixed here.** With 6 int + several `u8`/`u16` stack
  args, clang/gcc/zig **and** rust all place stack args at **4-byte-stepped
  offsets** (`a1+0, +4, +8, …`). clang/rust store narrow (`s8i`/`s16i`) into the
  4-byte slot; gcc/zig store full `s32i`; the *offsets agree*, so it is
  FFI-compatible. The old "tight packing" is gone.
- **esp-rs/rust #278** — "u8/u16 stack args use `s16i` not `s32i`" (OPEN). The
  narrow-store *width* difference is real (Rust/clang use narrow stores) but in
  our tests the **slot offsets still step by 4**, i.e. no offset drift / mismatch
  in the simple multi-arg cases — the reported corruption needs its specific
  `#[repr(C, align(16))]` bindgen scenario to manifest; not reproduced as a plain
  cross-toolchain offset mismatch here.
- **esp-rs/rust #18 / #1** — "Fix/complete the Rust Xtensa call ABI to match
  clang's `TargetInfo.cpp`" (CLOSED). Consistent with our result: Rust's ESP C-ABI
  *does* match clang now (it is the reference the Zig gaps are measured against).
- Closed miscompiles (llvm-project #38 bit-compare, #41 float-compare, #33 fcmp)
  compile without crashing on clang 21.1.3 — regressions stayed fixed.

Where ABI/codegen root causes live: esp-rs/rust routes them to
`espressif/llvm-project` (the shared backend) and upstream `rust-lang/rust`
(the frontend ABI tables) — matching this repo's "shared backend, per-frontend
ABI" framing.

## Upstream Zig (`pip install ziglang`) vs the espressif bootstrap

Comparing stock upstream **Zig 0.16.0** (built against upstream LLVM) with
`kassane/zig-espressif-bootstrap` 0.16.0 (built against espressif LLVM 21.1.0):

- **Upstream Zig cannot target ESP.** `zig targets` lists only `generic` for the
  `xtensa` arch (`error: unknown CPU: 'esp32'`), and has no `esp32c3` riscv CPU.
  The espressif bootstrap is **required** — it bundles the espressif LLVM fork
  that adds the esp32/esp32s2/esp32s3 (and esp32c*) CPU models and the Xtensa
  codegen. (This mirrors Rust: stock rustc has no Xtensa; esp-rs/rust adds it.)
- **The RISC-V `{i32,i32}` → `[2 x i64]` bug is upstream, not the fork.** Built
  with a generic `riscv32 -mcpu=generic_rv32+m+c`, **both** upstream Zig and the
  bootstrap emit `i32 @zig_point_dot([2 x i64], [2 x i64])`. So the small-struct
  RISC-V C-ABI mis-lowering is an upstream **Zig frontend** bug, reproducible with
  stock `pip install ziglang` on any RISC-V target — independent of the espressif
  LLVM fork. (The Xtensa `[24]u8` bug can only be exercised via the bootstrap,
  since upstream Zig has no esp32 Xtensa target at all.)

Net parity: Rust's ESP story (esp-rs/rust) is a complete C-ABI implementation;
Zig's is experimental, with a frontend struct-ABI gap that is in part *upstream*
(RISC-V) and in part *fork-path* (Xtensa). The shared LLVM backend is necessary
but not sufficient for FFI — each frontend must implement the platform C ABI, and
only Rust (here) fully does.
