# HANDOFF

Status of the cross-language Xtensa FFI study. Snapshot: initial research pass
complete; all claims in `Research.md`/`docs/` are backed by reproduced tool
output.

## Done

- [x] Pinned + scripted setup of all **five** toolchains (`scripts/setup.sh`).
      Versions confirmed: clang/LLVM 21.1.3, rustc 1.95-nightly/LLVM 21.1.3,
      **zig 0.17.0-xtensa / bundled clang/LLVM 22.1.4** (canonical `$ZIG`; the
      legacy 0.16.0/LLVM 21.1.0 lane `$ZIG_016` is kept for the docs/05
      struct-bug reproducer), gcc 15.2.0, **LDC 1.42.0 on espressif LLVM
      22.1.4** (D; canonical fork build — 2026-05-30 maintainer re-upload
      bumped both the release tag and the bundled LLVM, AND dropped the
      universal byval/sret aggregate lowering; docs/05 §"LDC 1.42 status",
      docs/23). The upstream LLVM-22 LDC (`$LDC2_UPSTREAM`, LDC 1.42-git on
      LLVM 22.1.2) stays for the side-by-side comparison + as the
      regression-tracker baseline for the historical byval/sret bug.
- [x] Confirmed the shared backend: identical CPU feature sets and identical
      `target datalayout` across clang/rust/zig (docs 02, 04).
