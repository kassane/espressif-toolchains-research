# 00 — Xtensa support matrix: Rust × Zig × D × esp-clang × GCC

At-a-glance comparison for ESP32-class **Xtensa** targets, distilled from the
experiments in this repo. Legend: ✓ works / correct · ✗ broken · — n/a.

## Identity & availability

| | **Rust** (esp-rs) | **Zig** (esp bootstrap) | **D** (LDC) | **esp-clang** | **GCC** (crosstool-NG) | **TinyGo** (docs/24) |
|---|---|---|---|---|---|---|
| version | 1.95.0-nightly | 0.16.0 | LDC 1.42-git | 21.1.3 | 15.2.0 | v0.41.1 |
| backend | LLVM **21.1.3** | LLVM **21.1.0** | LLVM **21.1.3** (espressif fork) | LLVM **21.1.3** | GCC (own) | LLVM **20.1.1** (TinyGo-bundled) |
| Xtensa via | **`esp-rs/rust` fork** | **`kassane/zig-espressif-bootstrap` fork** | **`kassane/esp-idf-dlang` fork** (LDC + `espressif/llvm-project`; docs/23) | **`espressif/llvm-project` fork** | `espressif/crosstool-NG` | **`tinygo-org/llvm-project` fork** (bundled in the tarball; see docs/24) |
| works on **upstream**? | ✗ — esp-rs is a *fork*; upstream rustc has only Tier-3 *target specs*, no working Xtensa codegen | partial — Zig 0.16 has no esp32; 0.17.0-dev (Codeberg) adds `esp32` only (no s2/s3); **fork** has all three | partial — `$LDC2_UPSTREAM` (LLVM 22.1.2) works for `esp32` only (no s2/s3; ldc #4919) and needs the `-output-s` re-assembly workaround; docs/23 | ✗ — **espressif/llvm ≠ upstream LLVM**; upstream's Xtensa backend is experimental/partial (esp32/esp8266 only) | ~ — Xtensa is in upstream GCC, but the esp32/s2/s3 cores come from espressif | n/a — TinyGo bundles its own LLVM and runtime |
| esp32 / s2 / s3 | ✓ / ✓ / ✓ | ✓ / ✓ / ✓ | ✓ / ✓ / ✓ (via `-mcpu`) | ✓ / ✓ / ✓ | ✓ / ✓ / ✓ | ✓ / **✗** / ✓ (no esp32-s2 target) |
| `core`/libc model | no prebuilt core → `-Zbuild-std=core` + rust-src | freestanding (no std) | `-betterC` (no druntime/Phobos) | freestanding | newlib + libgcc | Go runtime + picolibc (bundled) |
| co-linkable `.o` for FFI matrix? | ✓ | ✓ | ✓ | ✓ | ✓ | **✗** — whole-program (firmware-only output; docs/24 §d) |

> **All five LLVM frontends here ride a custom LLVM fork** for Xtensa support
> — four against `espressif/llvm-project` and TinyGo against its own
> `tinygo-org/llvm-project` (LLVM 20.1.1, bundled inside the TinyGo tarball;
> docs/24). Stock upstream LLVM's Xtensa is still experimental (esp32/8266 only). `esp-rs/rust` is a fork of rustc (built against
> espressif's LLVM) — *upstream* `rustc` cannot build for Xtensa even though it
> carries Tier-3 target specs. Likewise **`espressif/llvm-project` ≠ upstream
> LLVM**: the espressif fork has the complete esp32/s2/s3 backend; upstream
> LLVM's Xtensa target is still experimental (only esp32/esp8266). Zig needs
> the espressif bootstrap fork too: upstream Zig 0.16 has no esp32 CPU, and
> while 0.17.0-dev (now on `codeberg.org/ziglang/zig`) adds `esp32` via upstream
> LLVM, it still lacks esp32-s2/s3 — **only the fork has all three, exactly like
> the Rust fork.** Only GCC's Xtensa core is upstream — and even then the ESP
> core configs ship via `espressif/crosstool-NG`. **D/LDC used to be the
> exception** (riding upstream LLVM-22 directly, with a literal-pool re-assembly
> workaround) — but the canonical 5th frontend is now
> [`kassane/esp-idf-dlang`'s LDC](https://github.com/kassane/esp-idf-dlang/releases/tag/xtensa-toolchain)
> on the espressif fork (LLVM 21.1.3, same family as clang/rust/zig). The old
> upstream-22 LDC stays as `$LDC2_UPSTREAM` for the comparison in docs/23.

## How to target an esp32 core

| | command |
|---|---|
| Rust | `cargo build -Z build-std=core --target xtensa-esp32-none-elf` |
| Zig | `zig build-obj -target xtensa-freestanding-none -mcpu=esp32` |
| D (LDC) | `ldc2 -mtriple=xtensa-esp-elf -mcpu=esp32 -betterC -c` *(direct -c on the espressif-fork LDC; the upstream-22 LDC needs `-output-s` re-assembly — docs/23)* |
| esp-clang | `clang --target=xtensa-esp-elf -mcpu=esp32` |
| GCC | `XTENSA_GNU_CONFIG=…/xtensa_esp32.so xtensa-esp-elf-gcc` *(mandatory: default core is big-endian)* |
| TinyGo | `tinygo build -target=esp32-coreboard-v2 -o app.bin app.go` *(default = ESP32 flash image; `-o app.o` does produce a relocatable Xtensa ELF with ~196 KB of Go runtime — docs/24 §d)* |

## ABI & FFI correctness (the core result — docs 03/05)

| | **Rust** | **Zig** | **D** | **esp-clang** | **GCC** | **TinyGo** |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| windowed ABI (`entry`/`retw.n`, args `a2..a7`, `callx8`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| int / i64 / f32 / f64 / pointer / callback C-ABI | ✓ | ✓ | ✓ | ✓ | ✓ | ✓¹ |
| small struct `{i32,i32}` by value | ✓ | ✓ | **✗** | ✓ | ✓ | ✓ (flattens to scalars) |
| **under-aligned (`align(1)`) struct by-value *arg*** | ✓ | **✗** | **✗** | ✓ | ✓ | **✗** (byte-per-register, docs/24 §e) |
| small struct return (8-byte, in regs) | ✓ | ✓ | **✗** | ✓ | ✓ | ✓ |
| large struct return (`sret`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| links under `ld.lld` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓² |
| links under GNU `ld` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓² |

> ¹ TinyGo scalar ABI matches clang per disasm (docs/22 §g; docs/24 §e).
> ² TinyGo `.o` links per-symbol but the consumer must supply the Go runtime
> undefs (`_heap_start`/`_heap_end`, `tinygo_swapTask`, `tinygo_startTask`,
> `tinygo_scanCurrentStack`) or accept the full runtime — docs/24 §d.
>
> Three outliers. **Zig** stack-spills only the `align(1)` by-value struct arg
> (alignment-, not size-driven; runtime `242≠300`). **D/LDC** is broader: it
> marks *every* aggregate `byval`/`sret` (indirect), so it diverges for the
> **small `{i32,i32}` arg AND the align-1 arg AND the small-struct return** —
> everything the C ABI puts in registers (runtime `point_dot` + `blob_sum`
> both FAIL on Xtensa; the small struct even *faults* on RISC-V). The lone
> struct case D gets right is the >16-byte `sret` return (the C ABI is *also*
> indirect there). **TinyGo** joins the byte-array hole: a `struct{[24]uint8}`
> lowers as `[24 x i8]` byte-per-register, not clang's `[6 x i32]` (docs/24
> §e). The D divergence is **frontend-side** — the espressif-fork LDC (LLVM
> 21.1.3) produces the identical broken IR as the upstream-22 LDC (docs/23,
> §(h)), proving the bug isn't in the LLVM Xtensa backend. Rust, clang, GCC
> all agree on everything. **Use by-pointer structs across any Zig, D, or
> TinyGo boundary** (runtime-verified for zig/D; docs/05/10/11/19/24).

## Codegen, tooling & misc

| | **Rust** | **Zig** | **D** | **esp-clang** | **GCC** | **TinyGo** |
|---|---|---|---|---|---|---|
| 9-fn lib `.text`, esp32 `-Os` | 179 B | **715 B** | 533 B | 223 B | **201 B** | n/a (whole-firmware; single `add_i32` is 7 B, docs/22 §g) |
| symbol mangling (internal) | v0 `_R…` / legacy `_ZN…` | module-qualified + export alias | D `_D…` / Itanium `_Z…` for `extern(C++)` | Itanium `_Z…` | Itanium `_Z…` | `<package>.<func>` (e.g. `main.go_add_i32`); `//export name` re-emits as bare `name` |
| FFI export | `#[no_mangle] extern "C"` | `export fn` | `extern(C)` / `extern(C++[,"ns"])` | `extern "C"` | (C) | `//export name` |
| call / emit `@"mangled"` symbols | — | ✓ (docs/12) | ✓ native `extern(C++)` + `-HC` header (docs/19) | — | — | — |
| cross-language **LTO** peer | esp-clang (both 21.1.3) ✓ | ✗ skew (21.1.0 vs 21.1.3) | **esp-clang ✓** (same 21.1.3; docs/19) | Rust ✓ | — (not LLVM) | ✗ skew (LLVM 20.1.1, docs/24) |
| call0 ABI | LLVM `-windowed` feat. | LLVM `-windowed` feat. | LLVM `-windowed` feat. | LLVM `-windowed` feat. | `-mabi=call0` | LLVM `-windowed` feat. (not exposed via TinyGo CLI) |
| f32: esp32 / esp32-s3 | HW FPU | HW FPU | HW FPU | HW FPU | HW FPU | HW FPU |
| f32: esp32-**s2** (no FPU) | soft `__mulsf3` | soft | soft | soft | soft | n/a (no s2 target, docs/24 §a) |
| soft-float/builtins | `compiler_builtins` | `compiler_rt` | `compiler-rt` | `compiler-rt` | `libgcc` | bundled `compiler-rt` + Go runtime |
| runtime-run on qemu | ✓ (docs/08/09) | ✓ | ✓ (docs/19) | ✓ | ✓ (objs) | standalone via `tinygo flash` (docs/24) |

## One-line verdict

The shared LLVM backend gives a **shared, interoperable ABI** across the six
toolchains on Xtensa for everything except **by-value aggregate lowering** in
the three frontends that defer it (Zig, D, TinyGo for byte-arrays) or universally
`byval`/`sret`-it (D). Use **by-pointer** structs across those boundaries. Rust
matches clang/GCC
bit-for-bit; GCC is the smallest, Zig the largest. Object files link across all
five with `ld.lld` and GNU `ld` (D direct `-c` since docs/23). Cross-language
LTO needs compatible LLVM bitcode — clang↔rust↔D (all 21.1.3) work, while
clang↔zig (21.1.0 vs 21.1.3) does not. D has the richest C/C++ FFI surface
(native Itanium mangling, `-HC` headers). Details: docs 01–23; `Research.md`.
