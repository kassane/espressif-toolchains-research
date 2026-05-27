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
- [x] **Headline finding** — large (`>16 B`) by-value struct **arguments** are
      ABI-incompatible with Zig; proven at the call site (doc 05).
- [x] IR mixing: `llc` consumes all frontends; clang↔rust cross-language **LTO**
      links; clang↔zig LTO blocked by 21.1.0 vs 21.1.3 bitcode skew (doc 04).
- [x] Binary/size/mangling comparison (doc 06): gcc 174 B < clang 196/212 B <<
      zig 647 B for the 9-fn lib.

## Not done / next steps

- [ ] **Execute** the Xtensa images. They are statically linked & disassembled
      but not run. `qemu-system-xtensa` (espressif fork) with a real esp32 machine
      + bootloader, or an esp-idf semihosting harness, would turn the static ABI
      proof into a runtime one — and would let the large-struct bug fail loudly.
- [ ] **Boundary sweep** for the struct ABI: test 12 B and 16 B structs to pin the
      exact size where Zig starts to diverge (we have 8 B = OK, 24 B = broken).
- [ ] **`-mlongcalls` / call0 ABI** variant: everything here is the default
      windowed ABI. ESP-IDF builds with `-mlongcalls`; worth confirming FFI holds
      with long calls and (if supported) the call0 ABI.
- [ ] **espidf targets** (`xtensa-*-espidf`) and the **RISC-V** ESP32-C* cores —
      the same backend hosts riscv32 (it is esp clang's default triple); repeat
      the matrix there.
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
