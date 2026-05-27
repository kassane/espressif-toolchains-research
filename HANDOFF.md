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
- [x] **Headline finding** — by-value struct **arguments** are ABI-incompatible
      with Zig on Xtensa for **under-aligned** (`align(1)`) structs (alignment-,
      not size-driven; proven at the call site). NOTE: also broken differently on
      RISC-V (small `{i32,i32}` → `[2 x i64]`) — see the corrected entry below;
      not Xtensa-only. (doc 05/09, `experiments/abi-structs/sweep.sh`).
- [x] IR mixing: `llc` consumes all frontends; clang↔rust cross-language **LTO**
      links; clang↔zig LTO blocked by 21.1.0 vs 21.1.3 bitcode skew (doc 04).
- [x] Binary/size/mangling comparison (doc 06): real `.text` rust ~171 ≈ gcc 174
      < clang 192 (C) / 204 (C++) < zig **443** for the 9-fn lib (the 647 figure
      counted zig's default `.eh_frame`; use `llvm-size -A`).

- [x] **Address spaces** (docs/18, `experiments/addrspace/run.sh`): the Xtensa
      backend is single-flat-address-space (datalayout `p:32:32` only), so
      `addrspace(N)` is annotation-only/no-op. clang accepts numbered
      `address_space(N)` (→ IR), **Zig validates per-target** (only `.generic`;
      `.flash` etc. rejected), gcc ignores the numbered attr, Rust has none. ESP
      regions (IRAM/DRAM/flash/RTC) are placed via linker **sections** —
      `section`/`linksection`/`link_section` → `.iram1.text` — at parity in all four.
- [x] **Rust ⇄ Zig frontend interop** (docs/17, `experiments/rust-zig/run.sh`):
      the two non-C LLVM frontends agree on **every scalar ABI incl. C-inexpressible
      `u128`/`f128`/`f16`** (Rust uses byval for the 2nd 16-byte arg, Zig direct —
      backend reconciles; runtime-verified Rust→Zig u128 carry on qemu). The only
      clash is **by-value struct arguments** (Zig's bug — pass by pointer). Object
      FFI links; **cross-language LTO fails** (Rust 21.1.3 vs Zig 21.1.0 bitcode).
- [x] **SIMD / vectorization** (docs/16, `experiments/simd/run.sh`): only ESP32-S3
      has a SIMD unit (`EE.*` PIE, q0–q7; rejected on esp32/s2). **No
      autovectorization** in any of the four — vectorizable loops stay scalar and
      `vector_size` (clang) / `@Vector` (zig) / `core::simd` (rust) all scalarize
      (no q-reg codegen class). Inline asm is the only path; **clang, gcc, zig AND
      rust all assemble `EE.*` (4/4/4/4)**. Zig 0.15+ struct-form clobbers
      `.{ .memory = true, .q0 = true, … }`; Rust needs
      `#![feature(asm_experimental_arch)]` and has no `qreg` class (esp-rs #265).
- [x] **Compiler-driver parity** (docs/15, `experiments/compiler-parity/run.sh`):
      `zig cc` ⇄ `esp-clang` are effectively the same C/C++ compiler (espressif
      clang/LLVM 21; near-identical Xtensa code, differ only in driver defaults —
      zig emits `.eh_frame`/ubsan/libc++); `esp-gcc` has full ABI parity (windowed
      C ABI; byte-identical Itanium C++ mangling `_ZN…` + vtables `_ZTV…`),
      different regalloc, slightly smaller. Also corrected the size figures: zig's
      real `.text` is **443 B** (the 647 B included default `.eh_frame`); fair code
      sizes rust ~171 ≈ gcc 174 < clang 192 < zig 443 (docs/00, docs/06).

## Not done / next steps

- [x] **Execute** the Xtensa images on qemu. The espressif qemu fork
      (`esp-develop-9.2.2-20260417`) is downloaded; the bare-metal harness
      (`experiments/qemu-run`, `scripts/run-qemu.sh`) **runs the full FFI matrix
      on `-machine sim -cpu dc233c`** and reproduces the docs/05 prediction at
      runtime: scalars + align-4 `Point` pass for all 4 languages; the align-1
      `blob_sum` by value gives `zig FAIL (got=242 want=300)` — the ABI bug, live.
      (Bring-up: XEA2 window handlers + VECBASE, `PS.INTLEVEL=15`, and a
      div-free `putdec` to dodge dc233c's missing `mul32high`.) docs/08.
      Remaining nicety: a full `-machine esp32` + ROM + flash-image run to use the
      exact esp32 core (sim can't, it resets to the unmapped 0x50000000).
- [x] **Struct-ABI boundary sweep** — done (`experiments/abi-structs/sweep.sh`).
      Found the trigger is **alignment, not size**: align-1 structs mismatch at
      every size, align-4 match at every size.
- [x] **`-mlongcalls` / call0 ABI** variant (docs/02): default is windowed
      everywhere. call0 is reachable (gcc `-mabi=call0`; LLVM by dropping the
      `windowed` feature) but is a **different, incompatible ABI** — must be
      project-wide, can't mix with windowed. `-mlongcalls` is gcc-only (clang
      ignores it) and FFI-neutral (call encoding, not ABI).
- [x] **RISC-V** ESP32-C3 — full FFI matrix built, linked **and run on
      qemu-system-riscv32** (`build-ffi.sh esp32c3`, `run-qemu.sh riscv`, docs/09).
      Overturned the "Xtensa-only" assumption: RISC-V has a **different** Zig
      struct-arg bug — small `{i32,i32}` mis-lowered to `[2 x i64]` →
      `zig point_dot FAIL (got=-2130706553)` at runtime (the large `[24]u8` is
      fine, by reference). Rust/clang/gcc correct on both arches.
- [x] **Zig⇔Rust parity** (docs/10): Rust's ESP C-ABI matches clang/gcc on both
      arches; Zig's experimental targets have a by-value struct-arg gap on each.
- [x] **Issue-tracker cross-checks** (docs/10): tested llvm-project #66 (narrow
      stack args — fixed; all toolchains agree on 4-byte slots), esp-rs/rust
      #278/#18, and closed miscompiles (#38/#41/#33 stay fixed on clang 21.1.3).
- [x] **Upstream Zig comparison** (`pip install ziglang`, docs/10): upstream Zig
      **0.16.0** has no esp32/esp32c3 CPUs (bootstrap required). Zig **0.17.0-dev**
      (Codeberg) adds an `esp32` CPU via upstream LLVM, but still not s2/s3 — only
      the fork has all Xtensa targets, like the Rust fork. The RISC-V `[2 x i64]`
      struct bug reproduces on upstream Zig → an upstream Zig frontend bug.
- [x] **Cross-language LTO** (docs/04): C↔Zig LTO inlines + constant-folds across
      the boundary on riscv when one LLVM version is used (upstream zig cc -flto).
- [x] **Bare-metal Rust+Zig mixin use-case** (docs/11,
      `experiments/baremetal-mixin/run.sh`): Rust app + Zig kernel + Zig→Rust
      callback, buffers by pointer, one no_std ELF, runs `816 OK` on **both**
      esp32c3 (riscv) and esp32 (xtensa) qemu.
- [x] **`-lc` vs C-ABI** (docs/10): `-lc` only links libc; it does not fix Zig's
      struct ABI (verified `[2 x i64]` persists with `-lc` and real musl libc).
- [x] **Mangled-symbol FFI from Zig** (docs/12, `experiments/mangled-ffi`,
      `run.sh` runs all four): (1) Zig CALLS mangled C++ `@"_Z…"` (19 OK, picks an
      overload) and Rust v0 `@"_R…"` (21 OK — needs v0+rlib+opt0 to stay global;
      staticlib/`-O`/legacy internalize it; v0 hash unstable → prefer
      `#[no_mangle]`); (2) Zig EXPORTS mangled C++ symbols that C++ links against
      (`export fn @"_Z…"`, 19 OK); (3) Zig calls **libc++** via `extern "c++"`
      **plus** `-lc++` (operator new/delete, 42 OK) — `extern "c++"` names the dep
      but Zig still requires `-lc++`; arbitrary `extern "<lib>"` → `-l<lib>`.
- [x] **Re-test & port esp-rs/rust issues across frontends** (docs/13,
      `experiments/esp-rs-issues/run.sh`): #95 enum/match FIXED (all frontends);
      #137 u128 compiles (cross-frontend: C/gcc reject `__int128` on xtensa, rust
      & zig support u128 identically); #277 PCREL_WRAPPER ICE still OPEN but NOT
      minimally reproducible (serde/espidf-specific); #161 position & #177 C
      variadics both FIXED — verified at runtime on qemu (index 1 / sum 100,
      rust == C). 4/5 fixed; #277 needs the full serde+espidf+build-std=std repro.
- [x] **All 12 OPEN esp-rs/rust issues triaged** (docs/14,
      `experiments/esp-rs-issues/open-issues.sh`): #270 force-frame-pointers spill
      **reproduces** (LLVM-xtensa regalloc); #278 narrow stack-arg store width
      compared across frontends (rust/clang narrow, gcc/zig wide, offsets agree,
      gcc-callee reads narrow); #277 espidf-only; #243 size_of SIGSEGV does NOT
      reproduce on 1.95; #275/#253/#256/#258 are ESP-IDF-gated (out of scope);
      #265/#267/#76/#89 are non-bugs (#89 "merge into rust-lang/rust?" confirms
      the fork status). Also corrected all docs: esp-rs/rust is a fork, no
      upstream Xtensa; espressif/llvm ≠ upstream LLVM (docs/00/01/07, Research §1).
- [ ] Remaining: the **espidf** std target (`xtensa-*-espidf`) — needs the
      esp-idf framework + ldproxy + `build-std=std`; required to reproduce
      #277/#275/#253/#256/#258. The only untested frontend config. Also: file the
      Zig struct-ABI gaps upstream (ziglang/zig) with the `experiments/abi-structs`
      repro.
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
