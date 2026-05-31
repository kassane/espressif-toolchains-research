# 09 — RISC-V (ESP32-C3): a *different* Zig struct-ABI gap

The same `espressif/llvm-project` LLVM 21 also hosts **riscv32** (it is esp clang's
*default* triple). ESP32-C3 = `rv32imc`. Repeating the matrix here was meant to
check whether the Zig struct-argument divergence (docs/05) is Xtensa-specific.
**TinyGo** also has an `esp32c3-generic` target (LLVM 20.1.1, docs/24) but is
firmware-only so doesn't join the link matrix here.

**Historically, no.** RISC-V had its *own*, different Zig 0.16 struct-ABI
bug — caught by the qemu runtime test (docs/08-style), which a static
spot-check of only the large struct had missed. **Zig 0.17 (`$ZIG`
canonical) closes it** — the riscv `zig_point_dot FAIL` line below is the
0.16 baseline reproducible only on `$ZIG_016` now. Rust, clang and gcc
are correct on both architectures in both lanes.

## Build & link — fine

`scripts/build-ffi.sh esp32c3` builds the **five-language** matrix for ESP32-C3
(clang C/C++, `cargo … --target riscv32imc-unknown-none-elf`,
`zig … -mcpu=esp32c3`, `ldc2 -mtriple=riscv32-unknown-none-elf -mattr=+m,+c`),
links one `EM_RISCV` ELF via `ld.lld` + rv32imc compiler-rt, **0 undefined
symbols**. As on Xtensa, everything links.

## Runtime (qemu-system-riscv32 `virt`)

`scripts/run-qemu.sh riscv` runs the matrix on the espressif qemu RISC-V build
(**canonical `$ZIG` = 0.17 / LLVM 22.1.4**):

```
- scalar add_i32 : c ok, cpp ok, rs ok, zig ok, d ok
- point_dot  (8B {i32,i32} by value) : c ok, rs ok, zig ok (11),
                                       d SKIP (byval→ptr deref faults on riscv
                                              small struct; docs/19)
- blob_sum   (24B [24]u8 by value)   : c ok, cpp ok, rs ok, zig ok (300), d OK (300)
```

The riscv harness on the canonical 0.17 lane is **all-pass** for Zig.
Historically (on the legacy `$ZIG_016` lane, Zig 0.16 / LLVM 21.1.0): zig
**passed** the large `blob_sum` here but **failed `point_dot`**, the small
two-`i32` struct (`zig FAIL (got=-2130706553 want=11)`). D's pattern is the
**opposite** of Xtensa: on RISC-V the >16-byte `Blob` happens to be passed
by reference in the C ABI itself, so D's universal `byval` *matches* —
`d_blob_sum` PASSES.

> **Zig 0.17 fix (`$ZIG` canonical).** Both Zig struct-by-value gaps closed in
> the 0.17 frontend; the riscv `point_dot` flip is documented alongside the
> xtensa `blob_sum` flip in docs/05 §"Zig 0.17 status". To reproduce the
> historical break, `ZIG=$ZIG_016 ./scripts/build-ffi.sh esp32c3 &&
> ZIG=$ZIG_016 ./scripts/run-qemu.sh riscv` regenerates `zig FAIL`.
The 8-byte `Point` would still go in registers per C, so D's pointer-deref
runs off into garbage, harness gates it as SKIP. The asymmetry is the proof
of docs/19's frontend-bug analysis: D is correct exactly when the C ABI is
*also* indirect.

## Why (the IR tells it)

The canonical `point_dot(Point, Point)` IR shapes per frontend (clang vs
the historical Zig 0.16 `[2 x i64]` mis-lowering vs the pre-2026-05-30 LDC
`byval ptr` mis-lowering vs the canonical post-fix forms) are tabulated in
[docs/05 §"Zig 0.17 status"](05-struct-abi-deep-dive.md). On RISC-V the
specific breakage was that Zig 0.16 widened each `i32` field to `i64`, so
the second `Point` arg landed in `a4,a5` instead of `a2,a3` — clang's
caller placed it in `a2,a3`, the bytes were read from the wrong registers.
Zig 0.17 flattens to `[2 x i32]` like clang; both lanes now emit the C-ABI
shape and the riscv `zig_point_dot FAIL` is gone from qemu.

## The corrected cross-architecture picture

| by-value struct argument | Xtensa esp32 | RISC-V esp32c3 |
|--------------------------|--------------|----------------|
| small `{i32,i32}` (8 B, align 4) | zig **ok** | zig **BROKEN** (`[2 x i64]`) |
| `[24]u8` (24 B, align 1) | zig **BROKEN** (stack vs `[6 x i32]` regs) | zig **ok** (by-ref) |
| clang / rust / gcc | correct | correct |

