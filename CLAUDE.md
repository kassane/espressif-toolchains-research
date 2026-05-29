# CLAUDE.md — orientation for automated sessions

This repo is a **research & test bed**, not a shipping product. Goal: study
cross-language FFI (Zig / Rust / D / Go / C / C++) on Xtensa (ESP32 / S2 / S3 /
C3) over the shared LLVM backend, compare features / LLVM IR / binaries, and
document the findings. The six toolchains are tracked uniformly where they
co-link; TinyGo is studied standalone (docs/24) because its `.o` drags ~196 KB
of Go runtime. Read `Research.md` first, then `docs/`.

## Environment facts

- Host: x86_64 Linux, 4 CPUs, ~15 GB RAM, ~31 GB free disk. Network: outbound OK
  (the six toolchains download from GitHub release CDNs).
- **GitHub API is rate-limited** on this shared IP (unauthenticated 60/hr). To
  discover release assets use the **download CDN** (`releases/download/...`,
  `releases/expanded_assets/<tag>`) or `WebFetch`, not `api.github.com`.

## Toolchains (live OUTSIDE the repo)

`scripts/setup.sh` installs into `/home/user/toolchains` (`$TC`); downloads cache
in `/home/user/dl`. **Never commit these** (`.gitignore` guards `toolchains/`,
`dl/`, `*.tar.xz`, `build/`). `source scripts/env.sh` exports:

| var | points at |
|-----|-----------|
| `$ZIG` | zig **0.17.0-xtensa** (canonical; bundled clang/LLVM **22.1.4**; also `zig cc`/`zig c++`, the only host-capable C/C++ here). Closes the docs/05 struct-by-value bug + the riscv `zig_point_dot` bug |
| `$ZIG_016` | zig 0.16.0 legacy lane (LLVM 21.1.0) — kept so `experiments/abi-structs/sweep.sh` + qemu can demonstrate the historical break; `ZIG=$ZIG_016 ./scripts/build-ffi.sh ...` to switch (env.sh honors a pre-set ZIG) |
| `$CLANG`/`$CLANGXX` | esp clang 21.1.3 (cross-only: **no X86 target**) |
| `$RUSTC`/`$CARGO` | merged rust-esp prefix (1.95-nightly, LLVM 21.1.3) |
| `$GCC` | xtensa-esp-elf-gcc 15.2.0 |
| `$LDC2` | LDC 1.42-git, espressif/llvm-project **LLVM 21.1.3** (kassane/esp-idf-dlang xtensa-toolchain). D; `-betterC` for bare-metal. esp32/s2/s3 are first-class `-mcpu`; direct `ldc2 -c` -> `ld.lld` works, no re-assembly (docs/19, docs/23) |
| `$LDC2_UPSTREAM` | LDC 1.42-git, **upstream LLVM 22.1.2** (`ldc-developers/ldc CI`). Comparison-only — used by `experiments/ldc-fork-comparison`. Opt-in: `LDC_UPSTREAM=1 ./scripts/setup.sh` |
| `$LDC_PE` | `-preview=all --edition=2025` — the canonical flag bundle every non-probe `$LDC2` invocation includes. 2026 is rejected by LDC 1.42 (`safety.sh` §b). `-preview=all` includes `dip1000`/`safer`/etc.; raw-pointer kernels must be `@system` (the honest annotation for a C-ABI buffer consumer). Docs/20 §2.0. |
| `$LDC_LLVM_DIR` | **LLVM 22.1.2** binutils (llvm-link/opt/llvm-dis/llvm-as). Only useful with `$LDC2_UPSTREAM` — esp-clang's 21.1.3 binutils version-match the canonical `$LDC2` now. Opt-in (`LLVM22=1`; `.tar.zst`, needs `zstd`); NOT on PATH (would shadow esp-clang's tools); call `$LDC_LLVM_DIR/bin/<tool>` (docs/04) |
| `xtensa_cfg <cpu>` | path to `xtensa_<cpu>.so` for `XTENSA_GNU_CONFIG` |
| `ldc_xtensa_flags <cpu>` | `-mcpu=<cpu> -mattr=<features>` string; word-splits in build-ffi.sh/analyze.sh. Mirrors esp-clang's implicit feature set; intersection of both LDC versions' feature lists so the comparison can drive both arms with one string |
| `$TINYGO` | TinyGo v0.41.1 (Go 1.24.7, LLVM **20.1.1** bundled). Targets esp32 / esp32s3 / esp32c3 (no s2). Whole-program compiler — emits a firmware image, not relocatable `.o`, so it sits outside the FFI matrix in `experiments/tinygo/` (docs/24) |

## Build / analyze

```bash
source scripts/env.sh
./scripts/build-ffi.sh all      # host (RUNS, expect PASS) + esp32/s2/s3 link (expect 0 undef)
./scripts/analyze.sh esp32      # -> build/analysis/{features,ir-signatures,disasm,sizes}-esp32.txt
```

LLVM binutils for analysis (`llvm-objdump`, `llvm-readobj`, `llc`, `llvm-size`,
`llvm-nm`) come from `esp-clang/bin`. **Disassemble with `--mcpu=esp32`** or the
windowed `entry` instruction decodes as garbage.

