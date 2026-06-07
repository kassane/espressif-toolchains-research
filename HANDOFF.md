# HANDOFF

Status of the cross-language Xtensa FFI study. Snapshot: initial research pass
complete; all claims in `Research.md`/`docs/` are backed by reproduced tool
output.

## Done

- [x] Pinned + scripted setup of all **five** toolchains (`scripts/setup.sh`).
      Full version table + env-var semantics in CLAUDE.md; canonical lanes:
      esp-clang 21.1.3, rustc 1.95-nightly (LLVM 21.1.3), `$ZIG` 0.17.0-xtensa
      (LLVM 22.1.4), `$LDC2` 1.42.0 (espressif LLVM 22.1.4), gcc 15.2.0.
      Legacy lanes `$ZIG_016` + `$LDC2_UPSTREAM` kept for the struct-ABI bug
      reproducers (docs/05 §"Zig 0.17 status" + §"LDC 1.42 status").
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
      Zig 0.16 deferred to the backend (closed by 0.17 — doc 04, doc 05).
- [x] **Headline finding** — by-value struct **arguments** are ABI-incompatible
      with Zig on Xtensa for **under-aligned** (`align(1)`) structs (alignment-,
      not size-driven; proven at the call site). NOTE: also broken differently on
      RISC-V (small `{i32,i32}` → `[2 x i64]`) — see the corrected entry below;
      not Xtensa-only. (doc 05/09, `experiments/abi-structs/sweep.sh`).
- [x] IR mixing: `llc` consumes all frontends; clang↔rust cross-language **LTO**
      links; clang↔zig LTO blocked by the LLVM-21 vs LLVM-22 cluster split
      (zig 0.17 = 22.1.4 bitcode rejected by esp-clang's 21.1.3 `ld.lld`; doc 04).
- [x] Binary/size/mangling comparison (doc 06): real `.text` rust 171 ≈ gcc 201
      < clang 219 (C) / 204 (C++) < zig 375 (down from 715 on 0.16) < D 516
      for the 9-fn lib (canonical LDC 1.42.0 post-fix; numbers `llvm-size -A`,
      current as of doc 06).

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
- [x] **D / LDC as a 5th frontend** (docs/19, `experiments/dlang/run.sh`; D
      added to the FFI matrix + qemu harness). Canonical LDC 1.42.0 on
      espressif LLVM 22.1.4 (2026-05-30 maintainer re-upload, docs/23). The
      historical universal `byval`/`sret` aggregate lowering closed at the
      same time — `d_point_dot` now byte-identical to `c_point_dot`, qemu
      xtensa drops to 0 D failures; legacy break reproduces on
      `$LDC2_UPSTREAM` (docs/05 §"LDC 1.42 status"). Scalars at parity;
      links into the one ELF with the four FFI-matrix peers (0 undef). Rich
      C/C++ FFI: byte-identical Itanium mangling
      (`extern(C)`/`extern(C++[,"ns"])`/ref), `-HC` C++-header gen with a
      verified C++→D round-trip. Cross-language LTO follows the
      LLVM-21/22 cluster split (docs/04 §"Two LLVM clusters"): clang↔rust
      works, clang↔D fails since D moved to 22.x, D↔zig newly reachable.
      Known issues: ldc #5091 (ICE EH+opt); ldc #4919 (cpu-feature
      defaults — fixed for esp32-s2/s3 on the fork).
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
      **rust 171 ≈ gcc 201 < clang-C++ 204 < clang-C 219 < zig 375 < D 516**
      (docs/00, docs/06; canonical LDC 1.42.0 post-fix). The legacy `$ZIG_016`
      lane reproduces the old 715 B figure for the byte-by-byte stack marshalling.

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

## Lock-file motivation (the cautionary case this repo lived)

The `toolchains.lock` file at repo root pins **sha256 + size + url + resolved
tag** for every artifact `scripts/setup.sh` downloads. The motivation isn't
hypothetical:

