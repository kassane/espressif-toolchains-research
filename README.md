# espressif-ffi-ai

Research & test bed for **cross-language FFI on Xtensa (ESP32 / ESP32-S2 / ESP32-S3)**
using the shared `espressif/llvm-project` backend.

The central question:

> Zig, Rust, D and C/C++ can all target Xtensa through (forks of, or upstream)
> the same LLVM backend. Does that shared backend actually give us a shared ABI —
> i.e. can the five languages call each other freely on a real ESP32 core, and can
> their intermediate representations and binaries be mixed?

Short answer, established empirically in this repo:

> **Yes for scalars, floats, pointers, callbacks and struct returns — all five
> toolchains agree on the ABI (verified in disassembly and live on qemu). The
> holes are in by-value struct *arguments* on the two frontends that defer ABI
> lowering to the backend: Zig (under-aligned structs on Xtensa; small `{i32,i32}`
> on RISC-V) and — more broadly — D/LDC (every by-value struct + small-struct
> return). Rust/clang/gcc are correct everywhere. Fix: pass structs by pointer.**

See **[Research.md](Research.md)** for the full write-up and **[docs/](docs/)** for
the detailed evidence.

## The five toolchains

| Lang | Toolchain | Version | Backend |
|------|-----------|---------|---------|
| C/C++ (clang) | [espressif/llvm-project](https://github.com/espressif/llvm-project) `esp-21.1.3_20260408` | clang/LLVM **21.1.3** | LLVM Xtensa |
| Rust | [esp-rs/rust-build](https://github.com/esp-rs/rust-build) `v1.95.0.0` | rustc 1.95.0-nightly, LLVM **21.1.3** | LLVM Xtensa |
| Zig | [kassane/zig-espressif-bootstrap](https://github.com/kassane/zig-espressif-bootstrap) `0.16.0-xtensa` | Zig 0.16.0, clang/LLVM **21.1.0** | LLVM Xtensa |
| D | [ldc-developers/ldc](https://github.com/ldc-developers/ldc) `CI` (`-betterC`) | LDC 1.42-git, LLVM **22.1.2** | LLVM Xtensa (upstream, experimental) |
| C/C++ (gcc) | [espressif/crosstool-NG](https://github.com/espressif/crosstool-NG) `esp-15.2.0_20251204` | gcc **15.2.0** | GCC Xtensa (control) |

The four LLVM frontends share an Xtensa backend (clang/rust/zig on the espressif
LLVM-21 fork; D on *upstream* LLVM 22). GCC is the non-LLVM control: it should
still agree on the *ABI* even though it shares no IR. An optional 6th component —
the matching **LLVM 22.1.2 binutils** (`ldc-developers/llvm-project` `ldc-v22.1.2`,
`setup.sh LLVM22=1`) — adds the `llvm-link`/`opt`/`llvm-dis` esp-clang omits, for
true cross-frontend IR module-merge (docs/04).

**At-a-glance comparison:** [docs/00-support-matrix.md](docs/00-support-matrix.md)
(Rust × Zig × D × esp-clang × GCC — versions, targeting, ABI/FFI correctness,
sizes, LTO, mangling). D deep-dive: [docs/19](docs/19-dlang-ldc.md).

## Quick start

```bash
./scripts/setup.sh          # download + extract + install the 5 toolchains (~1 GB)
source scripts/env.sh       # point at the toolchains
./scripts/build-ffi.sh all  # build the FFI matrix: host (runs) + esp32/s2/s3 (link)
./scripts/analyze.sh esp32  # regenerate IR / disassembly / size evidence
```

Toolchains install **outside** the repo (`/home/user/toolchains`) and are never
committed; `.gitignore` guards against it.

## Layout

```
experiments/
  ffi-matrix/      5 languages implement one C-ABI contract (ffi_abi.h); a C
                   driver calls all of them. Builds for host + xtensa.
  abi-structs/     minimal caller comparison that isolates the large-struct ABI bug
  llvm-ir-mix/     cross-language LTO / IR-merge probes (+ LLVM-22 llvm-link merge)
  dlang/           D/LDC deep-dive: ABI, extern(C++), -HC headers, LTO (docs/19)
  baremetal-mixin/ runnable use-case: Rust app + Zig kernel in one no_std ELF
  qemu-run/        bare-metal semihosting harnesses (xtensa + riscv) for qemu
scripts/           setup / env / build / analyze
docs/              detailed findings (00–19: toolchains, ABI, IR, FFI matrix, …)
Research.md        headline write-up
HANDOFF.md         current state + next steps
CLAUDE.md          orientation for future automated sessions
```

## Headline results

- **Host (x86_64) FFI matrix runs and passes** — all 45 cross-language calls
  (C↔C++↔Rust↔Zig↔D, incl. struct-by-value, sret, f32/f64, i64, callbacks).
- **All three Xtensa cores link** as one ELF from a mix of compilers, under
  **both** `ld.lld` **and** GNU `ld`, with **0 unresolved symbols** — including
  images that mix **GCC-built** and **LLVM-built** (clang/rust/zig/D) objects.
- **ABI agreement is verifiable in the disassembly**: `entry`/`retw.n` windowed
  frames, integer args in `a2..a7`, returns in `a2`, callbacks via `callx8` —
  identical across clang, rust, zig, D and gcc.
- **IR interop**: clang/rust/zig share a byte-identical `target datalayout` (D's
  upstream-LLVM-22 one differs slightly but still merges). Same-version (21.1.3)
  bitcode is LTO-mergeable (clang↔rust, and — surprisingly — clang↔D 22.1.2);
  with the LLVM-22 binutils, `llvm-link` merges **all five** frontends' IR into
  one module (docs/04).
- **Two frontends mis-handle by-value struct *arguments*** (Rust/clang/gcc are
  correct): **Zig** stack-spills under-aligned (`align(1)`) structs on Xtensa and
  mis-lowers a small `{i32,i32}` to `[2 x i64]` on RISC-V (reproduces on upstream
  Zig). **D/LDC** marks *every* aggregate `byval`/`sret`, so it diverges more
  broadly — both `point_dot` (align-4) and `blob_sum` on Xtensa, plus small-struct
  *returns* (docs/19). Struct returns ≤reg-size, scalars, pointers and callbacks
  are fine everywhere; **pass structs by pointer** across a Zig or D boundary.
- **Confirmed at runtime on qemu** (both `qemu-system-xtensa` and
  `qemu-system-riscv32`): Xtensa → `zig blob_sum FAIL` + `d point_dot`/`d blob_sum
  FAIL`; RISC-V → `zig point_dot FAIL`. The by-pointer variant and everything else
  pass for all five.
