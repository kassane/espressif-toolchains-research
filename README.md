# espressif-ffi-ai

Research & test bed for **cross-language FFI on Xtensa (ESP32 / ESP32-S2 / ESP32-S3)**
using the shared `espressif/llvm-project` backend.

The central question:

> Zig, Rust and C/C++ can all target Xtensa through (forks of) the same LLVM 21
> backend. Does that shared backend actually give us a shared ABI — i.e. can the
> four languages call each other freely on a real ESP32 core, and can their
> intermediate representations and binaries be mixed?

Short answer, established empirically in this repo:

> **Yes for scalars, floats, pointers, callbacks, small structs and struct
> returns — all four toolchains agree bit-for-bit on the Xtensa windowed ABI.
> The one real hole is large by-value struct *arguments*, where Zig's
> experimental Xtensa target diverges from clang/rust/gcc.**

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
- **One genuine incompatibility**: passing a struct **larger than 16 bytes by
  value as an argument**, where Zig uses a stack-based layout instead of the
  `[6 x i32]`-in-registers convention used by clang/rust/gcc.