## Non-obvious gotchas (already solved — don't relearn the hard way)

1. **GCC default core is big-endian.** Always set
   `XTENSA_GNU_CONFIG=$(xtensa_cfg <cpu>)` or you get MSB objects that won't match
   the little-endian LLVM ones.
2. **No prebuilt Rust xtensa `core`.** Rust→Xtensa needs `-Z build-std=core` +
   the `rust-src` component symlinked into the sysroot (setup.sh does this).
   `--emit=...` must go after `--` in `cargo rustc`.
3. **esp clang can't target the host** — use `zig cc` for host C/C++.
4. **`llvm-link`/`opt`/`llvm-dis` are not shipped** by esp clang; the host's are
   LLVM 18 and reject LLVM-21/22 IR. The canonical 21.1.3 LDC's bitcode reads
   cleanly via esp-clang's own 21.1.3 binutils — no skew, no extra download.
   Cross-language **LTO** (`ld.lld`): clang↔rust↔D all on 21.1.3 (the **LLVM-21
   cluster**), all link; zig (22.1.4) fails "Invalid record" against the
   21.1.3 `ld.lld` (the version skew got bigger with the 0.17 flip — major
   instead of patch). The optional **LLVM-22 binutils**
   (`$LDC_LLVM_DIR`, `setup.sh LLVM22=1`) form a second cluster with zig 0.17
   + upstream LDC; their LLVM-22 `llvm-link` *also* reads esp-clang 21.1.3
   bitcode (forward-compatible), so cross-cluster IR analysis is reachable —
   only full LTO inlining needs one cluster end-to-end. See docs/04
   §"Two LLVM clusters".
5. **D's by-value struct ABI is a frontend bug, not a backend one.** Both LDC
   variants emit `byval`/`sret` for every aggregate; the espressif-21 fork
   doesn't change that, so `point_dot`/`blob_sum` still FAIL at runtime on
   Xtensa. Pass structs by pointer across a D boundary. Same family as
   [kassane/dlang-mos-hello-world#1](https://github.com/kassane/dlang-mos-hello-world/issues/1)
   (wontfix) — docs/23. **Zig had the same family of bug on 0.16 (LLVM
   21.1.0), closed by `$ZIG` 0.17 (LLVM 22.1.4)** — the frontend now flattens
   to `[N x i32]` matching clang, qemu `zig_blob_sum` passes on xtensa AND
   `zig_point_dot` passes on riscv (docs/05 §"Zig 0.17 status"). `ZIG=$ZIG_016
   ./scripts/build-ffi.sh esp32` reproduces the historical break.

## Repo map

```
experiments/ffi-matrix/   the contract (include/ffi_abi.h) + 5 impls (c/cpp/rust/zig/d) + driver + xtensa.ld
experiments/abi-structs/  sweep.sh — clang/zig/D caller sweep; isolates the by-value struct-arg bug; covers byte arrays, word arrays, AND C-style bitfields (D's native extern(C) bitfield ABI vs clang vs Zig packed struct(uN); docs/05)
experiments/llvm-ir-mix/  mix*.c + mix_rs + run.sh — LTO probes & LLVM-22 llvm-link module-merge
experiments/dlang/        cppiface.d + run.sh + safety.sh + tmpffi.sh + ldc-attrs.sh — D/LDC deep-dive (ABI, extern(C++), -HC, LTO; @safe/@mustuse/@live/preview/edition vs Rust × C++26; embedded TMP-FFI matrix on Xtensa; LDC attribute/pragma family + @assumeUsed cross-frontend parity + import("file") embed matrix — docs/19, /20)
experiments/ldc-fork-comparison/ run.sh — espressif-21 vs upstream-22 LDC side-by-side (docs/23). Requires LDC_UPSTREAM=1.
experiments/atomics-orders/ run.sh — 4-frontend × stores/loads × N orderings, esp32 (atomics gap closed beyond docs/17's single-order probe)
experiments/tinygo/       run.sh — TinyGo v0.41.1 / LLVM 20.1.1 probe; whole-program compiler, outside the FFI matrix (docs/24)
experiments/call0-abi/    run.sh — windowed vs CALL0 ABI (-mcpu=<core>-windowed) across 5 frontends × 3 cores (docs/02 §CALL0)
scripts/                  setup.sh env.sh build-ffi.sh analyze.sh run-qemu.sh
docs/00..24               support-matrix / toolchains / abi / … / dlang-ldc / dlang-safety / tmp-ffi-baremetal / dwarf-codegen-parity / ldc-espressif-fork / tinygo
experiments/dwarf-parity/ run.sh — DWARF & disassembly audit across all 5 toolchains on Xtensa (docs/22)
Research.md HANDOFF.md     headline write-up / status
```

## House style

- Findings must be backed by **real tool output**, never asserted. Re-run
  `build-ffi.sh`/`analyze.sh` and quote actual disassembly/IR.
- Keep big artifacts in `build/` (gitignored); commit curated excerpts in docs.
