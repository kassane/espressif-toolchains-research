# 14 — All open esp-rs/rust issues: status & cross-frontend comparison

Every **open** issue in `esp-rs/rust` (12 total at time of writing), re-tested on
this toolchain (rustc 1.95.0-nightly / LLVM 21.1.3) and, where a frontend-neutral
comparison is meaningful, ported to clang / gcc / zig / D/LDC. `esp-rs/rust`
is a **fork** (see docs/00); "upstream" is not an option for any of this.
TinyGo is excluded — its whole-program model (docs/24) wouldn't survive most
of these reproducers, which depend on cargo / build-std / per-symbol .o
emission.

| # | symptom | reproduced here? | needs | cross-frontend note |
|---|---------|------------------|-------|---------------------|
| **#270** | `-C force-frame-pointers` → "Cannot scavenge register … emergency spill slot" | **YES** (building `compiler_builtins`) | `+esp`, `-Cforce-frame-pointers` | LLVM-xtensa regalloc limit under high pressure + forced FP; clang/gcc `-fno-omit-frame-pointer` on a small fn does **not** trip it |
| **#278** | `u8`/`u16` stack args stored narrow not `s32i` | **YES** (rust 1.95-nightly still emits 6×`s8i`+4×`s16i`; see below) | `xtensa-esp32-none-elf` | store width differs (**rust/clang narrow** `s8i/s16i`, **gcc/zig/D wide** `s32i`); **offsets agree** (4-byte slots); manifests only when callee reads the full slot as `u32` |
| **#277** | ICE `Cannot select XtensaISD::PCREL_WRAPPER` (serde) | **espidf-only** | `xtensa-esp32s3-espidf` + serde | exact repro builds clean on `*-none-elf`; clang/gcc compile float pools fine (docs/13) |
| **#243** | `size_of::<Self>()` → rustc SIGSEGV (release) | **NO** (minimal, on 1.95) | `esp32s3-none-elf`, opt3 | was 1.80/1.82; minimal repro compiles fine now |
| **#275** | ICE `Cannot select i32 = Constant<4096>` | not reproduced minimally | `espidf`, opt3, `piper`+esp-idf-hal | needs the espidf std target + crates |
| **#253** | `Undefined temporary symbol .LBBxx` (rustls) | not attempted | `espidf` + rustls/ring/suppaftp | x86-64 fine → xtensa backend; heavy multi-crate repro |
| **#256** | LTO-stage ICE (`Undefined temporary symbol`) regex-automata | not attempted | `espidf` + regex-automata + LTO | same family as #253 |
| **#258** | async_io Timer deadlock / `LoadProhibited` (atomics) | not attempted | `espidf` + wifi, **runtime** | suspected atomics codegen; needs hardware/IDF |
| **#265** | expose SIMD `q` regs as an `asm!` register class | n/a (feature request) | esp32s3 SIMD | not a bug |
| **#267** | "upstream asm patches" | n/a (empty tracking issue) | — | not a bug |
| **#89** | "merge Xtensa into rust-lang/rust?" | n/a (question) | — | **confirms esp-rs/rust is a fork, not upstreamed** (docs/00) |
| **#76** | IP-based backtraces under ESP-IDF | n/a (enhancement) | espidf | not a bug |

## The two directly testable bugs

### #270 — forced frame pointers ⇒ register-scavenge failure (reproduces)
`RUSTFLAGS="-C force-frame-pointers"` building for `xtensa-esp32-none-elf` fails
in `compiler_builtins`:

```
rustc-LLVM ERROR: Error while trying to spill A8 from class AR:
  Cannot scavenge register without an emergency spill slot!
```

This is an **LLVM-Xtensa register-allocation limitation**: forcing a frame pointer
removes a register, and a high-pressure function (here in `compiler_builtins`) has
nothing left to scavenge. It is a *shared-backend* problem in principle — but
clang/gcc with `-fno-omit-frame-pointer` on an ordinary register-heavy function do
**not** trip it, so in practice only Rust hits it (via `build-std` of the
register-heavy `compiler_builtins`). Mitigation: don't force frame pointers on
Xtensa.

