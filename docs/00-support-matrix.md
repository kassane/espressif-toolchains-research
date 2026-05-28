# 00 — Xtensa support matrix: Rust × Zig × D × esp-clang × GCC

At-a-glance comparison for ESP32-class **Xtensa** targets, distilled from the
experiments in this repo. Legend: ✓ works / correct · ✗ broken · — n/a.

## Identity & availability

| | **Rust** (esp-rs) | **Zig** (esp bootstrap) | **D** (LDC) | **esp-clang** | **GCC** (crosstool-NG) |
|---|---|---|---|---|---|
| version | 1.95.0-nightly | 0.16.0 | LDC 1.42-git | 21.1.3 | 15.2.0 |
| backend | LLVM **21.1.3** | LLVM **21.1.0** | LLVM **22.1.2** | LLVM **21.1.3** | GCC (own) |
| Xtensa via | **`esp-rs/rust` fork** | **`kassane/zig-espressif-bootstrap` fork** | **upstream LLVM** (experimental target) | **`espressif/llvm-project` fork** | `espressif/crosstool-NG` |
| works on **upstream**? | ✗ — esp-rs is a *fork*; upstream rustc has only Tier-3 *target specs*, no working Xtensa codegen | partial — Zig 0.16 has no esp32; 0.17.0-dev (Codeberg) adds `esp32` only (no s2/s3); **fork** has all three | ~ — rides upstream LLVM's *experimental* Xtensa target (LDC CI build, `-mtriple=xtensa`); no espressif fork needed | ✗ — **espressif/llvm ≠ upstream LLVM**; upstream's Xtensa backend is experimental/partial (esp32/esp8266 only) | ~ — Xtensa is in upstream GCC, but the esp32/s2/s3 cores come from espressif |
| esp32 / s2 / s3 | ✓ / ✓ / ✓ | ✓ / ✓ / ✓ | ✓ / ✓ / ✓ (via `-mcpu`) | ✓ / ✓ / ✓ | ✓ / ✓ / ✓ |
| `core`/libc model | no prebuilt core → `-Zbuild-std=core` + rust-src | freestanding (no std) | `-betterC` (no druntime/Phobos) | freestanding | newlib + libgcc |

