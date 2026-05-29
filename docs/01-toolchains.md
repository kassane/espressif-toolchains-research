# 01 — Toolchains

Six toolchains, pinned. All are x86_64-linux hosted cross-compilers (except the
host-capable parts of Zig/Rust used for the runnable host test). Four LLVM
frontends — clang/rust/zig **and now D/LDC** (since docs/23) — ride the same
espressif/llvm-project Xtensa fork (LLVM 21.x); **TinyGo** (since docs/24) is a
fifth LLVM frontend on its own bundled LLVM 20.1.1 fork (tinygo-org). GCC is
the non-LLVM control. The upstream-LLVM-22 LDC remains as `$LDC2_UPSTREAM` for
the comparison.

## Pins & download URLs

| # | Component | Repo / tag | Asset | Size |
|---|-----------|-----------|-------|------|
| 1 | Zig | `kassane/zig-espressif-bootstrap` @ `0.16.0-xtensa` | `zig-relsafe-x86_64-linux-musl-baseline.tar.xz` | 75 MB |
| 1b | Zig 0.17 (fix lane) | `kassane/zig-espressif-bootstrap` @ `0.16.0-xtensa-dev` | `zig-0.17.0-relsafe-x86_64-linux-musl-baseline.tar.xz` | 76 MB |
| 2 | clang/LLVM | `espressif/llvm-project` @ `esp-21.1.3_20260408` | `clang-esp-21.1.3_20260408-x86_64-linux-gnu.tar.xz` | 398 MB |
| 3 | Rust | `esp-rs/rust-build` @ `v1.95.0.0` | `rust-1.95.0.0-x86_64-unknown-linux-gnu.tar.xz` (+ `rust-src-1.95.0.0.tar.xz`) | 168 MB |
| 4 | GCC | `espressif/crosstool-NG` @ `esp-15.2.0_20251204` | `xtensa-esp-elf-15.2.0_20251204-x86_64-linux-gnu.tar.xz` | 173 MB |
| 5 | D / LDC (canonical) | `kassane/esp-idf-dlang` @ `xtensa-toolchain` | `ldc2-v1.42.0-espressif-linux-musl-static.tar.xz` | 48 MB |
| 5b | D / LDC (upstream, *opt*) | `ldc-developers/ldc` @ `CI` (`ldc2-c8305d0a`) | `ldc2-c8305d0a-linux-x86_64.tar.xz` | 142 MB |
| 6 | LLVM-22 binutils *(opt)* | `ldc-developers/llvm-project` @ `ldc-v22.1.2` | `llvm-22.1.2-linux-x86_64.tar.zst` | 405 MB |
| 7 | TinyGo | `tinygo-org/tinygo` @ `v0.41.1` | `tinygo0.41.1.linux-amd64.tar.gz` | 172 MB |

`scripts/setup.sh` fetches, verifies (asset 5 also has a hand-pinned sha256)
and lays out 1–5 under `$TC` (`/home/user/toolchains`). Components 5b
(comparison-only upstream LDC) and 6 (the matching LLVM-22 `llvm-link`/`opt`/
`llvm-dis`, a `.tar.zst` needing `zstd`) are opt-in via
`LDC_UPSTREAM=1`/`LLVM22=1`; needed only to run `experiments/ldc-fork-comparison`
(docs/23). The canonical 5th frontend (asset 5) version-matches esp-clang's
21.1.x binutils, so cross-frontend IR work doesn't require asset 6.

## Reported versions

```
zig                : 0.16.0
zig (fix lane)     : 0.17.0-xtensa                       →  bundled clang 22.1.4 / LLVM 22.1.4
zig cc (bundled)   : clang version 21.1.0  (kassane/zig-espressif-bootstrap)
esp clang          : Espressif clang version 21.1.3 (esp-21.1.3_20260408)   [LLVM 21.1.3]
rustc              : 1.95.0-nightly (95e5bda86 2026-04-15)  →  LLVM version: 21.1.3
xtensa-esp-elf-gcc : 15.2.0 (crosstool-NG esp-15.2.0_20251204)
ldc2 (canonical)   : 1.42.0-git-04a6c8b (DMD v2.112.1)  →  LLVM version: 21.1.3 (espressif fork)
ldc2 (upstream,opt): 1.42.0-git-c8305d0 (DMD v2.112.1)  →  LLVM version: 22.1.2
tinygo             : 0.41.1 (Go 1.24.7)                 →  LLVM version: 20.1.1 (tinygo-org fork; bundled)
```

**Backend alignment:** clang, rust **and the canonical D/LDC** are now *the
same* LLVM point release (21.1.3, espressif fork); Zig is one patch behind
(21.1.0); the optional upstream LDC is on LLVM 22.1.2 for the comparison. The
21.1.0 vs 21.1.3 gap is invisible for object-level FFI but blocks cross-language
**LTO** with Zig; clang↔rust↔D LTO all share 21.1.3 so they link without
skew (see [04-llvm-ir-and-mixing.md](04-llvm-ir-and-mixing.md) +
[23-ldc-espressif-fork.md](23-ldc-espressif-fork.md)).

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