- [x] FFI matrix (`experiments/ffi-matrix`): one C-ABI contract, 5 implementations
      (c/cpp/rust/zig/d), 1 driver.
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
      links; clang↔zig LTO blocked by the LLVM-21 vs LLVM-22 cluster split
      (zig 0.17 = 22.1.4 bitcode rejected by esp-clang's 21.1.3 `ld.lld`; doc 04).
- [x] Binary/size/mangling comparison (doc 06): real `.text` rust 171 ≈ gcc 201
      < clang 219 (C) / 204 (C++) < zig 375 (down from 715 on 0.16) < D 489
      for the 9-fn lib (numbers
      shifted after the docs/23 LDC swap brought back clang-class compact
      forms in the LDC arm; `llvm-size -A`, current as of doc 06).

- [x] **Address spaces** (docs/18, `experiments/addrspace/run.sh`): the Xtensa
      backend is single-flat-address-space (datalayout `p:32:32` only), so
      `addrspace(N)` is annotation-only/no-op. clang accepts numbered
      `address_space(N)` (→ IR), **Zig validates per-target** (only `.generic`;
      `.flash` etc. rejected), gcc ignores the numbered attr, Rust has none. ESP
      regions (IRAM/DRAM/flash/RTC) are placed via linker **sections** —
      `section`/`linksection`/`link_section`/`@section` → `.iram1.text` — at
      parity for five of six toolchains; TinyGo's `//go:section` is silently
      ignored in v0.41.1 (docs/18).
- [x] **Rust ⇄ Zig frontend interop** (docs/17, `experiments/rust-zig/run.sh`):
      the two non-C LLVM frontends agree on **every scalar ABI incl. C-inexpressible
      `u128`/`f128`/`f16`** (Rust uses byval for the 2nd 16-byte arg, Zig direct —
      backend reconciles; runtime-verified Rust→Zig u128 carry on qemu). The
      historical clash was **by-value struct arguments** on Zig 0.16 (an
      *upstream* Zig gap per #5467 — **CLOSED 2026-05-06, landed in 0.17.0**),
      now closed on the canonical `$ZIG` (0.17, LLVM 22.1.4). qemu `zig_blob_sum`
      reads `ok (300)` on xtensa and qemu `zig_point_dot` reads `ok (11)` on
      riscv; the `abi-structs` sweep on every Xtensa core shows REGISTERS in
      every Zig row (was STACK on align-1 byte arrays). `ZIG=$ZIG_016
      ./scripts/build-ffi.sh esp32` reproduces the historical break. See
      docs/05 §"Zig 0.17 status".
      **Nullable pointers interop** (`Option<&T>`/`Option<NonNull>`/`Option<fn>`
      ↔ `?*T`/`?*fn` = single `ptr`, FFI-safe, runtime-verified). **Atomics**
      match (native `s32c1i`). Object FFI links; **cross-language LTO** fails
      across the LLVM-21/LLVM-22 cluster split (21.1.3 rust vs 22.1.4 zig
      bitcode; docs/04 §"Two LLVM clusters").
- [x] **D / LDC as a 5th frontend** (docs/19, `experiments/dlang/run.sh`; D added
      to the FFI matrix + qemu harness). The canonical LDC is **LDC 1.42.0 on
      espressif/llvm-project LLVM 22.1.4** (kassane/esp-idf-dlang, 2026-05-30
      maintainer re-upload; docs/23) — same backend family as clang/rust at
      the espressif fork, but at a different LLVM point release. `-betterC` =
      freestanding. **Headline (historical):** the previous LDC 1.42-git on
      LLVM 21.1.3 marked **every** by-value aggregate `byval`/`sret` (indirect)
      and deferred to the backend, so it diverged from the register-based
      Xtensa C ABI more broadly than Zig — `point_dot` (align-4) AND `blob_sum`
      (align-1) both FAILED on Xtensa; on RISC-V the small struct even
      *faulted* while the large one PASSED. **Headline (canonical, post-
      2026-05-30):** the LDC 1.42.0 frontend drops the universal byval/sret
      lowering and emits `[N x i32]` like clang. `d_point_dot` disasm is
      byte-identical to `c_point_dot` (`mull/mull/add.n/retw.n`); `d_make_point`
      is just `entry/retw.n`. **qemu xtensa drops from 2 D failures to 0**.
      The legacy break is preserved on `$LDC2_UPSTREAM` (LDC on upstream LLVM
      22.1.2, no aggregate-flattening fix) for the regression tracker
      (`experiments/ldc-fork-comparison/run.sh`). The bug was **frontend-side**
      — confirmed across both legacy LDC arms (fork-21.1.3 + upstream-22.1.2
      produced byte-identical broken IR). Scalars at parity; links into the
      one ELF with the four FFI-matrix peers (0 undef). Rich C/C++ FFI:
      byte-identical Itanium mangling (`extern(C)`/`extern(C++[,"ns"])`/ref),
      `-HC` C++-header gen with a verified C++→D round-trip. **Cross-language
      LTO**: `clang ↔ rust` still works (LLVM-21 cluster), `clang ↔ D` LTO
      via esp-clang's 21.1.3 lld now **FAILS** (`Invalid record`) since D
      moved to LLVM-22; `D ↔ zig` LTO is newly reachable via `$LDC_LLVM_DIR`'s
      lld (docs/04 §"Two LLVM clusters"). Known issues: ldc #5091 (ICE
      EH+opt); ldc #4919 (cpu-feature defaults — fixed for esp32-s2/s3 on
      the fork). **`$LLD`** (= `$ZIG ld.lld`, LLD 22.1.4, PR #24) is the
      canonical linker for every `.sh` in the repo; gotcha #4 host-LLVM-18
      risk is mitigated.
- [x] **LDC espressif-fork comparison** (docs/23, `experiments/ldc-fork-comparison`).
      Side-by-side both LDCs on the same `lib_d.d` for esp32. The fork drops 5
      workarounds (literal-pool re-assembly, `.cfi_*` strip, `-output-s` step,
      `-mattr` fallback for s2/s3, LLVM-22 binutils dependency for canonical IR
      work), gives `mov.n`/`s32i.n`/`l32i.n` compact codegen byte-identical to
      clang, and makes the datalayout match the trio. **The byval/sret bug
      survived the original LLVM-21 ↔ LLVM-22 swap** (both legacy LDC arms
      produced byte-identical broken IR) — that's what proved it was a
      frontend issue, not a backend one. The **2026-05-30 LDC 1.42.0
      maintainer re-upload** carried a new aggregate-flattening frontend
      pass that closes the bug end-to-end (docs/05 §"LDC 1.42 status").
- [x] **D/LDC exclusive features + `@safe` parity with Rust** (docs/20,
      `experiments/dlang/safety.sh`). LDC-only, Xtensa-verified: `@fastmath`
      (`fmul fast`), `@section`→`.iram1.text`, `@weak`, inline LLVM IR `__ir!`→real
      `add`; plus `ldc.attributes`/`pragma(LDC_*)`/`--fsanitize`. **Extended
      attribute/pragma sweep** (`experiments/dlang/ldc-attrs.sh`, docs/20
      §1.1/1.2): `@assumeUsed`/`@cold`/`@optStrategy(none|optsize|minsize)`/
      `@naked`/`@restrict`/`@llvmAttr` + `pragma(mangle/inline(true|false)/
      LDC_intrinsic/LDC_extern_weak)` all IR-verified on the canonical 21.1.3
      fork. **`@assumeUsed` cross-frontend parity finding**: LDC + Rust
      `#[used]` both emit the **strong** `@llvm.used` marker (survives
      `--gc-sections`); clang's classic `__attribute__((used))` emits the
      *weak* `@llvm.compiler.used` — only C23's `[[gnu::retain]]` yields the
      strong form on clang 13+. **`import("file")` parity matrix**: D
      `import("file")` / Zig `@embedFile` / Rust `include_bytes!` /
      clang C23 `#embed` / TinyGo `//go:embed` all embed bytes into the
      `.rodata` family of sections at compile time (TinyGo on Xtensa requires
      the embed variable to be reached by a non-DCE-d code path). Two evolution
      axes: `-preview=<name>` (à la carte; `=all`; safety ones dip1000/safer/
      systemVariables/nosharedaccess) and **`--edition=` (DIP1052, valid 2023–2025,
      per-module) — exactly Rust's edition model**; editions don't flip default
      `@safe` here, `-preview=safer` does. **Default bundle now applied
      repo-wide**: `$LDC_PE = "-preview=all --edition=2025"` is exported by
      `env.sh` and threaded through every non-probe `$LDC2` invocation
      (build-ffi.sh / analyze.sh / abi-structs/sweep.sh / addrspace /
      atomics-orders / call0-abi / dlang/{ldc-attrs,run,tmpffi,safety §e} /
      dwarf-parity / esp-rs-issues / ldc-fork-comparison / llvm-ir-mix /
      mangled-ffi / rust-zig / simd). The one source-level change needed was
      `@system` on raw-pointer-indexing kernels (`experiments/simd/vadd.d`),
      which is the honest C-ABI annotation anyway; everything else compiles
      and runs identically (xtensa qemu still 2 failures = D only; riscv
      0 failures; abi-structs/atomics/simd/dwarf/llvm-ir-mix/mangled-ffi all
      unchanged). docs/20 §2.0 documents the bundle. **`@safe` ⇄ Rust battery**
      (real errors
      both sides): D `@safe` rejects 7/8 unsafe ops; the one gap is same-size
      pointer reinterpret (Rust needs `unsafe`). DIP1000 escape ≈ but ⊂ Rust's
      borrow checker (escape only, no aliasing; `@trusted` is whole-function;
      `scope` unchecked inside `@trusted`). **Key FFI tie-in:** DIP1028 "make @safe
      default" was *rejected* because `extern(C)`/`extern(C++)` prototypes can't be
      verified `@safe` (safety isn't mangled) — so D's FFI boundary must be hand
      `@trusted`. D `@system`-by-default vs Rust safe-by-default.
- [x] **Extended: `@mustuse`, `@live`, and C++26 third leg** (docs/20 §7–§9;
      `safety.sh` §f-§h). Three-way **must-use parity**: D `@mustuse` (DIP1038)
      is a *compile-error* but TYPE-only; Rust `#[must_use]` and C++17
      `[[nodiscard]]` are warnings on both fns and types. **`@live` ownership
      checker** (no standalone DIP; DIP1021 is the formal piece) catches UAF,
      double-free, dangling AND **leak** — the last is what Rust's borrow checker
      famously *doesn't* catch (`std::mem::forget` is safe). Empirical caveat:
      spec says `@live` activates with the attribute alone, but on LDC 1.42 the
      checker is silent without `-preview=dip1021` (or `=all`). **C++26 reality
      on zig c++ / clang 21**: of the safety paper trail (Contracts P2900,
      Reflection P2996, Pattern Matching P2688, Profiles P3081 — all C++26-frozen
      at Sofia 2025 except Profiles/PM), **none are in clang 21**; only
      `[[nodiscard]]` carries through. `-fexperimental-library` gates `<execution>`
      / tzdb / `<syncstream>` / libc++ hardening, NOT `<expected>`/`<print>`/
      `<flat_map>` (those ship unconditionally). **GCC arm probed too**
      (`safety.sh` §i; esp-g++ 15.2.0 / libstdc++ 15, `-ffreestanding`
      xtensa-esp-elf): same verdict — P2686R5 / Contracts P2900 / Reflection
      P2996 / PM P2688 all rejected. libstdc++ 15 ships `<expected>` /
      `<ranges>` / `<stdfloat>` in the freestanding subset; the C++23 hosted
      headers (`<print>` / `<format>` / `<flat_map>` / `<execution>` /
      `<generator>` / `<stacktrace>`) are gated by `bits/requires_hosted.h`;
      and the C++26 frontier (`<simd>` / `<linalg>` / `<contracts>` / `<hive>`
      / `<mdspan>`) is not in libstdc++ 15 at all — same gap libc++ 22 has.
      The two C++ producers in the matrix (esp-clang 21.1.3 + esp-g++ 15.2.0)
      agree on every C++26-frontier feature. Reviewed DIPs 1000–1052 (DIP1050
      is skipped); the 5 Accepted-and-relevant ones plus the rejected DIP1028 are
      summarized in docs/20 §6.
- [x] **Embedded TMP-FFI matrix on Xtensa across ALL 5 toolchains** (docs/21,
      `experiments/dlang/tmpffi.sh`). Sample: `shims::Gpio<int Pin>` — the embedded
      "shim" template (each pin instantiation is its own symbol with its own static
      state, no vtable / no runtime branch). C++ provider (esp-clang OR gcc, *both*
      emit byte-identical Itanium symbols); D consumer via
      `extern(C++,"shims") extern(C++,class) struct Gpio(int Pin)` with the
      `pragma(mangle, "_ZN…")` escape hatch for the SFINAE/partial-spec/defaults D's
      TMP can't express; Rust consumer via `#[link_name="_ZN…"]`; Zig consumer via
      `extern fn @"_ZN…"`. ld.lld + the xtensa.ld script links every FFI-matrix language into one
      esp32 ELF, **0 undefined**. LLVM-22 binutils (`ldc-developers/llvm` ≠
      `ldc-developers/ldc` tarball) `llvm-link`s clang+D+Rust IRs into a single
      11-define module. Empirical C++26 status on esp-clang 21.1.3: even P2686R5
      constexpr structured bindings (the *only* clang-22 mainline C++26 addition)
      is rejected — the Sofia-2025 frontier (Contracts/Reflection/PM/Profiles) is
      not in any clang we have, and re-probing the GCC arm (**esp-g++ 15.2.0 /
      libstdc++ 15**) confirms identical-shaped rejections (docs/21 §5).
      Baremetal-D's `@safe`+`@live` already covers the static-safety story
      (docs/20 §8).
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
      clang/LLVM family — esp-clang is 21.1.3, zig 0.17 canonical is 22.1.4 but
      shares the same espressif Xtensa backend code; near-identical Xtensa code,
      differ only in driver defaults — zig emits `.eh_frame`/ubsan/libc++);
      `esp-gcc` has full ABI parity (windowed C ABI; byte-identical Itanium C++
      mangling `_ZN…` + vtables `_ZTV…`), different regalloc, slightly smaller.
      Current `.text` ordering on the canonical lane (canonical zig 0.17 closes
      the 0.16 struct-byval gap, so its size dropped from 715 B → 375 B):
      **rust 171 ≈ gcc 201 < clang-C++ 204 < clang-C 219 < zig 375 < D 489**
      (docs/00, docs/06). The legacy `$ZIG_016` lane reproduces the old
      715 B figure for the byte-by-byte stack marshalling.

## Known outages

- **LDC mirror RESTORED on 2026-05-30 — different tarball.** The mirror is
  fetchable again. The maintainer republished
  `ldc2-v1.42.0-espressif-linux-musl-static.tar.xz` as **LDC 1.42.0 on
  LLVM 22.1.4** (was LDC 1.42-git on LLVM 21.1.3), sha256
  `c2cd9f5bdd1caa80233cebc7b3d61243366b1b1a8780af019d0dbfb80becb548` (80 MB;
  old was `0e99b893…` 50 MB). `scripts/setup.sh` is bumped to the new sha.
  Major implications: (1) the universal D `byval`/`sret` aggregate ABI bug
  (docs/05/19/23) is **closed** on the new canonical — qemu xtensa drops
  from 2 D failures to 0; (2) the canonical LDC moved from the LLVM-21
  cluster (was with clang/rust on 21.1.3) into the LLVM-22 cluster (now
  with zig 0.17 + upstream LDC + LDC_LLVM_DIR binutils), so clang↔D LTO
  via esp-clang's 21.1.3 lld now fails — use `$LDC_LLVM_DIR`'s lld for
  cross-language LTO on the 22.x side. The fork still has the espressif
  Xtensa MC patches, so the literal-pool workaround is still dropped
  (`ldc2 -c -> ld.lld` works direct). The old 50 MB tarball is preserved
  at `$DL/ldc-esp-OLD.tar.xz` and the old install at
  `$TC/ldc-xtensa-old/` for anyone who needs to reproduce the 21.1.3
  behaviour. **(Previous outage note, 2026-05-28 → 2026-05-30, kept for
  the record):** the
  auto-fallback in `env.sh` is the operational path.

## Not done / next steps

- [x] **Execute** the Xtensa images on qemu. The espressif qemu fork
      (`esp-develop-9.2.2-20260417`) is downloaded; the bare-metal harness
      (`experiments/qemu-run`, `scripts/run-qemu.sh`) **runs the full FFI matrix
      on `-machine sim -cpu dc233c`** and reproduces the docs/05 prediction at
      runtime: scalars pass for all 5 languages; the align-1 `blob_sum` by value
      gives `zig FAIL` (and `d FAIL` — D also misses the align-4 `point_dot`,
      docs/19) — the ABI bugs, live; by-pointer passes for all.
      (Bring-up: XEA2 window handlers + VECBASE, `PS.INTLEVEL=15`, and a
      div-free `putdec` to dodge dc233c's missing `mul32high`.) docs/08.
      Remaining nicety: a full `-machine esp32` + ROM + flash-image run to use the
      exact esp32 core (sim can't, it resets to the unmapped 0x50000000).
- [x] **Struct-ABI boundary sweep** — done (`experiments/abi-structs/sweep.sh`).
      Found the trigger is **alignment, not size**: align-1 structs mismatch at
      every size, align-4 match at every size. Extended with **C-style
      bitfield** rows (D supports native `extern(C) struct{uint a:4;...}`):
      clang flattens to scalar backing (i16/i32/[1 x i64]); Zig matches when
      `packed struct(uN)` has explicit backing; **legacy** D (LDC 1.42-git
      on LLVM 21.1.3, preserved on `$LDC2_UPSTREAM`) wrapped every
      bitfield as `byval(%s.T)` — universal-aggregate bug applied to
      bitfields too; **canonical** LDC 1.42.0 (LLVM 22.1.4) flattens
      bitfields to scalar backing like clang, so every D row classifies
      REGISTERS on the canonical lane (docs/05/19, 2026-05-30 re-upload).
- [x] **`-mlongcalls` / call0 ABI** variant (docs/02): default is windowed
      everywhere. call0 is reachable (gcc `-mabi=call0`; LLVM by dropping the
      `windowed` feature) but is a **different, incompatible ABI** — must be
      project-wide, can't mix with windowed. `-mlongcalls` is gcc-only (clang
      ignores it) and FFI-neutral (call encoding, not ABI). **Mechanized as
      `experiments/call0-abi/run.sh`** — flips every frontend
      (clang `-Xclang -target-feature -Xclang -windowed`, gcc `-mabi=call0`,
      **zig `-mcpu=<core>-windowed`**, LDC `-mattr=-windowed`,
      rust `-C target-feature=-windowed`) and confirms identical
      `entry+retw.n` → `ret.n` prologue swap across esp32 / esp32s2 / esp32s3.
- [x] **RISC-V** ESP32-C3 — full FFI matrix built, linked **and run on
      qemu-system-riscv32** (`build-ffi.sh esp32c3`, `run-qemu.sh riscv`, docs/09).
      Overturned the "Xtensa-only" assumption: RISC-V has a **different** Zig
      struct-arg bug — small `{i32,i32}` mis-lowered to `[2 x i64]` →
      `zig point_dot FAIL (got=-2130706553)` at runtime (the large `[24]u8` is
      fine, by reference). Rust/clang/gcc correct on both arches.
- [x] **C-ABI completeness per frontend** (docs/10): Rust's ESP C-ABI matches clang/gcc on both
      arches; Zig's experimental targets have a by-value struct-arg gap on each.
- [x] **Issue-tracker cross-checks** (docs/10): tested llvm-project #66 (narrow
      stack args — fixed; all toolchains agree on 4-byte slots), esp-rs/rust
      #278/#18, and closed miscompiles (#38/#41/#33 stay fixed on clang 21.1.3).
- [x] **Upstream Zig comparison** (`pip install ziglang`, docs/10): upstream Zig
      **0.17.0** adds an `esp32` CPU via upstream LLVM (per #5467) but still
      not s2/s3 — only the bootstrap fork has all Xtensa targets, like the Rust
      fork. The historical `$ZIG_016` lane (upstream 0.16.0) had no esp32 CPU
      upstream at all. The RISC-V `[2 x i64]` struct-arg bug reproduced on
      upstream Zig 0.16 → an upstream Zig frontend bug, fixed in 0.17.
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
- [x] **Version-matched LLVM binutils for true module-merge** (docs/04,
      `experiments/llvm-ir-mix/run.sh`): added the **LLVM 22.1.2** tools from
      `ldc-developers/llvm-project` `ldc-v22.1.2` (the LLVM LDC is built on;
      `$LDC_LLVM_DIR`, `setup.sh LLVM22=1`, a 405 MB `.tar.zst` → needs `zstd`).
      These supply the `llvm-link`/`opt`/`llvm-dis`/`llvm-as` esp-clang doesn't
      ship, and being LLVM-22 they read all the post-18 IR the host LLVM-18 tools
      reject. **`llvm-link` now merges every LLVM frontend into one module** (42
      defines), `opt -O2` inlines across the merge (D→D `x+2`), and `llvm-dis`
      reads LDC's LLVM-22 bitcode (producer `ldc version 1.42.0-git-c8305d0`).
      Caveats: cross-frontend `opt` inlining is gated by matching target-features
      (the `ld.lld` LTO path inlines clang↔D regardless), and esp32 *codegen* of
      the merged 22-IR still needs the espressif backend (upstream LLVM-22 has no
      `esp32` CPU). The "D's datalayout differs" caveat went away when D moved to
      the espressif-21 fork (docs/23 §(e)) — all 4 LLVM frontends now share the
      identical Xtensa datalayout, no llvm-link warning.
- [x] **Full parity audit + DWARF/codegen reverse-engineering** (docs/22,
      `experiments/dwarf-parity/run.sh`). Re-ran every canonical claim:
      `build-ffi.sh all` (host PASS, 9 Xtensa ELFs + riscv all 0 undef),
      `run-qemu.sh xtensa` (3 fails: d point_dot, zig+d blob_sum — docs/08/19),
      `run-qemu.sh riscv` (1 fail: zig point_dot — docs/09). New: same trivial
      `int add_i32(int,int)` compiled by all 5 toolchains with -g for esp32 ->
      **DWARF section size + version comparison** (clang/gcc=DWARFv5, rust/zig/
      LDC=DWARFv4; Zig's `.debug_str`=12 KB for one function), **subprogram DIE**
      inspection (gcc resolves names pre-link; LLVM frontends need link-time
      `.debug_str_offsets` relocations; v4 pre-link strings show producer string
      instead of `add_i32` -- a tooling subtlety to know when RE'ing `.o`
      archives), **frame info** (clang/gcc/rust use `.debug_frame`; **zig/LDC
      emit `.eh_frame`** even on baremetal — wasted bytes without an unwinder),
      and **disassembled add_i32** across all 5 (rust release: 6 B; clang/gcc:
      14 B; zig: 12 B; **LDC: 17 B byte-identical to clang** on the canonical
      espressif-fork LDC — the 19 B / 35 %-bigger figure was on the upstream-22
      LDC, preserved in docs/23 §(g)). Plus consolidated capability / known-vulns
      table per toolchain (§7) and the espressif baremetal advantages roll-up
      (§8).
- [x] **D coverage extended into the silent experiments** (companion to docs/23).
      D rows added to: `simd` (LDC `__asm` → 4 `EE.*` instructions, full parity),
      `abi-structs` (D classifies REGISTERS via byval-passthrough), `addrspace`
      (no addrspace syntax; `@section .iram1.text` works), `rust-zig` (u64/
      atomics/opt-ptr match; u128 diverges via `core.int128.Cent` — `cent`/
      `ucent` keywords formally obsoleted), `mangled-ffi` (4 ABI paths: D-native
      `_D…`, Itanium `_Z…` via extern(C++), Rust v0 consumption via
      pragma(mangle), Zig consumption via extern(C++,"ns")), `esp-rs-issues`
      (#137 `cent` rejected, #270 no ICE on forced FP, #278 wide stack-arg
      stores — D joins gcc/zig). docs/00-23 final.
- [x] **Zero-cost abstraction parity D × C++ × Rust on esp32 -Os** (docs/25,
      `experiments/zero-cost/run.sh`). Stroustrup's "what you do use, you
      couldn't hand code any better" probed against the three monomorphizing
      LLVM frontends. Monomorphized generics / lambdas / static dispatch are
      byte-identical to the C hand-loop modulo a frame-pointer policy (clang
      keeps `mov.n a7, a1` at -Os, LDC + rustc don't). Dynamic dispatch (C++
      virtual / Rust `dyn Trait`) is NOT zero-cost: +2-3 insns per call (extra
      `l32i` for vtable read). D class in -betterC needs hand-rolled malloc +
      placement; identical machine code to C++ `new T(args)` and Rust
      `Box::new` (10-11 insns / 24-26 B) — no language overhead, just no GC
      to emit the malloc+emplace for you. D `struct` (4 insns / 9 B) is the
      canonical embedded answer.
- [x] **TMP feature surface parity D × C++ × Rust** (docs/26,
      `experiments/tmp-parity/run.sh`). Twelve template-metaprogramming
      capabilities probed × 3 languages: parameter forms (type / NTTP /
      template-template / string NTTP), constraints (concepts / SFINAE /
      trait bounds), full + partial specialization, compile-time branching
      (`static if` / `if constexpr` / trait dispatch), token-level identifier
      synthesis (D `mixin` / C++ X-macros / Rust nightly), CTFE, in-language
      reflection (D `__traits` / C++ P2996 future / Rust proc-macro-only),
      variadic. D supports 11/12 in-language with no host build step; C++ 10
      (no in-language reflection, no identifier synthesis); stable Rust 6
      (closes ~3 on nightly; the rest need proc-macros at 50-100 MB per
      consumer). **Plus** the docs/26 §h disentanglement of D's three
      `extern(C++)` FFI forms: `class` = D PRODUCES vtable; `extern(C++,ns)
      class struct` = D CONSUMES (Itanium-mangled call sites only, body
      supplied by C++ — the docs/21 shim pattern); plain `struct` = POD
      layout in either direction. `llvm-nm` symbol-role table makes the
      distinction concrete. The PR-27 zero-cost `extern(C++) class Counter`
      was form (1) — DIFFERENT from form (2) used by the shim matrix.
- [x] **RISC-V parity for zero-cost + TMP + esp32p4 vendor SIMD** (folded
      back into docs/09 / docs/16 / docs/25 / docs/26 — no docs/27).
      `experiments/{zero-cost,tmp-parity,simd}/run.sh` parameterized for
      esp32c3 (rv32imc) and esp32p4 (rv32imafc); every monomorphization /
      inlining / static-vs-dynamic / heap / TMP conclusion holds ISA-
      portably (riscv §b apply = 2 insn / 4 B beats xtensa's 3-4 / 8-10 B
      because no register windows; riscv §c dynamic dispatch costs +14 insn /
      +24 B vs xtensa's +6 / +14). CTFE `fact(5)→120` folds to `li a0,
      0x78 ; ret` on riscv (2 insn / 6 B) vs xtensa's `entry ; movi a2,
      120 ; retw.n` (3 insn / 9 B), byte-identical across cpp/d/rs.
      **esp32p4 vendor PIE/ESPV SIMD added to experiments/simd/run.sh §7**.
      esp-clang 21.1.3 exposes three vendor extensions: `+xespv` (ESPV 2.2,
      esp32p4 default — sparse public docs), `+xespv1v` (ESPV 2.1,
      esp32p4eco4 only — 412 documented mnemonics), `+xesploop` (zero-
      overhead loops). Mnemonic family `esp.*` (lowercase-dotted analog of
      xtensa `EE.*`), 128-bit q0..q? + qacc/xacc regs. **Cross-frontend
      byte-identical inline-asm encodings across clang, zig, LDC, rustc**
      (all four share libLLVM's RISC-V assembler). No intrinsic headers
      ship — `riscv_vector.h` requires standard V which esp32p4 doesn't
      enable. ESPV 2.1 ↔ 2.2 are wire-incompatible opcode tables — use
      `-mcpu=esp32p4eco4` for the documented mnemonic surface. esp32c3
      has no vendor SIMD (rejected the same way esp32 LX6 rejects EE.*).
      All three LLVM C-family frontends (esp-clang, LDC's bundled LLVM
      22.1.4, Zig) accept the esp32* CPU names natively for riscv; rustc
      needs `--target riscv32imafc-unknown-none-elf -C target-cpu=esp32p4eco4`.
      Toolchain matrix in docs/09 §"Four-frontend toolchain matrix";
      zero-cost RISC-V variant in docs/25; TMP RISC-V variant in docs/26;
      esp32p4 SIMD section in docs/16.

## How to resume

```bash
./scripts/setup.sh && source scripts/env.sh
./scripts/build-ffi.sh all && ./scripts/analyze.sh esp32
```

Everything regenerates into `build/` (gitignored). See `CLAUDE.md` for the
solved gotchas before changing build commands.