> **All three LLVM toolchains require an Espressif *fork* for usable ESP/Xtensa
> support.** `esp-rs/rust` is a fork of rustc (built against espressif's LLVM) —
> *upstream* `rustc` cannot build for Xtensa even though it carries Tier-3 target
> specs. Likewise **`espressif/llvm-project` ≠ upstream LLVM**: the espressif fork
> has the complete esp32/s2/s3 backend; upstream LLVM's Xtensa target is still
> experimental (only esp32/esp8266). Zig needs the espressif bootstrap fork too:
> upstream Zig 0.16 has no esp32 CPU, and while 0.17.0-dev (now on
> `codeberg.org/ziglang/zig`) adds `esp32` via upstream LLVM, it still lacks
> esp32-s2/s3 — **only the fork has all three, exactly like the Rust fork.** Only
> GCC's Xtensa core is upstream — and even then the ESP core configs ship via
> `espressif/crosstool-NG`. **D/LDC is the exception**: it rides *upstream*
> LLVM's experimental Xtensa target directly (no espressif fork), at the cost of
> a literal-pool link bug worked around by re-assembling with esp clang (docs/19).

## How to target an esp32 core

| | command |
|---|---|
| Rust | `cargo build -Z build-std=core --target xtensa-esp32-none-elf` |
| Zig | `zig build-obj -target xtensa-freestanding-none -mcpu=esp32` |
| D (LDC) | `ldc2 -mtriple=xtensa-esp-elf -mcpu=esp32 -betterC` *(then re-assemble `-output-s` with esp clang; docs/19)* |
| esp-clang | `clang --target=xtensa-esp-elf -mcpu=esp32` |
| GCC | `XTENSA_GNU_CONFIG=…/xtensa_esp32.so xtensa-esp-elf-gcc` *(mandatory: default core is big-endian)* |

## ABI & FFI correctness (the core result — docs 03/05)

| | **Rust** | **Zig** | **D** | **esp-clang** | **GCC** |
|---|:---:|:---:|:---:|:---:|:---:|
| windowed ABI (`entry`/`retw.n`, args `a2..a7`, `callx8`) | ✓ | ✓ | ✓ | ✓ | ✓ |
| int / i64 / f32 / f64 / pointer / callback C-ABI | ✓ | ✓ | ✓ | ✓ | ✓ |
| small struct `{i32,i32}` by value | ✓ | ✓ | **✗** | ✓ | ✓ |
| **under-aligned (`align(1)`) struct by-value *arg*** | ✓ | **✗** | **✗** | ✓ | ✓ |
| small struct return (8-byte, in regs) | ✓ | ✓ | **✗** | ✓ | ✓ |
| large struct return (`sret`) | ✓ | ✓ | ✓ | ✓ | ✓ |
| links under `ld.lld` | ✓ | ✓ | ✓¹ | ✓ | ✓ |
| links under GNU `ld` | ✓ | ✓ | ✓¹ | ✓ | ✓ |

> Two experimental outliers. **Zig** stack-spills only the `align(1)` by-value
> struct arg (alignment-, not size-driven; runtime `242≠300`). **D/LDC** is
> broader: it marks *every* aggregate `byval`/`sret` (indirect), so it diverges
> for the **small `{i32,i32}` arg AND the align-1 arg AND the small-struct
> return** — everything the C ABI puts in registers (runtime `point_dot` + `blob_sum`
> both FAIL on Xtensa; the small struct even *faults* on RISC-V). The lone struct
> case D gets right is the >16-byte `sret` return (the C ABI is *also* indirect
> there). Rust, clang, GCC all agree on everything. **Use by-pointer structs
> across any Zig or D boundary** (runtime-verified fix; docs 10/11/19).
> ¹ D needs LDC's `-output-s` re-assembled with esp clang (literal-pool bug, docs/19).

## Codegen, tooling & misc

| | **Rust** | **Zig** | **D** | **esp-clang** | **GCC** |
|---|---|---|---|---|---|
| 9-fn lib `.text`, esp32 `-Os` | 179 B | **443 B** (+200 B default `.eh_frame`) | ~366 B | 192 B | **174 B** |
| symbol mangling (internal) | v0 `_R…` / legacy `_ZN…` | module-qualified + export alias | D `_D…` / Itanium `_Z…` for `extern(C++)` | Itanium `_Z…` | Itanium `_Z…` |
| FFI export | `#[no_mangle] extern "C"` | `export fn` | `extern(C)` / `extern(C++[,"ns"])` | `extern "C"` | (C) |
| call / emit `@"mangled"` symbols | — | ✓ (docs/12) | ✓ native `extern(C++)` + `-HC` header (docs/19) | — | — |
| cross-language **LTO** peer | esp-clang (both 21.1.3) ✓ | ✗ skew (21.1.0 vs 21.1.3) | **esp-clang ✓** (22.1.2 bc accepted; docs/19) | Rust ✓ | — (not LLVM) |
| call0 ABI | LLVM `-windowed` feat. | LLVM `-windowed` feat. | LLVM `-windowed` feat. | LLVM `-windowed` feat. | `-mabi=call0` |
| f32: esp32 / esp32-s3 | HW FPU | HW FPU | HW FPU | HW FPU | HW FPU |
| f32: esp32-**s2** (no FPU) | soft `__mulsf3` | soft | soft | soft | soft |
| soft-float/builtins | `compiler_builtins` | `compiler_rt` | `compiler-rt` | `compiler-rt` | `libgcc` |
| runtime-run on qemu | ✓ (docs/08/09) | ✓ | ✓ (docs/19) | ✓ | ✓ (objs) |

## One-line verdict

The shared LLVM backend gives a **shared, interoperable ABI** across all five
toolchains on Xtensa for everything except **by-value aggregate lowering** in the
two frontends that defer it to the backend: **Zig** (only the `align(1)` arg) and
**D/LDC** (every register-passed struct — broader). Use **by-pointer** structs
across either boundary. Rust matches clang/GCC bit-for-bit; GCC is the smallest,
Zig the largest. Object files link across all five (incl. D, via a literal-pool
re-assembly). Cross-language LTO needs compatible LLVM bitcode — clang↔rust and,
surprisingly, **clang↔D (LLVM 22.1.2)** work, while clang↔zig (21.1.0) does not.
D is the only one on *upstream* LLVM, with the richest C/C++ FFI (native Itanium
mangling, `-HC` headers). Details: docs 01–19; `Research.md`.
