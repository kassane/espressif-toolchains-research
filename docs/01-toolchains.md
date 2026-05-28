# 01 — Toolchains

Five toolchains, pinned. All are x86_64-linux hosted cross-compilers (except the
host-capable parts of Zig/Rust used for the runnable host test). The four LLVM
frontends are clang/rust/zig (espressif LLVM-21 fork) + D/LDC (upstream LLVM-22);
GCC is the non-LLVM control.

## Pins & download URLs

| # | Component | Repo / tag | Asset | Size |
|---|-----------|-----------|-------|------|
| 1 | Zig | `kassane/zig-espressif-bootstrap` @ `0.16.0-xtensa` | `zig-relsafe-x86_64-linux-musl-baseline.tar.xz` | 75 MB |
| 2 | clang/LLVM | `espressif/llvm-project` @ `esp-21.1.3_20260408` | `clang-esp-21.1.3_20260408-x86_64-linux-gnu.tar.xz` | 398 MB |
| 3 | Rust | `esp-rs/rust-build` @ `v1.95.0.0` | `rust-1.95.0.0-x86_64-unknown-linux-gnu.tar.xz` (+ `rust-src-1.95.0.0.tar.xz`) | 168 MB |
| 4 | GCC | `espressif/crosstool-NG` @ `esp-15.2.0_20251204` | `xtensa-esp-elf-15.2.0_20251204-x86_64-linux-gnu.tar.xz` | 173 MB |
| 5 | D / LDC | `ldc-developers/ldc` @ `CI` (`ldc2-c8305d0a`) | `ldc2-c8305d0a-linux-x86_64.tar.xz` | 142 MB |
| 6 | LLVM-22 binutils *(opt)* | `ldc-developers/llvm-project` @ `ldc-v22.1.2` | `llvm-22.1.2-linux-x86_64.tar.zst` | 405 MB |

`scripts/setup.sh` fetches, verifies (`xz -t`) and lays out 1–5 under `$TC`
(`/home/user/toolchains`). Component 6 (the matching LLVM-22 `llvm-link`/`opt`/
`llvm-dis`, a `.tar.zst` needing `zstd`) is optional — fetched only with
`LLVM22=1` (it enables cross-frontend IR module-merge, docs/04).

## Reported versions

```
zig                : 0.16.0
zig cc (bundled)   : clang version 21.1.0  (kassane/zig-espressif-bootstrap)
esp clang          : Espressif clang version 21.1.3 (esp-21.1.3_20260408)   [LLVM 21.1.3]
rustc              : 1.95.0-nightly (95e5bda86 2026-04-15)  →  LLVM version: 21.1.3
xtensa-esp-elf-gcc : 15.2.0 (crosstool-NG esp-15.2.0_20251204)
ldc2               : 1.42.0-git-c8305d0 (DMD v2.112.1)  →  LLVM version: 22.1.2
```

**Backend alignment:** clang and rust are *the same* LLVM point release (21.1.3);
Zig is one patch behind (21.1.0); D/LDC is a whole release ahead (**22.1.2**, on
*upstream* LLVM). The 21.1.0 vs 21.1.3 gap is invisible for object-level FFI but
blocks cross-language **LTO** with Zig; D's 22.1.2 bitcode, surprisingly, still
LTO-links with the 21.1.3 reader (see
[04-llvm-ir-and-mixing.md](04-llvm-ir-and-mixing.md)).

## Per-toolchain notes / gotchas

### clang (espressif/llvm-project)
- Default triple is **`riscv32-esp-unknown-elf`** — Xtensa needs an explicit
  `--target=xtensa-esp-elf -mcpu=esp32|esp32s2|esp32s3`.
- Cross-only build: **no X86 target**, so it cannot compile the host test
  (`error: No available targets … "x86_64-…"`). We use `zig cc` for host C/C++.
