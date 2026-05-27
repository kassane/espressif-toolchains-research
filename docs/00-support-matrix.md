# 00 — Xtensa support matrix: Rust × Zig × esp-clang × GCC

At-a-glance comparison for ESP32-class **Xtensa** targets, distilled from the
experiments in this repo. Legend: ✓ works / correct · ✗ broken · — n/a.

## Identity & availability

| | **Rust** (esp-rs) | **Zig** (esp bootstrap) | **esp-clang** | **GCC** (crosstool-NG) |
|---|---|---|---|---|
| version | 1.95.0-nightly | 0.16.0 | 21.1.3 | 15.2.0 |
| backend | LLVM **21.1.3** | LLVM **21.1.0** | LLVM **21.1.3** | GCC (own) |
| Xtensa via | `esp-rs/rust` fork | `kassane/zig-espressif-bootstrap` | `espressif/llvm-project` | `espressif/crosstool-NG` |
| upstream Xtensa? | Tier-3, upstreaming | ✗ (needs the fork) | WIP, upstreaming | ✓ (origin of Xtensa GCC) |
| esp32 / s2 / s3 | ✓ / ✓ / ✓ | ✓ / ✓ / ✓ | ✓ / ✓ / ✓ | ✓ / ✓ / ✓ |
| `core`/libc model | no prebuilt core → `-Zbuild-std=core` + rust-src | freestanding (no std) | freestanding | newlib + libgcc |

## How to target an esp32 core

| | command |
|---|---|
| Rust | `cargo build -Z build-std=core --target xtensa-esp32-none-elf` |
| Zig | `zig build-obj -target xtensa-freestanding-none -mcpu=esp32` |
| esp-clang | `clang --target=xtensa-esp-elf -mcpu=esp32` |
| GCC | `XTENSA_GNU_CONFIG=…/xtensa_esp32.so xtensa-esp-elf-gcc` *(mandatory: default core is big-endian)* |

## ABI & FFI correctness (the core result — docs 03/05)

| | **Rust** | **Zig** | **esp-clang** | **GCC** |
|---|:---:|:---:|:---:|:---:|
| windowed ABI (`entry`/`retw.n`, args `a2..a7`, `callx8`) | ✓ | ✓ | ✓ | ✓ |
| int / i64 / f32 / f64 / pointer / callback C-ABI | ✓ | ✓ | ✓ | ✓ |
| small struct `{i32,i32}` by value | ✓ | ✓ | ✓ | ✓ |
| **under-aligned (`align(1)`) struct by-value *arg*** | ✓ | **✗** | ✓ | ✓ |
| large struct return (`sret`) | ✓ | ✓ | ✓ | ✓ |
| links under `ld.lld` | ✓ | ✓ | ✓ | ✓ |
| links under GNU `ld` | ✓ | ✓ | ✓ | ✓ |

> The single ✗: Zig's experimental Xtensa target stack-spills an `align(1)`
> by-value struct argument instead of using the `[N x i32]`-in-registers C ABI
> (alignment-, not size-driven; runtime-confirmed `242≠300` on qemu). Rust, clang
> and GCC all agree. (On RISC-V Zig instead breaks a *small* `{i32,i32}` arg —
> docs/09. Use **by-pointer** structs across any Zig boundary — docs/10/11.)

## Codegen, tooling & misc

| | **Rust** | **Zig** | **esp-clang** | **GCC** |
|---|---|---|---|---|
| 9-fn lib `.text`, esp32 `-Os` | 179 B | **647 B** | 196 B | **174 B** |
| symbol mangling (internal) | v0 `_R…` / legacy `_ZN…` | module-qualified + export alias | Itanium `_Z…` | Itanium `_Z…` |
| FFI export | `#[no_mangle] extern "C"` | `export fn` | `extern "C"` | (C) |
| call `@"mangled"` symbols | — | ✓ (docs/12) | — | — |
| cross-language **LTO** peer | esp-clang (both 21.1.3) ✓ | ✗ skew (21.1.0 vs 21.1.3) | Rust ✓ | — (not LLVM) |
| call0 ABI | LLVM `-windowed` feat. | LLVM `-windowed` feat. | LLVM `-windowed` feat. | `-mabi=call0` |
| f32: esp32 / esp32-s3 | HW FPU | HW FPU | HW FPU | HW FPU |
| f32: esp32-**s2** (no FPU) | soft `__mulsf3` | soft | soft | soft |
| soft-float/builtins | `compiler_builtins` | `compiler_rt` | `compiler-rt` | `libgcc` |
| runtime-run on qemu | ✓ (docs/08/09) | ✓ | ✓ | ✓ (objs) |

## One-line verdict

The shared LLVM 21 backend gives a **shared, interoperable ABI** across Rust,
Zig, esp-clang and GCC on Xtensa for everything except **Zig's by-value
struct-argument lowering** (use pointers there). Rust matches clang/GCC bit-for-
bit; GCC is the smallest; Zig is the largest and the one experimental outlier.
Linkers and object files are mutually compatible; cross-language LTO additionally
requires one matching LLVM point release. Details: docs 01–12; `Research.md`.