So Zig's experimental ESP targets have **frontend C-ABI struct-lowering gaps on
both architectures** — different cases each — while Rust matches clang/gcc on
both. This is the concrete frontend-C-ABI-completeness gap discussed in
[10-cabi-completeness.md](10-cabi-completeness.md). The shared backend gives a shared
ABI only where each frontend implements the platform C ABI correctly; Rust does,
Zig (for these WIP targets) does not yet.

## Adding ESP32-P4 (rv32imafc + vendor PIE/ESPV)

esp-clang 21.1.3 also targets **esp32p4** (mainstream, ESPV 2.2) and
**esp32p4eco4** (older revision, ESPV 2.1). esp32p4 is rv32imafc + B
(`zba/zbb/zbc/zbs`) + extensive Zc compressed extensions + the two vendor
extensions `Xespv` and `Xesploop` (plus `Xespdsp` opt-in). ABI is ilp32f.

The `zero-cost` and `tmp-parity` experiments (docs/25, docs/26) now accept
esp32c3 and esp32p4 as `-mcpu` targets:

```bash
experiments/zero-cost/run.sh   {esp32 | esp32c3 | esp32p4}
experiments/tmp-parity/run.sh  {esp32 | esp32c3 | esp32p4}
```

Vendor SIMD (`esp.*` mnemonics on esp32p4) — see [docs/16
§"ESP32-P4 RISC-V vendor SIMD"](16-simd-vectorization.md).

### Four-frontend toolchain matrix for RISC-V ESP targets

| frontend | esp32c3 (rv32imc) | esp32p4 (rv32imafc) | esp32p4 SIMD asm |
|---|---|---|---|
| **esp-clang 21.1.3** | `--target=riscv32-esp-elf -mcpu=esp32c3` | `--target=riscv32-esp-elf -mcpu=esp32p4` | `-mcpu=esp32p4eco4` for ESPV 2.1 mnemonics |
| **LDC 1.42.0** (LLVM 22.1.4) | `-mtriple=riscv32-unknown-none-elf -mcpu=esp32c3` | `-mtriple=riscv32-unknown-none-elf -mcpu=esp32p4` | `-mcpu=esp32p4eco4` |
| **Zig 0.17.0-xtensa** | `-target riscv32-freestanding-none -mcpu=esp32c3` | `-target riscv32-freestanding-none -mcpu=esp32p4` | `-mcpu=esp32p4eco4` |
| **rustc 1.95-nightly** | `--target riscv32imc-unknown-none-elf` | `--target riscv32imafc-unknown-none-elf` | `-C target-cpu=esp32p4eco4` |

All three LLVM C-family frontends accept the esp* CPU names natively because
they share the espressif LLVM RISC-V backend: esp-clang's 21.1.3 and LDC's
bundled 22.1.4 both enumerate `esp32c2/c3/c5/c6/c61/h2/h21/h4/p4/p4eco4/s31`
plus their `+xesploop / +xespv / +xespv1v / +xespdsp` features through
`-mcpu=help` / `-mattr=help`. Rust currently has no `riscv32imafc-esp-elf`
target — `riscv32imafc-unknown-none-elf` + `-C target-cpu=esp32p4eco4` is
the working combination. compiler-rt builtins for both targets ship under
`$ESP_CLANG_DIR/../lib/clang-runtimes/riscv32-esp-unknown-elf/` (esp-clang
ships `rv32imc-…`, `rv32imafc-…`, plus many `…_no-rtti` variants).

### RISC-V ABI quirks observed across the experiments

A few rv32 ABI properties the parameterized runs make visible:

1. **No register windows** — rv32 functions don't carry an `entry/retw`
   pair, so every leaf function is 1-2 insns shorter than its xtensa peer.
   The riscv ABI passes args + return in `a0..a7` (no per-call rotation).
2. **2/4-byte instruction encoding** — `c.*` compressed instructions are
   2 bytes; non-compressed are 4 bytes (vs xtensa's 2/3 byte split). The
   bytes-per-function totals shift accordingly.
3. **`li` macro expansion** — `li a0, K` for K outside ±2KB expands to
   `lui a0, hi(K) ; addi a0, a0, lo(K)` (8 bytes total). `0x78` fits in
   12-bit imm so it stays 4 bytes. This makes the riscv `fact(5)` and
   `static_sum(42)` returns slightly tighter than xtensa where every
   const-return is `movi a2, K ; retw.n` (5-6 bytes).
4. **Vendor-extension MCA gap** — LLVM's RISC-V Machine Code Analyzer
   (`llvm-mca`) has no cost model for `Xespv` ops yet, so cycle counting
   the ESPV kernels needs manual lookup against the ESPV 2.1 ISA manual.

These shift absolute byte counts in the docs/25 (zero-cost) and docs/26
(TMP) probes, but every *relative* conclusion (static = free, dynamic =
+vtable cost, CTFE = single-`li` return) holds across both architectures.