- Ships `llc`, `ld.lld`, `llvm-objdump`, `llvm-readobj`, … but **not**
  `llvm-link`/`opt`/`llvm-as`/`llvm-dis` (component 6 supplies those at LLVM 22).
- Per-multilib compiler-rt builtins at
  `esp-clang/lib/clang-runtimes/xtensa-esp-unknown-elf/<cpu>/lib/libclang_rt.builtins.a`.

### rustc (esp-rs/rust-build)
- A **fork of rustc**, built against `espressif/llvm-project`. **Stock upstream
  `rustc` cannot compile for Xtensa** — it has Tier-3 target *specs* only, and its
  bundled upstream LLVM lacks the production Xtensa backend. Use the esp-rs fork
  (e.g. via `espup`), not a regular toolchain.
- Targets: `xtensa-esp32-none-elf`, `xtensa-esp32s2-none-elf`,
  `xtensa-esp32s3-none-elf` (+ `*-espidf`, `xtensa-esp8266-none-elf`).
- Ships **only** `rust-std-x86_64-unknown-linux-gnu` — **no precompiled xtensa
  `core`**. So Xtensa builds need `-Z build-std=core` + the `rust-src` component.
- The release is split into components; `setup.sh` runs its `install.sh` to merge
  rustc + host std + cargo into one prefix (`$TC/rust-esp`) — required for
  `build-std`, whose `compiler_builtins` build script compiles for the host.
- `rust-src` is symlinked into `…/rust-esp/lib/rustlib/src/rust`.

### Zig (kassane/zig-espressif-bootstrap)
- Xtensa CPUs in `zig targets`: `esp32`, `esp32s2`, `esp32s3` (+ `esp8266` and
  the RISC-V `esp32c*`).
- Build objects with `-target xtensa-freestanding-none -mcpu=<cpu>`.
- `zig cc`/`zig c++` is a full clang 21 driver **with** the X86 target, so it
  doubles as the host C/C++ compiler. By default it enables ubsan-rt and (for
  C++) libc++; on bare-metal use `-nostdlib`/`-ffreestanding`.

### D / LDC (ldc-developers/ldc)
- The rolling **`CI`** pre-release (LLVM **22.1.2**); the tagged stable LDC 1.42
  is LLVM 21.1.8, too old. The **only** toolchain here not on an espressif fork —
  it rides *upstream* LLVM's experimental Xtensa target.
- Build with `ldc2 -mtriple=xtensa-esp-elf -mcpu=esp32 -betterC` (`-betterC` drops
  druntime/Phobos = freestanding). **Only `esp32` is a recognized CPU** —
  `esp32s2`/`esp32s3` are "not a recognized processor", so pass features by hand
  (`-mattr=+windowed,+density,+mul32,…`; `env.sh` has `ldc_xtensa_flags`).
- A direct `ldc2 -c` Xtensa object **fails to link** (the integrated assembler
  mis-aligns the `l32r` literal pool); `build-ffi.sh` works around it by emitting
  `-output-s`, stripping `.cfi_*`, and re-assembling with esp clang. See docs/19.
- Component 6 ships the matching LLVM-22 `llvm-link`/`opt`/`llvm-dis` under
  `$LDC_LLVM_DIR/bin` (not on PATH — call explicitly).

### GCC (espressif/crosstool-NG)
- The unified `xtensa-esp-elf-gcc` selects the Xtensa **core *and endianness*** at
  runtime via a dynamic-config shared library:
  `XTENSA_GNU_CONFIG=$TC/xtensa-esp-elf/lib/xtensa_<cpu>.so`.
- **Critical:** with no dynconfig the default core is **big-endian generic
  Xtensa** — ESP cores are little-endian, so every esp build must set
  `XTENSA_GNU_CONFIG`. `env.sh` provides the `xtensa_cfg <cpu>` helper.
- libgcc (soft-float/64-bit builtins) at
  `xtensa-esp-elf/lib/gcc/xtensa-esp-elf/15.2.0/libgcc.a`.