### D / LDC (kassane/esp-idf-dlang — canonical 5th frontend)
- Built from `ldc-developers/ldc` against **`espressif/llvm-project` LLVM 21.1.3**
  — same backend family as esp-clang and rustc. Static-musl, single 156 MB
  binary; ships its own `ldc2.conf` (including a pre-bundled
  `xtensa-esp32-none-elf` triple alias).
- Build with `ldc2 -mtriple=xtensa-esp-elf -mcpu=esp32 -betterC -c`. `-betterC`
  drops druntime/Phobos (= freestanding). **All three esp32 cores are
  first-class `-mcpu` values:** `esp32` / `esp32s2` / `esp32s3` (no `-mattr`
  fallback needed for the CPU; `env.sh:ldc_xtensa_flags` still pins the
  feature set explicitly to match esp-clang).
- Direct `ldc2 -c` Xtensa objects link cleanly under `ld.lld -T xtensa.ld`
  (literal pools are correctly aligned). The `-output-s` + esp-clang
  re-assembly workaround is **gone**. DWARF survives end-to-end; the producer
  DIE reads `LDC 1.42.0-git-04a6c8b (LLVM 21.1.3)`.

### D / LDC (ldc-developers/ldc — comparison-only, opt-in)
- The rolling **`CI`** pre-release (LLVM **22.1.2**), pinned to `c8305d0a`. The
  *upstream* LLVM Xtensa target is still experimental: only `esp32` is a
  recognized `-mcpu` (esp32s2/s3 are *not a recognized processor* —
  [ldc#4919](https://github.com/ldc-developers/ldc/issues/4919)); direct
  `ldc2 -c` fails to link (`R_XTENSA_SLOT0_OP not aligned to 4 bytes` on the
  `l32r` literal pool); `.cfi_*` directives are emitted but esp-clang's Xtensa
  MC rejects them on re-assembly. Datalayout differs slightly from the
  espressif-21 trio (`i8:8:32-i16:16:32` vs `v1:8:8-i128:128`).
- Opt-in via `LDC_UPSTREAM=1 ./scripts/setup.sh` → `$LDC2_UPSTREAM`. Used only
  by `experiments/ldc-fork-comparison` + docs/23.
- Component 6 (LLVM-22 binutils) version-matches *this* LDC and is what powers
  `experiments/llvm-ir-mix` for the upstream-LDC arm; for the canonical LDC,
  esp-clang's 21.1.3 binutils suffice.

### GCC (espressif/crosstool-NG)
- The unified `xtensa-esp-elf-gcc` selects the Xtensa **core *and endianness*** at
  runtime via a dynamic-config shared library:
  `XTENSA_GNU_CONFIG=$TC/xtensa-esp-elf/lib/xtensa_<cpu>.so`.
- **Critical:** with no dynconfig the default core is **big-endian generic
  Xtensa** — ESP cores are little-endian, so every esp build must set
  `XTENSA_GNU_CONFIG`. `env.sh` provides the `xtensa_cfg <cpu>` helper.
- libgcc (soft-float/64-bit builtins) at
  `xtensa-esp-elf/lib/gcc/xtensa-esp-elf/15.2.0/libgcc.a`.

### TinyGo (tinygo-org/tinygo)
- `v0.41.1` ships **its own LLVM 20.1.1 bundle** (the only LLVM-20 in the
  matrix; clang/rust/D-fork are 21.1.3, zig 21.1.0, upstream-LDC 22.1.2).
- Targets `esp32 + esp32s3 + esp32c3` (per-board variants too); **no `esp32s2`** —
  TinyGo upstream doesn't ship that target.
- Build with `tinygo build -target=esp32-coreboard-v2 -o app.bin app.go`.
  `tinygo info <target>` lists the per-board LLVM triple, `-mattr`, GOARCH
  build tags, garbage collector, scheduler — see `experiments/tinygo/run.sh`.
- **Whole-program compiler:** there's no `-c` relocatable mode outside wasm
  (`-buildmode=c-shared` is wasm-only), so TinyGo can't join the FFI matrix as
  a co-linkable column (docs/24). For inspection, `tinygo build -work`
  preserves the intermediate dir under `/tmp/tinygo*/`; the linked `main` is a
  real Xtensa ELF and `main.o` is LLVM-20 bitcode (readable by
  `$LDC_LLVM_DIR/bin/llvm-dis` or any newer `llvm-dis`).
- **CLI footguns** (encoded in `experiments/tinygo/run.sh` comments):
  - Stdout/stderr merge (`2>&1`) silently truncates the build log and reports
    `rc=1`; split the streams (`>out 2>err`).
  - Go ignores files whose name starts with `_` even when named on the command
    line; `_probe.go` silently compiles to no output.