### #278 — narrow stack-arg store width (frontend-divergent, offsets agree)
For a function with 6 register args + 5 `u8`/`u16` stack args
(`experiments/esp-rs-issues/open-issues.sh §"#278"`, current toolchain), the
**outgoing stack-slot offsets are 4-byte-stepped everywhere** — only the
*store width* differs:

| frontend | caller stores observed (`callm`) | policy |
|---|---|---|
| rust 1.95-nightly | 6× `s8i` + 4× `s16i` | **narrow** (matches clang) |
| clang 21.1.3 | 6× `s8i` + 4× `s16i` | **narrow** |
| gcc 15.2.0 | 5× `s32i` | widened |
| zig 0.17 | 5× `s32i` | widened |
| D/LDC 1.42.0 | 5× `s32i.n` | widened (joins gcc + zig) |

So **rust and clang use narrow stores; gcc, zig, and D/LDC widen to `s32i`**.
Since callees read *narrow* by default (`l8ui`/`l16ui`) when the param type
is `u8`/`u16`, the divergence is benign for matching declarations on both
sides. **The corruption #278 reported arises when a callee reads the full
32-bit slot** expecting a widened value — the binding case: a C library
declared its parameter as the typedef-resolved `unsigned` (= read as
`l32i`) and the Rust binding declared it as `u8` (= caller emits `s8i`,
upper bytes undefined).

**End-to-end runtime repro on qemu-system-xtensa** (`run.sh §"Runtime
miscompile tests"` and `runtime/rt_*.{rs,c,zig,d}`): the callee `fm_u32_callee`
reads 5 stack slots as `u32` and returns their sum. Each per-frontend
caller declares the callee with `u8`/`u16` and calls it with `(10, 20, 30,
40, 50)` — so the correct sum is 150. The C/clang and Rust callers are in
their own TUs to prevent the optimizer from inlining + constant-propagating
the literals into widened stores; that's the same scenario as a real
binding crate sitting in its own `.rlib`.

```
clang_issue278_callm = 134,152,086  FAIL (#278 reproduces)
gcc_issue278_callm   = 150           ok
rs_issue278_callm    = 3,159,446     FAIL (#278 reproduces)
zig_issue278_callm   = 150           ok
d_issue278_callm     = 150           ok
```

So the bug isn't actually Rust-specific — **clang and Rust both silently
corrupt**, while gcc, zig, and D/LDC widen the stores and produce the
correct result. The mismatch is only between the caller's *narrow* and the
callee's *widened-read* expectations, both legal on their own. **Safe FFI
rule**: declare such ABI-critical params as `u32` on both sides (the
issue's own workaround), or keep ≤ 6 args so nothing is stack-passed.
Concrete numbers for the upstream issue: switching the Rust binding's
`u16` params to `u32` flips the test from `FAIL` to `ok` without any
runtime cost.

### #270 cross-frontend cross-check: D/LDC compiles clean
`ldc2 --frame-pointer=all -Os` on a 6-arg register-heavy function in `ports.d`
compiles **without ICE** — matching clang/gcc and unlike Rust's
`compiler_builtins` build. So #270 is a *Rust-specific* manifestation of an
LLVM-Xtensa regalloc edge case; the backend isn't generally broken under
forced FP, only when an ABI-critical, very high-pressure crate is
build-std-ed under it.

## ESP-IDF-gated issues

**#275, #253, #256, #258** (and the full **#277**) all require the
`xtensa-*-espidf` **std** target — i.e. the ESP-IDF C framework + `ldproxy` +
`build-std=std` (+ crates.io). That environment is out of scope for this
toolchain-only repo; #277 was narrowed to *being* espidf-specific (docs/13), which
is consistent with this cluster of std-target ICE/codegen reports.

## Not bugs

**#265** (SIMD `asm!` register class) and **#76** (backtraces) are enhancements;
**#267** is an empty tracking issue; **#89** asks to upstream Xtensa into
`rust-lang/rust` — which directly confirms the framing in docs/00 that today
`esp-rs/rust` is a *fork* and there is no stock-upstream Xtensa Rust.
