# 10 — C-ABI completeness per frontend on Espressif targets

The core thesis: a shared LLVM backend is *necessary but not sufficient* for
cross-language FFI — each frontend has to implement the platform C ABI
itself. Anchored on a Rust ↔ Zig comparison (both reach Espressif through
the *same* espressif LLVM 21 backend) and broadened with cross-references
to clang / gcc / D/LDC / TinyGo where the same finding applies. Also pins
the relevant `esp-rs/rust` and `espressif/llvm-project` issue-tracker
status as of writing.

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

| by-value struct argument | Rust | clang | gcc | **Zig** | D/LDC | TinyGo |
|--------------------------|:----:|:-----:|:---:|:-------:|:-----:|:------:|
| Xtensa: `{i32,i32}` 8 B | ok | ok | ok | ok | **wrong** (byval, docs/19) | ok (flattens) |
| Xtensa: `[24]u8` 24 B (align 1) | ok | ok | ok | **wrong** (stack, not `[6 x i32]` regs) | **wrong** (byval; runtime FAIL) | **wrong** (`[24 x i8]` byte-per-register, docs/24 §e) |
| RISC-V: `{i32,i32}` 8 B | ok | ok | n/a | **wrong** (`[2 x i64]`, wrong regs) | gated (byval→ptr deref faults, docs/19) | n/a (TinyGo esp32c3 target, not in matrix) |
| RISC-V: `[24]u8` 24 B | ok | ok | n/a | ok (by-ref) | ok (C ABI is by-ref there too) | n/a |

So **Rust is at parity with clang/gcc on the C ABI for both ESP architectures;
Zig is not** — it has a different struct-argument bug on each. **D/LDC fails
broader** (every by-value aggregate, docs/19) and **TinyGo joins on byte-array
fields** (docs/24 §e). Everything else tested (scalars, `i64`, `f32`/`f64`,
pointers, callbacks, small/large struct *returns*) is at parity across every
FFI-matrix toolchain.

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
LLVM version: compile C with `zig cc -flto` and Zig with `zig -femit-llvm-bc`,
link with `zig cc -flto`. The Zig `zigsq` is inlined into the C caller and
constant-folded (the linked `_start` just stores `385`). It fails when mixing
zig 0.17's LLVM **22.1.4** bitcode with the esp-clang **21.1.3** LTO reader
("Invalid record") — a version-skew constraint, not a language one. The
optional `$LDC_LLVM_DIR`'s LLVM-22 `llvm-link` reads esp-clang 21.1.3 bitcode
fine, so cross-cluster IR analysis is reachable (docs/04 §"Two LLVM
clusters").

> These specific Zig cases do not appear in the issue trackers (below); they look
> unreported. A minimal repro lives in `experiments/abi-structs` + the qemu
> harness.

## Issue-tracker cross-checks (tested on this exact toolchain)

Reproduced/checked selected issues from `espressif/llvm-project` and `esp-rs/rust`
against clang 21.1.3 / rustc 1.95-nightly(LLVM 21.1.3) / zig 0.17(LLVM 22.1.4) /
gcc 15.2 (the `$ZIG_016` legacy lane gives the same answers for everything
that isn't the by-value struct-arg case, which docs/05 covers):

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

Comparing stock upstream **Zig 0.17.0** (built against upstream LLVM) with
`kassane/zig-espressif-bootstrap` 0.17.0 (canonical `$ZIG`, built against
espressif LLVM 22.1.4):

- **Upstream Zig 0.17.0 partially targets ESP.** Upstream LLVM only carries
  esp32/esp8266 (esp32-s2/s3 are fork-side, docs/07), so upstream Zig 0.17
  gets `esp32` but **not the full esp32/s2/s3 set** — **only the espressif
  bootstrap fork has all Xtensa targets**, exactly mirroring Rust (stock
  rustc has Tier-3 specs / partial upstream; the esp-rs *fork* has the
  complete, working set). So the espressif bootstrap remains **required**
  for s2/s3 (and for the production backend). The history: ziglang/zig
  **#5467 "Xtensa Support" CLOSED 2026-05-06**, milestone **0.17.0**
  (companion #23088 for `xtensa(eb)-linux` tier landed the same day) added
  the upstream `esp32` model. The legacy `$ZIG_016` lane has no upstream
  esp32 (`error: unknown CPU: 'esp32'` on stock `pip install ziglang`
  0.16.0); the bootstrap fork carried it.
- **The RISC-V `{i32,i32}` → `[2 x i64]` bug WAS upstream, not the fork** —
  and it's gone in 0.17. Built with a generic `riscv32
  -mcpu=generic_rv32+m+c`, the legacy 0.16 emitted `i32
  @zig_point_dot([2 x i64], [2 x i64])` on BOTH upstream and the bootstrap.
  So the small-struct RISC-V C-ABI mis-lowering was an upstream **Zig
  frontend** bug, reproducible with stock `pip install ziglang` 0.16.0 on
  any RISC-V target — independent of the espressif LLVM fork. (The Xtensa
  `[24]u8` bug was exercised via the bootstrap, since upstream Zig 0.16.0
  had no esp32 target.) **Answer to the previous open question** (was:
  "did #5467's landing rewrite the C-ABI lowering for Xtensa, or only
  enable codegen?"): **YES, it rewrote the lowering**. Re-running
  `experiments/abi-structs/sweep.sh` against the canonical `$ZIG`
  (`kassane/zig-espressif-bootstrap` `zig-0.17.0-relsafe-…-baseline`,
  bundled LLVM 22.1.4) on every Xtensa core shows REGISTERS in every Zig row
  (was STACK for align-1 byte arrays on 0.16). The qemu harness on both
  xtensa and riscv flips Zig from FAIL to ok for the affected cases. Full
  account in docs/05 §"Zig 0.17 status". The legacy `$ZIG_016` lane
  reproduces the historical break.

Net parity (canonical lane): Rust's ESP story (esp-rs/rust) is a complete C-ABI
implementation; Zig 0.17 now also passes the by-value struct-arg cases that
0.16 missed. The legacy struct-ABI gap was in part *upstream*
(RISC-V) and in part *fork-path* (Xtensa); 0.17 closed both. The shared LLVM
backend is necessary but not sufficient for FFI — each frontend must implement
the platform C ABI, and Rust + Zig 0.17 now both do.
