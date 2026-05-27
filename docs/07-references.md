# 07 — References & related work

External references gathered via web search (research agents). URLs were
search-verified; where a page blocked automated fetch (GitHub / rust-lang docs
often return 403 to bots) the **title + URL are confirmed but the body was not
deep-read** — verify before quoting as authority. This is background/related
work, not a dependency of the experiments.

## Xtensa ABI & ISA

- **GCC "Xtensa Options"** — <https://gcc.gnu.org/onlinedocs/gcc/Xtensa-Options.html>
  — authoritative on `-mabi=call0` vs the default windowed ABI, and the register
  convention (windowed: caller stages outgoing args in `a10..a15`, rotated to
  `a2..a7` in the callee). Directly corroborates our `call8`/`callx8` disassembly.
- **Xtensa ABI Interface** — Linux/Xtensa wiki —
  <https://wiki.linux-xtensa.org/index.php?title=ABI_Interface> — windowed vs
  call0, args `a2..a7`, 8-byte args in even/odd pairs, struct padding/return.
- **Overview of Xtensa ISA** (Espressif) —
  <https://dl.espressif.com/github_assets/espressif/xtensa-isa-doc/releases/download/latest/Xtensa.pdf>
  — `CALLn`/`CALLXn` window rotation, `entry`, register-windowed return values.
- **xtensa-isa-doc `WindowedOption.tex`** —
  <https://github.com/espressif/xtensa-isa-doc/blob/main/WindowedOption.tex> —
  source for the 64-register sliding-window option (`entry`/`retw`).
- **GCC patch: "fix Xtensa ABI for structures returned in registers"** (B. Wilson,
  2004) — <https://gcc.gnu.org/legacy-ml/gcc-patches/2004-03/msg00487.html> —
  aggregates returned in up to 4 registers, sub-word structs in the LSBs;
  historical basis for the `[N x i32]` coercion clang/rust still do.
- **LLVM-dev: "On passing structures in registers"** —
  <https://groups.google.com/g/llvm-dev/c/CafdpEzOEp0> — general background on
  clang coercing aggregates to word-sized types (the `[N x i32]` pattern, docs/05).
- **gcc-xtensa: data alignment hardcoded to 4** —
  <https://github.com/jcmvbkbc/gcc-xtensa/issues/2> — an Xtensa-specific
  struct-alignment quirk; context for the alignment sensitivity we observe.

## LLVM Xtensa backend (status / upstreaming)

- **espressif/llvm-project releases** —
  <https://github.com/espressif/llvm-project/releases> — the fork providing the
  WIP Xtensa target (`-mcpu=esp32/esp32s2/esp32s3`) shared by clang, rust and zig.
- **RFC: Request for upstream Tensilica/Xtensa ESP32 backend** (LLVM Discourse) —
  <https://discourse.llvm.org/t/rfc-request-for-upstream-tensilica-xtensa-esp32-backend/65355>
  — Espressif's upstreaming request.
- **RFC: Tensilica Xtensa ESP32 backend** (original) —
  <https://discourse.llvm.org/t/rfc-tensilica-xtensa-esp32-backend/57835> — the
  initial experimental-target proposal.
- **LLVM all-commits: "[Xtensa] Add esp32/esp8266 cpus implementation"** (Aug 2025)
  — <https://lists.llvm.org/pipermail/all-commits/Week-of-Mon-20250811/241722.html>
  — upstream LLVM gaining esp32/esp8266 `-mcpu` parser support (s2/s3 still
  fork-side at time of writing).

## Zig on Xtensa & Zig's C-ABI lowering

- **ziglang/zig #5467 — Xtensa Support** —
  <https://github.com/ziglang/zig/issues/5467> — Zig's Xtensa tracking issue
  (no native upstream Xtensa codegen; needs the LLVM fork). Explains why we use
  the espressif-bootstrap Zig.
- **kassane/zig-espressif-bootstrap (xtensa)** —
  <https://github.com/kassane/zig-espressif-bootstrap/blob/xtensa/README.md> —
  the exact Zig used: Zig 0.16 + Espressif LLVM 21.1.0.
- **zig `src/codegen/llvm.zig`** —
  <https://github.com/ziglang/zig/blob/master/src/codegen/llvm.zig> — where Zig
  lowers C calling conventions (aggregate by-value / byval handling); the area the
  Xtensa struct-arg gap (docs/05) lives in.
