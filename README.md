# espressif-ffi-ai

Research & test bed for **cross-language FFI on Espressif's Xtensa (ESP32 / S2
/ S3) and RISC-V (ESP32-C3)** silicon, riding the shared `espressif/llvm-project`
backend. Six toolchains in scope: clang, gcc, rustc, zig, ldc2, tinygo.

The central question:

> LLVM-frontend toolchains (clang, rustc, zig, ldc2, tinygo) plus a non-LLVM
> control (gcc) all target Espressif Xtensa through some fork of LLVM. Does
> that shared backend actually give a shared ABI — can the languages call
> each other freely on a real ESP32 core, and can their IRs and binaries be
> mixed?

Short answer, established empirically in this repo:

> **Yes for scalars, floats, pointers, callbacks and struct returns — five
> co-linkable toolchains (clang, rust, zig, D-LDC, gcc) agree on the ABI
> (verified in disassembly and live on qemu). TinyGo joins the same backend
> family on Xtensa but, in v0.41.1, drags its Go runtime into every `.o` so
> we leave it out of the FFI matrix (docs/24). The holes are in by-value
> struct *arguments* on the two frontends that defer ABI lowering to the
> backend: Zig (under-aligned structs on Xtensa; small `{i32,i32}` on RISC-V)
> and — more broadly — D/LDC (every by-value struct + small-struct return).
> Rust/clang/gcc are correct everywhere. Fix: pass structs by pointer.**

See **[Research.md](Research.md)** for the full write-up and **[docs/](docs/)** for
the detailed evidence.

## The six toolchains

