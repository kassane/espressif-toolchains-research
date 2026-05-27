# espressif-ffi-ai

Research & test bed for **cross-language FFI on Xtensa (ESP32 / ESP32-S2 / ESP32-S3)**
using the shared `espressif/llvm-project` backend.

The central question:

> Zig, Rust and C/C++ can all target Xtensa through (forks of) the same LLVM 21
> backend. Does that shared backend actually give us a shared ABI — i.e. can the
> four languages call each other freely on a real ESP32 core, and can their
> intermediate representations and binaries be mixed?

Short answer, established empirically in this repo:

> **Yes for scalars, floats, pointers, callbacks and struct returns — all four
> toolchains agree on the ABI (verified in disassembly and live on qemu). The one
> real hole is by-value struct *arguments* into Zig's experimental ESP targets,
> which mis-handle them on *both* arches (different cases): Xtensa under-aligned
> structs stack-spilled; RISC-V small `{i32,i32}` mis-lowered. Rust/clang/gcc are
> correct on both.**

See **[Research.md](Research.md)** for the full write-up and **[docs/](docs/)** for
the detailed evidence.

## The four toolchains

| Lang | Toolchain | Version | Backend |
|------|-----------|---------|---------|
| C/C++ (clang) | [espressif/llvm-project](https://github.com/espressif/llvm-project) `esp-21.1.3_20260408` | clang/LLVM **21.1.3** | LLVM Xtensa |
| Rust | [esp-rs/rust-build](https://github.com/esp-rs/rust-build) `v1.95.0.0` | rustc 1.95.0-nightly, LLVM **21.1.3** | LLVM Xtensa |
| Zig | [kassane/zig-espressif-bootstrap](https://github.com/kassane/zig-espressif-bootstrap) `0.16.0-xtensa` | Zig 0.16.0, clang/LLVM **21.1.0** | LLVM Xtensa |
| C/C++ (gcc) | [espressif/crosstool-NG](https://github.com/espressif/crosstool-NG) `esp-15.2.0_20251204` | gcc **15.2.0** | GCC Xtensa (control) |

The first three share the espressif LLVM 21 Xtensa backend. GCC is the
non-LLVM control: it should still agree on the *ABI* even though it shares no IR.

**At-a-glance comparison:** [docs/00-support-matrix.md](docs/00-support-matrix.md)
(Rust × Zig × esp-clang × GCC — versions, targeting, ABI/FFI correctness, sizes,
LTO, mangling).

## Quick start

```bash
./scripts/setup.sh          # download + extract + install the 4 toolchains (~0.9 GB)
source scripts/env.sh       # point at the toolchains
./scripts/build-ffi.sh all  # build the FFI matrix: host (runs) + esp32/s2/s3 (link)
./scripts/analyze.sh esp32  # regenerate IR / disassembly / size evidence
```

Toolchains install **outside** the repo (`/home/user/toolchains`) and are never
committed; `.gitignore` guards against it.

## Layout

```
experiments/
  ffi-matrix/      4 languages implement one C-ABI contract (ffi_abi.h); a C
                   driver calls all of them. Builds for host + xtensa.
  abi-structs/     minimal caller comparison that isolates the large-struct ABI bug
  llvm-ir-mix/     cross-language LTO / IR-merge probes
  baremetal-mixin/ runnable use-case: Rust app + Zig kernel in one no_std ELF
  qemu-run/        bare-metal semihosting harnesses (xtensa + riscv) for qemu
scripts/           setup / env / build / analyze
docs/              detailed findings (toolchains, ABI, IR, FFI matrix, binaries)
Research.md        headline write-up
HANDOFF.md         current state + next steps
CLAUDE.md          orientation for future automated sessions
```

## Headline results

- **Host (x86_64) FFI matrix runs and passes** — all 36 cross-language calls
  (C↔C++↔Rust↔Zig, incl. struct-by-value, sret, f32/f64, i64, callbacks).
- **All three Xtensa cores link** as one ELF from a mix of compilers, under
  **both** `ld.lld` **and** GNU `ld`, with **0 unresolved symbols** — including
  images that mix **GCC-built** and **LLVM-built** objects.
- **ABI agreement is verifiable in the disassembly**: `entry`/`retw.n` windowed
  frames, integer args in `a2..a7`, returns in `a2`, callbacks via `callx8` —
  identical across clang, rust, zig and gcc.
- **Identical LLVM `target datalayout`** across clang/rust/zig; same-version
  (21.1.3) bitcode is LTO-mergeable (clang↔rust), proving IR-level interop.
- **Zig's experimental ESP targets mis-handle by-value struct *arguments* on both
  arches** (Rust/clang/gcc are correct): on **Xtensa** under-aligned (`align(1)`)
  structs are stack-spilled instead of `[N x i32]` registers (alignment, not
  size); on **RISC-V** a small `{i32,i32}` is mis-lowered to `[2 x i64]`. The
  RISC-V case reproduces on **upstream** Zig (`pip install ziglang`) too. Struct
  *returns*, scalars, pointers and callbacks are fine everywhere.
- **Confirmed at runtime on qemu** (both `qemu-system-xtensa` and
  `qemu-system-riscv32`): Xtensa → `zig blob_sum FAIL (got=242)`; RISC-V →
  `zig point_dot FAIL (got=-2130706553)`. Everything else passes for all four.
