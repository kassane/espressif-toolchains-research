# 14 — All open esp-rs/rust issues: status & cross-frontend comparison

Every **open** issue in `esp-rs/rust` (12 total at time of writing), re-tested on
this toolchain (rustc 1.95.0-nightly / LLVM 21.1.3) and, where a frontend-neutral
comparison is meaningful, ported to clang / gcc / zig. `esp-rs/rust` is a **fork**
(see docs/00); "upstream" is not an option for any of this.

| # | symptom | reproduced here? | needs | cross-frontend note |
|---|---------|------------------|-------|---------------------|
| **#270** | `-C force-frame-pointers` → "Cannot scavenge register … emergency spill slot" | **YES** (building `compiler_builtins`) | `+esp`, `-Cforce-frame-pointers` | LLVM-xtensa regalloc limit under high pressure + forced FP; clang/gcc `-fno-omit-frame-pointer` on a small fn does **not** trip it |
| **#278** | `u8`/`u16` stack args stored `s16i` not `s32i` | partial — see below | `xtensa-esp32s3-none-elf` | store width differs (**rust/clang narrow** `s8i/s16i`, **gcc/zig wide** `s32i`); **offsets agree** (4-byte slots); gcc callee *reads* narrow (`l8ui/l16ui`) |
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
For a function with 6 register args + several `u8`/`u16` stack args
(`experiments/esp-rs-issues` analysis), the **outgoing stack-slot offsets are
4-byte-stepped in all four toolchains**. They differ only in *store width*:

| | caller writes a narrow stack arg | callee reads it |
|---|---|---|
| rust  | `s8i`/`s16i` (low bytes; upper slot bytes undefined) | — |
| clang | `s8i`/`s16i` (narrow) | (narrow) |
| gcc   | `s32i` (widened, fills the 4-byte slot) | `l8ui`/`l16ui` (narrow) |
| zig   | `s32i` (widened) | — |

So rust and clang agree (narrow), gcc and zig agree (wide); since callees read
*narrow* (gcc verified), the difference is benign for a callee that reads its
`u8`/`u16` args narrowly. #278's reported corruption arises only if a callee reads
the **full 32-bit slot** expecting a widened value — the safe FFI rule is the
familiar one: declare such ABI-critical params as `u32` (its workaround), or keep
≤ 6 args so nothing is stack-passed.

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
