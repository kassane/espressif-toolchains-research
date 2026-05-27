# HANDOFF

Status of the cross-language Xtensa FFI study. Snapshot: initial research pass
complete; all claims in `Research.md`/`docs/` are backed by reproduced tool
output.

## Done

- [x] Pinned + scripted setup of all four toolchains (`scripts/setup.sh`).
      Versions confirmed: clang/LLVM 21.1.3, rustc 1.95-nightly/LLVM 21.1.3,
      zig 0.16.0/LLVM 21.1.0, gcc 15.2.0.
- [x] Confirmed the shared backend: identical CPU feature sets and identical
      `target datalayout` across clang/rust/zig (docs 02, 04).
- [x] FFI matrix (`experiments/ffi-matrix`): one C-ABI contract, 4 implementations,
      1 driver.
  - [x] **Host build runs & PASSes** — 36/36 cross-language calls (doc 03).
  - [x] **esp32 / esp32s2 / esp32s3 all link** as one ELF; 3 linker/compiler
        combos each (lld pure-LLVM, lld GCC-mixed, GNU ld); **0 undefined** (doc 03).
- [x] ABI verified from disassembly: windowed `entry`/`retw.n`, args `a2..a7`,
      callbacks `callx8` — identical clang/rust/zig/gcc (doc 03).
- [x] LLVM IR comparison: clang/rust lower aggregates to the C ABI in-frontend;
      zig defers to the backend (doc 04).
- [x] **Headline finding** — **under-aligned** (`align(1)`) by-value struct
      **arguments** are ABI-incompatible with Zig; proven at the call site, and
      shown by a size×alignment sweep to be alignment- (not size-) driven and
      Xtensa-specific (Zig matches on RISC-V esp32c3). (doc 05,
      `experiments/abi-structs/sweep.sh`).
- [x] IR mixing: `llc` consumes all frontends; clang↔rust cross-language **LTO**
      links; clang↔zig LTO blocked by 21.1.0 vs 21.1.3 bitcode skew (doc 04).
- [x] Binary/size/mangling comparison (doc 06): gcc 174 B < clang 196/212 B <<
      zig 647 B for the 9-fn lib.

## Not done / next steps

- [~] **Execute** the Xtensa images on qemu. The espressif qemu fork
      (`esp-develop-9.2.2-20260417`) is downloaded; a bare-metal harness
      (`experiments/qemu-run`) **runs a semihosting "hello" on the `sim` machine**
      (proves the toolchain output executes on an emulated core). The full FFI
      matrix run still hangs — the harness installs only the window vectors, not
      the kernel/user/double exception vectors, so deep call nesting double-faults.
      Finish via full XEA2 vectors, the `-machine esp32` ROM, or a `-mabi=call0`
      rebuild. Details + log in docs/08-qemu-execution.md.
- [x] **Struct-ABI boundary sweep** — done (`experiments/abi-structs/sweep.sh`).
      Found the trigger is **alignment, not size**: align-1 structs mismatch at
      every size, align-4 match at every size.
- [ ] **`-mlongcalls` / call0 ABI** variant: everything here is the default
      windowed ABI. ESP-IDF builds with `-mlongcalls`; worth confirming FFI holds
      with long calls and (if supported) the call0 ABI.
- [~] **RISC-V** ESP32-C* cores — spot-checked esp32c3 (Zig matches clang for the
      align-1 struct, so the bug is Xtensa-only). Still TODO: full FFI matrix on
      riscv32, and the **espidf** targets (`xtensa-*-espidf`).
- [ ] File/track the Zig large-struct ABI gap upstream (zig Xtensa C-ABI lowering)
      once reduced to a minimal repro (start from `experiments/abi-structs`).
- [ ] Get a version-matched LLVM-21 `llvm-link`/`opt` to demonstrate true
      module-merge (today only LTO is available; host tools are LLVM 18).

## How to resume

```bash
./scripts/setup.sh && source scripts/env.sh
./scripts/build-ffi.sh all && ./scripts/analyze.sh esp32
```

Everything regenerates into `build/` (gitignored). See `CLAUDE.md` for the
solved gotchas before changing build commands.