| Lang | Toolchain | Version | Backend |
|------|-----------|---------|---------|
| C/C++ (clang) | [espressif/llvm-project](https://github.com/espressif/llvm-project) `esp-21.1.3_20260408` | clang/LLVM **21.1.3** | LLVM Xtensa |
| Rust | [esp-rs/rust-build](https://github.com/esp-rs/rust-build) `v1.95.0.0` | rustc 1.95.0-nightly, LLVM **21.1.3** | LLVM Xtensa |
| Zig | [kassane/zig-espressif-bootstrap](https://github.com/kassane/zig-espressif-bootstrap) `0.16.0-xtensa-dev` (canonical; the `0.16.0-xtensa` tag is the `$ZIG_016` legacy lane) | **Zig 0.17.0-xtensa**, bundled clang/LLVM **22.1.4** | LLVM Xtensa |
| D | [kassane/esp-idf-dlang](https://github.com/kassane/esp-idf-dlang/releases/tag/xtensa-toolchain) `xtensa-toolchain` (`-betterC`) | **LDC 1.42.0**, espressif/llvm-project **LLVM 22.1.4** (2026-05-30 maintainer re-upload bumped both — docs/05 §"LDC 1.42 status", docs/23) | LLVM Xtensa (espressif fork) |
| Go | [tinygo-org/tinygo](https://github.com/tinygo-org/tinygo/releases/tag/v0.41.1) `v0.41.1` | TinyGo 0.41.1, bundled **LLVM 20.1.1** | LLVM Xtensa (tinygo-org fork; esp32/s3/c3 — no s2) |
| C/C++ (gcc) | [espressif/crosstool-NG](https://github.com/espressif/crosstool-NG) `esp-15.2.0_20251204` | gcc **15.2.0** | GCC Xtensa (control) |

The LLVM-frontend toolchains ride a fork of LLVM-Xtensa — clang and rustc on
`espressif/llvm-project` 21.1.3 (the **LLVM-21 cluster**); **canonical LDC
1.42.0** on the espressif fork bumped to 22.1.4 (joining the **LLVM-22
cluster** with zig 0.17 22.1.4 and `$LDC2_UPSTREAM` 22.1.2 — the 2026-05-30
maintainer re-upload of `kassane/esp-idf-dlang` bumped LDC AND moved it
between clusters; docs/05 §"LDC 1.42 status", docs/23); the legacy
`$ZIG_016` lane uses bundled 21.1.0; TinyGo on its own bundled
`tinygo-org/llvm-project` 20.1.1. GCC is the
non-LLVM control. TinyGo's output
defaults to a full ESP32 flash image but `-o foo.o` does produce a real
relocatable Xtensa ELF (with ~196 KB of Go runtime + scheduler undefs — see
docs/24 §d for what a consumer must supply). An *optional* `ldc-developers/ldc`
CI build of LDC on upstream LLVM **22.1.2** (`setup.sh LDC_UPSTREAM=1` →
`$LDC2_UPSTREAM`) lives only as the "before" arm of
[`experiments/ldc-fork-comparison`](experiments/ldc-fork-comparison/) — see
[docs/23](docs/23-ldc-espressif-fork.md) for the workarounds the
espressif-fork LDC removes.

**At-a-glance comparison:** [docs/00-support-matrix.md](docs/00-support-matrix.md)
(Rust × Zig × D × esp-clang × GCC × TinyGo — versions, targeting, ABI/FFI
correctness, sizes, LTO, mangling). D deep-dive: [docs/19](docs/19-dlang-ldc.md)
+ [docs/23](docs/23-ldc-espressif-fork.md). TinyGo deep-dive: [docs/24](docs/24-tinygo.md).

## Quick start

```bash
./scripts/setup.sh          # download + extract + install the 6 toolchains (~1.2 GB)
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
  abi-structs/     clang/zig/D caller sweep — documents the historical
                   by-value struct-arg bugs (Zig 0.16 + LDC 1.42-git, both
                   fixed on canonical; reproduce via `ZIG=$ZIG_016` /
                   `$LDC2_UPSTREAM`); covers byte arrays, word arrays, AND
                   C-style bitfields
  llvm-ir-mix/     cross-language LTO / IR-merge probes (+ LLVM-22 llvm-link merge)
  dlang/           D/LDC deep-dive: ABI, extern(C++), -HC headers, LTO (docs/19)
  ldc-fork-comparison/ espressif-21 vs upstream-22 LDC side-by-side (docs/23)
  atomics-orders/  atomic memory-order parity battery (docs/17 extended)
  tinygo/          TinyGo v0.41.1 / LLVM 20.1.1 probe; whole-program (docs/24)
  baremetal-mixin/ runnable use-case: Rust app + Zig kernel in one no_std ELF
  qemu-run/        bare-metal semihosting harnesses (xtensa + riscv) for qemu
scripts/           setup / env / build / analyze
docs/              detailed findings (00–24: toolchains, ABI, IR, FFI matrix, D safety/features, TMP-FFI, DWARF/codegen audit, LDC espressif-fork, TinyGo)
Research.md        headline write-up
HANDOFF.md         current state + next steps
CLAUDE.md          orientation for future automated sessions
```

## Headline results

- **Host (x86_64) FFI matrix runs and passes** — all 45 cross-language calls
  (C↔C++↔Rust↔Zig↔D, incl. struct-by-value, sret, f32/f64, i64, callbacks).
  TinyGo is exercised standalone in `experiments/tinygo/` and shares the
  byte-identical datalayout but stays outside the matrix per docs/24.
- **All three Xtensa cores link** as one ELF from a mix of compilers, under
  **both** `ld.lld` **and** GNU `ld`, with **0 unresolved symbols** — including
  images that mix **GCC-built** and **LLVM-built** (clang/rust/zig/D) objects.
- **ABI agreement is verifiable in the disassembly**: `entry`/`retw.n` windowed
  frames, integer args in `a2..a7`, returns in `a2`, callbacks via `callx8` —
  identical across clang, rust, zig, D, gcc, *and* TinyGo (per its
  intermediate ELF, docs/22 §g + docs/24).
- **IR interop**: every LLVM frontend in the matrix shares the byte-identical
  Xtensa `target datalayout` (clang/rust/zig/D/TinyGo — docs/04). The espressif-fork
  LDC matches the trio; the upstream-22 LDC used to differ (docs/23); TinyGo
  on LLVM-20 still matches byte-for-byte (docs/24 §c). Same-version (21.1.3)
  bitcode is LTO-mergeable across the **LLVM-21 cluster** (clang↔rust↔D);
  zig 0.17's 22.1.4 sits in a **second LLVM-22 cluster** with the optional
  upstream LDC + `$LDC_LLVM_DIR` binutils. TinyGo (20.1.1) is outside both.
  The LLVM-22 `llvm-link` reads esp-clang 21.1.3 bitcode fine, so cross-
  cluster IR merging works (docs/04).
- **One frontend mis-handles by-value struct *arguments*** on the canonical
  lane (Rust/clang/gcc/Zig 0.17/LDC 1.42.0 all correct): **TinyGo** lowers
  `struct{[N]uint8}` as `[N x i8]` byte-per-register (docs/24 §e), so byte-
  array aggregates round-trip incorrectly on Xtensa. Historically there were
  three outliers — **Zig 0.16** stack-spilled under-aligned (`align(1)`)
  structs on Xtensa and mis-lowered a small `{i32,i32}` to `[2 x i64]` on
  RISC-V; **the previous LDC 1.42-git (LLVM 21.1.3)** marked *every*
  aggregate `byval`/`sret`, so it diverged more broadly across `point_dot`
  (align-4), `blob_sum`, small-struct *returns*, AND C-style bitfields.
  Both are now history on the canonical lane: Zig 0.17 (`$ZIG`) flattens
  to `[N x i32]` like clang (docs/05 §"Zig 0.17 status"), and the
  2026-05-30 LDC 1.42.0 maintainer re-upload (LLVM 22.1.4) drops the
  universal byval/sret lowering — `d_point_dot` is now byte-identical to
  `c_point_dot`, qemu xtensa reports 0 D failures (docs/05 §"LDC 1.42
  status", docs/23). The legacy break is preserved on `$LDC2_UPSTREAM`
  (LDC on upstream LLVM 22.1.2, pre-fix) for the regression tracker. Struct returns ≤reg-size, scalars,
  pointers and callbacks are fine everywhere; **pass structs by pointer**
  across a Zig, D, or TinyGo-byte-array boundary.
- **Confirmed at runtime on qemu** (both `qemu-system-xtensa` and
  `qemu-system-riscv32`): Xtensa → `zig blob_sum FAIL` + `d point_dot`/`d blob_sum
  FAIL`; RISC-V → `zig point_dot FAIL` (D's small struct gated, TinyGo
  out-of-matrix). The by-pointer variant and everything else
  pass for every FFI-matrix language.