- **ziglang/zig #22515** — <https://github.com/ziglang/zig/issues/22515> —
  *close prior art*: Zig stack-spills an aggregate parameter that the C ABI passes
  in registers (SystemV/x86-64). Same class of bug, different target.
- **ziglang/zig #18916** — <https://github.com/ziglang/zig/issues/18916> —
  another aggregate-argument ABI mismatch vs clang/gcc/rust.

> Our specific finding — Zig stack-spilling **`align(1)` by-value struct
> arguments on Xtensa** that clang/rust/gcc flatten to `[N x i32]` in `a2..a7`
> — does not appear to be separately reported. #22515/#18916 are the nearest
> existing reports (non-Xtensa, not alignment-triggered).

## Rust on Xtensa (esp-rs)

- **esp-rs/rust** — <https://github.com/esp-rs/rust> — the rust-xtensa fork
  (built-in `xtensa-esp32-none-elf` etc.), source of the toolchain used here.
- **rustc platform support: Xtensa** —
  <https://doc.rust-lang.org/rustc/platform-support/xtensa.html> — Tier-3 targets;
  notes `build-std` usage (matches our setup).
- **rust-lang/rust #125141** — <https://github.com/rust-lang/rust/pull/125141> —
  upstreaming of the no_std Xtensa targets.
- **esp-rs/esp-hal** — <https://github.com/esp-rs/esp-hal> — the no_std Rust HAL
  for ESP32/Xtensa + ESP32-C/RISC-V; the practical consumer of `xtensa-*-none-elf`
  and a real-world setting for the C/Rust FFI studied here.

## LLVM IR / bitcode / cross-language LTO

- **LLVM Language Reference — `target datalayout`** —
  <https://llvm.org/docs/LangRef.html> — normative semantics of the datalayout
  string the three frontends emit identically (docs/04).
- **LLVM Developer Policy** — <https://llvm.org/docs/DeveloperPolicy.html> —
  bitcode is backward-compatible but textual IR is not; explains why same-version
  links and why our zig (21.1.0) bitcode fails the 21.1.3 LTO reader.
- **"Closing the gap: cross-language LTO between Rust and C/C++"** (LLVM blog,
  2019) — <https://blog.llvm.org/2019/09/closing-gap-cross-language-lto-between.html>
  — official write-up of Rust↔clang LTO and the matching-LLVM-version requirement
  (docs/04, our clang↔rust LTO success / clang↔zig failure).
- **Linker-plugin-based LTO — rustc book** —
  <https://doc.rust-lang.org/rustc/linker-plugin-lto.html> — `-Clinker-plugin-lto`
  and the rustc/clang same-LLVM-version rule.

## FFI lingua franca & name mangling

- **The Rustonomicon — FFI** — <https://doc.rust-lang.org/nomicon/ffi.html> —
  `extern "C"` + `#[no_mangle]`.
- **Zig documentation** — <https://ziglang.org/documentation/master/> —
  `export fn` / `extern struct` C-ABI semantics.
- **Rust symbol mangling v0** —
  <https://doc.rust-lang.org/rustc/symbol-mangling/v0.html> (RFC 2603:
  <https://rust-lang.github.io/rfcs/2603-rust-symbol-name-mangling-v0.html>) —
  the `_R…` scheme seen in docs/06.
- **Itanium C++ ABI — mangling** —
  <https://itanium-cxx-abi.github.io/cxx-abi/abi-mangling.html> — the `_Z…` scheme.

## Related polyglot ESP projects (prior art)

- **georgik/esp32c3-rust-zig** — <https://github.com/georgik/esp32c3-rust-zig> —
  a Rust `no_std` ESP32-C3 app calling Zig through a static library — direct
  prior art for Rust+Zig FFI on ESP (RISC-V side).
- **kassane/zig-esp-idf-sample** — <https://github.com/kassane/zig-esp-idf-sample>
  — Zig on ESP-IDF (Xtensa + RISC-V).
- **kassane/esp32-baremetal-zig** — <https://github.com/kassane/esp32-baremetal-zig>
  — bare-metal Zig on ESP32 (Xtensa) without ESP-IDF; closest prior art for the
  pure-Zig Xtensa path exercised here, and a good base for a runtime qemu harness
  (docs/08).