On **2026-05-30** the `kassane/esp-idf-dlang` maintainer republished the
`xtensa-toolchain` GitHub release. Same repo, same release tag, **different
bytes**: the LDC version bumped (1.42-git → 1.42.0) AND its bundled LLVM
bumped (21.1.3 → 22.1.4). The 21→22 LLVM bump silently moved the canonical
LDC from the **LLVM-21 cluster** (where it could LTO with esp-clang + rust)
to the **LLVM-22 cluster** (where it now LTOs with zig 0.17 + `$LDC2_UPSTREAM`
+ `$LDC_LLVM_DIR` instead — see CLAUDE.md gotcha #4 + docs/04 §"Two LLVM
clusters"). The artifact also acquired the `[N x i32]` aggregate-flattening
frontend fix, closing the universal byval/sret bug docs/05 + docs/19 +
docs/23 had documented.

**Tag-pinning cannot catch this kind of drift.** The release tag was stable
across the bump — only the bytes changed. Hash-pinning catches it
immediately: if `setup.sh` ever downloads bytes whose sha256 doesn't match
`toolchains.lock`, it aborts loudly with the actual hash + a note pointing
the user at the bump procedure. The same protection covers the other six
artifacts (espressif/llvm-project, esp-rs/rust-build, zig-espressif-bootstrap
canonical + legacy, espressif/crosstool-NG, ldc-developers/ldc CI,
ldc-developers/llvm-project binutils, tinygo, espressif/qemu xtensa +
riscv32).

**Deliberate re-pin procedure** when a fork legitimately bumps:

```
1. rm $DL/<name>                       # drop the cached artifact
2. ./scripts/setup.sh                  # re-fetches; aborts on mismatch
3. sha256sum $DL/<name>                # compute the new hash
4. Edit toolchains.lock; commit:
   "toolchains.lock: <name> bumped (<old-version> → <new-version>)"
```

The commit IS the audit log entry — a real, attributable engineering
event. The history of `toolchains.lock` is the history of toolchain
drift in this repo.

## Load-bearing green (anti false-green discipline)

`experiments-audit.md` catalogues every experiment by claim, verification
mechanism, and whether a mechanically-runnable mutation flips the green to
red. Rows are classified Strong / Medium / Weak; the four Weak rows
(atomics-orders, zero-cost, compiler-parity, dlang tmpffi) are deliberate
WIP, **not** silent passes — the audit calls them out so the reader knows
where the green is decorative vs. mechanical.

`experiments/qemu-run/negative-controls.sh` is the wrapper that drives the
guarantee:

```
experiments/qemu-run/negative-controls.sh canonical xtensa  # 0 failures
experiments/qemu-run/negative-controls.sh canonical riscv   # 0 failures
experiments/qemu-run/negative-controls.sh zig016    xtensa  # zig blob_sum FAIL (docs/05)
experiments/qemu-run/negative-controls.sh zig016    riscv   # zig point_dot FAIL (docs/09)
experiments/qemu-run/negative-controls.sh ldc_upstream xtensa  # byval/sret evidence
experiments/qemu-run/negative-controls.sh all
```

If the legacy lane stops failing, the canonical green has lost its
negative control — investigate before silently accepting. The historical
`$ZIG_016` / `$LDC2_UPSTREAM` breaks are the load-bearing mutation source
for the canonical lane's success claim; without them, "0 failures on
qemu" is just unverified text.

## How the gaps closed (taxonomy)

`docs/00-support-matrix.md` §"How the gaps closed (taxonomy)" classifies
each tracked historical FFI/ABI break by the mechanism that closed it:

- **callconv/frontend-patch** — Zig 0.16 align-1 + small `{i32,i32}`
  (Zig #5467, fixed in 0.17); LDC universal byval/sret (LDC 1.42.0
  aggregate-flattening frontend pass, 2026-05-30 maintainer re-upload).
- **fork-patch** — espressif-fork LDC's Xtensa MC layer (drops the
  `-output-s` re-assembly workaround); espressif-fork LDC's s2/s3 cpu
  defaults (closes ldc #4919).
- **runtime-rebuild** — Rust no-prebuilt-core, closed by `-Z build-std=
  core` + `rust-src` symlinked into the sysroot (CLAUDE.md gotcha #2).
- **pure-composition** — LLVM-22 binutils for canonical LDC IR analysis
  via `$LDC_LLVM_DIR` (opt-in `LLVM22=1`; parallel binutils tarball,
  no rebuild).
- **open** — TinyGo byte-array struct arg (out-of-FFI-matrix, docs/24 §e).

Each row links back to the experiment + doc that produced its evidence.
New gaps reported but not yet reproduced land with an explicit
`**unverified**` marker until evidence is in tree.

## Not done / next steps

- [x] **Execute** the Xtensa images on qemu. The espressif qemu fork
      (`esp-develop-9.2.2-20260417`) is downloaded; the bare-metal harness
      (`experiments/qemu-run`, `scripts/run-qemu.sh`) **runs the full FFI matrix
      on `-machine sim -cpu dc233c`** and reproduced the docs/05 prediction at
      runtime: on the legacy lanes the align-1 `blob_sum` gave `zig FAIL` and
      `d FAIL` (with D also missing the align-4 `point_dot`); on the canonical
      lane (`$ZIG` 0.17 + `$LDC2` 1.42.0) all by-value cases pass and qemu
      xtensa reports 0 failures. By-pointer always passes everywhere.
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
      #277/#275/#253/#256/#258. The only untested frontend config.
- [x] **Zig struct-ABI gaps upstream tracking** — closed by ziglang/zig #5467
      (Xtensa Support, landed 0.17.0 / 2026-05-06). Both the Xtensa align-1
      and the RISC-V `{i32,i32}→[2 x i64]` paths now flatten to `[N x i32]`
      like clang; the historical `experiments/abi-structs` repros run clean
      on `$ZIG`. The legacy `$ZIG_016` lane still reproduces the breaks for
      the regression tracker (docs/05 §"Zig 0.17 status").
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
      `experiments/zero-cost/run.sh`). Monomorphized generics / lambdas /
      static dispatch are byte-identical to the C hand-loop modulo a
      frame-pointer policy. Dynamic dispatch (C++ virtual / Rust `dyn
      Trait`) costs +2-3 insns / call. D class in -betterC needs hand-
      rolled malloc + placement; identical machine code to C++ `new T(args)`
      and Rust `Box::new`. D `struct` (4 insns / 9 B) is the canonical
      embedded answer.
- [x] **TMP feature surface parity D × C++ × Rust** (docs/26,
      `experiments/tmp-parity/run.sh`). Twelve TMP capabilities × 3
      languages. D supports 11/12 in-language; C++ 10/12 (no in-language
      reflection, no identifier synthesis); stable Rust 6/12 (proc-macros
      cover ~3 more at ~50-100 MB per consumer crate). Plus the docs/26
      §h disentanglement of D's three `extern(C++)` FFI forms — the PR-27
      zero-cost `extern(C++) class Counter` was form (1) PRODUCER (D
      emits vtable), DIFFERENT from form (2) CONSUMER used by the docs/21
      shim matrix.
- [x] **RISC-V parity for zero-cost + TMP + esp32p4 vendor SIMD** (folded
      back into docs/09 / docs/16 / docs/25 / docs/26 — no docs/27).
      `experiments/{zero-cost,tmp-parity,simd}/run.sh` parameterized for
      esp32c3 (rv32imc) and esp32p4 (rv32imafc); every monomorphization /
      inlining / static-vs-dynamic / heap / TMP conclusion holds ISA-
      portably (riscv leaf functions 1-2 insn tighter than xtensa thanks to
      no register windows). **esp32p4 vendor PIE/ESPV SIMD added to
      experiments/simd/run.sh §7** — three vendor extensions (`+xespv` ESPV
      2.2 / `+xespv1v` ESPV 2.1 / `+xesploop`); `esp.*` mnemonic family,
      128-bit q0..q? + qacc/xacc regs; **byte-identical inline-asm
      encodings across clang/zig/LDC/rustc** (shared libLLVM RISC-V
      assembler). ESPV 2.1 ↔ 2.2 wire-incompatible; use `-mcpu=esp32p4eco4`
      for the 412 documented mnemonics. esp32c3 has no vendor SIMD (rejected
      like esp32 LX6 rejects EE.*). Toolchain matrix in docs/09 §"Four-
      frontend toolchain matrix"; zero-cost RISC-V variant in docs/25; TMP
      RISC-V variant in docs/26; esp32p4 SIMD section in docs/16.

## How to resume

```bash
./scripts/setup.sh && source scripts/env.sh
./scripts/build-ffi.sh all && ./scripts/analyze.sh esp32
```

Everything regenerates into `build/` (gitignored). See `CLAUDE.md` for the
solved gotchas before changing build commands.
