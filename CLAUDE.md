# CLAUDE.md — orientation for automated sessions

This repo is a **research & test bed**, not a shipping product. Goal: study
cross-language FFI (Zig / Rust / D / C / C++) on Xtensa (ESP32 / S2 / S3) over the
shared LLVM backend, compare features / LLVM IR / binaries, and document the
findings. Read `Research.md` first, then `docs/`.

## Environment facts

- Host: x86_64 Linux, 4 CPUs, ~15 GB RAM, ~31 GB free disk. Network: outbound OK
  (the five toolchains download from GitHub release CDNs).
- **GitHub API is rate-limited** on this shared IP (unauthenticated 60/hr). To
  discover release assets use the **download CDN** (`releases/download/...`,
  `releases/expanded_assets/<tag>`) or `WebFetch`, not `api.github.com`.

## Toolchains (live OUTSIDE the repo)

`scripts/setup.sh` installs into `/home/user/toolchains` (`$TC`); downloads cache
in `/home/user/dl`. **Never commit these** (`.gitignore` guards `toolchains/`,
`dl/`, `*.tar.xz`, `build/`). `source scripts/env.sh` exports:

| var | points at |
|-----|-----------|
| `$ZIG` | zig 0.16.0 (also `zig cc`/`zig c++`, the only host-capable C/C++ here) |
| `$CLANG`/`$CLANGXX` | esp clang 21.1.3 (cross-only: **no X86 target**) |
| `$RUSTC`/`$CARGO` | merged rust-esp prefix (1.95-nightly, LLVM 21.1.3) |
| `$GCC` | xtensa-esp-elf-gcc 15.2.0 |
| `$LDC2` | LDC 1.42-git, LLVM **22.1.2** (D; `-betterC` for bare-metal). Xtensa is upstream-LLVM experimental — needs the `-output-s`+esp-clang re-assembly in build-ffi.sh (docs/19) |
| `$LDC_LLVM_DIR` | LLVM **22.1.2** binutils (llvm-link/opt/llvm-dis/llvm-as) matching LDC — the IR-merge tools esp-clang omits. Optional (`setup.sh LLVM22=1`; `.tar.zst`, needs `zstd`). NOT on PATH (would shadow esp-clang's 21.1.3 tools) — call `$LDC_LLVM_DIR/bin/<tool>` (docs/04) |
| `xtensa_cfg <cpu>` | path to `xtensa_<cpu>.so` for `XTENSA_GNU_CONFIG` |

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
   LLVM 18 and reject LLVM-21/22 IR. Two fixes: (a) the **LLVM-22 binutils**
   (`$LDC_LLVM_DIR`, `setup.sh LLVM22=1`) read all post-18 IR — `llvm-link` merges
   all five frontends into one module (`experiments/llvm-ir-mix/run.sh`); (b) for
   esp32 *codegen*, mix via cross-language **LTO** (`ld.lld`, the 21.1.3 reader):
   clang↔rust (both 21.1.3) and — surprisingly — clang↔D (LDC **22.1.2** bc) link;
   zig (21.1.0) fails "Invalid record" (docs/04/19). Version skew is not a simple
   "must match" rule; upstream LLVM-22 has no `esp32` CPU, so it can't codegen esp32.

## Repo map

```
experiments/ffi-matrix/   the contract (include/ffi_abi.h) + 5 impls (c/cpp/rust/zig/d) + driver + xtensa.ld
experiments/abi-structs/  caller.c / caller.zig — isolates the large-struct ABI bug
experiments/llvm-ir-mix/  mix*.c + mix_rs + run.sh — LTO probes & LLVM-22 llvm-link module-merge
experiments/dlang/        cppiface.d + run.sh + safety.sh — D/LDC deep-dive (ABI, extern(C++), -HC, LTO; @safe/preview/edition vs Rust)
scripts/                  setup.sh env.sh build-ffi.sh analyze.sh run-qemu.sh
docs/00..20               support-matrix / toolchains / abi / … / addrspace / dlang-ldc / dlang-safety
Research.md HANDOFF.md     headline write-up / status
```

## House style

- Findings must be backed by **real tool output**, never asserted. Re-run
  `build-ffi.sh`/`analyze.sh` and quote actual disassembly/IR.
- Keep big artifacts in `build/` (gitignored); commit curated excerpts in docs.
