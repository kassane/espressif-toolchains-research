# 16 — SIMD & vectorization on Xtensa + RISC-V

Where the ESP family stands on SIMD: the **xtensa s3 EE.\* PIE** unit and the
**RISC-V esp32p4 vendor ESPV** unit. Autovectorization, explicit vector types,
and the inline-asm path across all six toolchains. Reproduce with
`experiments/simd/run.sh`.

## TL;DR

- **Two ESP chips have a SIMD unit**: xtensa esp32s3 (`EE.*` 128-bit PIE,
  q0-q7) and riscv esp32p4 (`esp.*` 128-bit ESPV, q0..q? + qacc/xacc). esp32
  (LX6), esp32s2, esp32c3 have **none**. The two units share a remarkable
  amount of design: same width, same q-register family, same "vld → vop →
  vst" idiomatic kernel shape. The ISAs differ but the *capability* is
  parallel.
- **No autovectorization, on either unit.** Neither LLVM (clang / rust /
  zig / LDC) nor GCC vectorizes to the S3 or P4 vector unit. Vectorizable
  loops scalarize; explicit vector types (`__attribute__((vector_size))`,
  Zig `@Vector`, Rust `core::simd`, D `__vector`) scalarize to 16× scalar
  ops. The LLVM Xtensa AND RISC-V vendor backends have no codegen-usable
  vector register class or cost model for the q regs, so the loop/SLP
  vectorizer has nothing to target.
- **Inline assembly is the only way** to use either vector unit — and
  every LLVM frontend (clang / zig / LDC / rust) and gcc (xtensa only)
  assembles the mnemonics cleanly. **Cross-frontend encodings are
  byte-identical** because they share libLLVM's per-arch assembler.

## Autovectorization (esp32s3, `-O3` / `-opt=2`) — all six scalarize

```
vadd loop (i8/i16/i32/f32)       →  clang 0 · gcc 0 · zig 0 · rust 0 · D 0 · TinyGo 0  EE.*  (scalar)
vector_size(16) int8 add (clang) →  0 EE.*, 16 scalar add.n
@Vector(16,i8) add (zig)         →  0 EE.*, 17 scalar adds
core::simd i8x16 add (rust)      →  0 EE.*, 18 scalar adds
__vector(byte[16]) add (D/LDC)   →  0 EE.*, 16 scalar (matches clang vector_size pattern)
TinyGo: loop scalarized at -opt=0 (`l8ui`/`add.n`/`s8i`); DCE'd at -opt=2.
        No `core/simd` analog in Go; no Xtensa inline-asm directive in TinyGo.
```

The TinyGo row was verified at the shell: `tinygo build -opt=0 -target=esp32s3-generic`
on a `func go_vadd_i8(dst, a, b *[16]int8)` produces a 132-byte function
with `add.n` + `l8ui` + `s8i` and zero `EE.*`. At `-opt=2` LTO proves the
writes are dead and collapses the function to `entry a1,32; retw.n` —
which is its own kind of "no SIMD here" confirmation.

A `vadd_i8` body is a plain byte loop — `l8ui` / `add.n` / `s8i` / `addi.n` /
`bnez` — not a single `ee.*`. So for compute-heavy ESP32-S3 code you do **not**
get free SIMD from `-O3`; the compiler emits scalar Xtensa. Rust's portable
`core::simd` (`i8x16`) scalarizes exactly like clang's `vector_size` and Zig's
`@Vector` — same backend limitation.

## Inline asm — the real path (clang / gcc / zig)

The assembler in every toolchain knows the `EE.*` mnemonics for `-mcpu=esp32s3`.
A hand-written `int8x16` add (`experiments/simd/ee.c`):

```c
__asm__ volatile(
  "ee.vld.128.ip q0, %1, 0\n"
  "ee.vld.128.ip q1, %2, 0\n"
  "ee.vadds.s8   q2, q0, q1\n"
  "ee.vst.128.ip q2, %0, 0\n"
  : : "r"(d), "r"(a), "r"(b) : "memory");
```

assembles to 4 `EE.*` instructions under clang **and** gcc.

### Zig: the new struct-form asm clobbers (0.15+)

Zig moved inline-asm clobbers from a string (`: "memory"`) to a **struct**
(`std.builtin` `Clobbers`), which can name **q registers**
(`experiments/simd/ee.zig`):

```zig
asm volatile (
    \\ee.vld.128.ip q0, %[a], 0
    \\ee.vld.128.ip q1, %[b], 0
    \\ee.vadds.s8   q2, q0, q1
    \\ee.vst.128.ip q2, %[d], 0
    :
    : [d] "r" (d), [a] "r" (a), [b] "r" (b),
    : .{ .memory = true, .q0 = true, .q1 = true, .q2 = true });
```

Verified on the canonical Zig 0.17 (espressif bootstrap, LLVM 22.1.4) and
the legacy `$ZIG_016` (LLVM 21.1.0): both assemble the same 4 `EE.*`
instructions, operands routed to `a2/a3/a4`, with q-register clobbers accepted.
(Old `: "memory"` string form is gone in 0.15+.)

### Rust: `core::arch::asm!` (needs `asm_experimental_arch`)

Same path in Rust (`experiments/simd/rs`), with two nightly caveats:

```rust
#![feature(asm_experimental_arch)]   // Xtensa asm! is experimental → required
core::arch::asm!(
    "ee.vld.128.ip q0, {a}, 0",
    "ee.vld.128.ip q1, {b}, 0",
    "ee.vadds.s8   q2, q0, q1",
    "ee.vst.128.ip q2, {d}, 0",
    a = in(reg) a, b = in(reg) b, d = in(reg) d,
);
```

Assembles the same 4 `EE.*` (q0/q1/q2, operands `a2/a3/a4`). The q registers are
**hardcoded** in the template — there is **no `qreg` register class** in rustc's
xtensa `asm!`, so you can't write `out(qreg) _` to let the compiler allocate or
declare them clobbered (this is exactly esp-rs/rust **#265**). In practice the
compiler never *uses* q regs, so hardcoding q0–q2 is safe.

### Cross-frontend inline-asm clobber matrix

The four LLVM frontends differ sharply on how (or whether) they can declare
PIE q-registers as clobbered. This matters: the LLVM register allocator
won't avoid reuse of a q-register unless the constraint string says so, and
on Xtensa the *only* clobber signal C/clang exposes to LLVM for q-regs is
`memory` — clang has no q-register class at the constraint-parser level.

| frontend | idiomatic form | does the q clobber reach LLVM? |
|---|---|---|
| C / esp-clang 21.1.3 | `: : : "memory"` only — `~{q0}` rejected at parse: *"unknown register name 'q0'"* | **no** |
| Zig 0.17 | `: .{ .memory = true, .q0 = true, .q1 = true, .q2 = true }` (`std.lang.assembly.Clobbers`) | **yes** — lowers to `~{q0},~{q1},~{q2}` in IR |
| D / LDC 1.42.0 | raw LLVM constraint string: `"r,r,r,~{memory},~{q0},~{q1},~{q2}"` | **yes** — pass-through (no validation) |
| Rust 1.95-nightly | `out("q0") _` rejected: *"unknown register"* (esp-rs/rust#265 + PR #272 draft, not merged) | **no** until #272 lands |

The Zig clobber fields live in `$ZIG_DIR/lib/std/lang/assembly.zig`'s
`pub const Clobbers = switch (cpu.arch)` block — Xtensa branch starts at
line 852 (`.xtensa, .xtensaeb`); q0..q7 are at lines 930-937 alongside
a0..a15, b0..b15, f0..f15, MAC16 (acchi/acclo/m0..m3), and control regs
(sar/lbeg/lend/ps/...). The Clobbers struct was *renamed from
`std.builtin.Clobbers` to `std.lang.assembly.Clobbers`* in Zig 0.17 (the
old path remains aliased one release for deprecation).

**RISC-V ESPV gap**: the same file's `.riscv32, .riscv32be, ...` branch
(lines 646-827) defines the standard RVV `v0..v31` registers but has **no
q-regs for Espressif ESPV**. So on esp32p4 / esp32s31 the q-reg clobber
path is unreachable via the Zig struct surface; only `.memory = true`
applies. `experiments/simd/esp.zig` reflects this constraint.

**LDC parity update (2026-06)**: `experiments/simd/ee.d` now uses
`"r,r,r,~{memory},~{q0},~{q1},~{q2}"` (was `"r,r,r,~{memory}"`) — the LDC
side previously left the q-reg clobbers off for parity with the C version,
but that under-constrained the register allocator. Zig had it right; D now
matches.

**rustc status**: esp-rs/rust **#265** (q-reg register class) is still
open. Tracking PR **#272** ("Expose SIMD q register class") sits in draft
as of 2026-06-05 — adds `xtensa_reg::qreg` plus an LLVM submodule pointer
bump. Once #272 merges, the Rust side can write `out("q0") _, out("q1") _`
and the asm template `q0`/`q1` references become allocator-managed.

**Upstream Xtensa asm! milestone**: `rust-lang/rust#147302` ("asm! support
for the Xtensa architecture", MabezDev) **merged 2026-06-05**. Xtensa
inline-asm is now a non-fork upstream Rust feature; the `esp-rs/rust`
patches on this front become rebase-clean. `#![feature(asm_experimental_arch)]`
will continue to be required until #147302 graduates from "experimental
arch", per the upstream policy.

## C++26 `<simd>` (P1928) — not yet a path

The natural seventh row in the parity table would be C++26's
`std::simd` ([P1928](https://wg21.link/P1928)), the standardized version
of `std::experimental::simd` (TS). It's the C++-language analog of Rust's
`core::simd` / Zig's `@Vector` / D's `__vector(byte[16])` — a portable
fixed-width vector type with abi tags (`std::simd_abi::native_abi<T>`).
Status as of writing, probed at the shell against three libc++ revisions
and the matrix's libstdc++:

- `$ZIG c++` — canonical Zig 0.17 bundle: clang 22.1.4 / libc++ 22.
- `$ZIG_016 c++` — legacy Zig 0.16 bundle: clang 21.1.0 / libc++ 21.
- `$GXX` — esp-g++ 15.2.0 / libstdc++ 15, `-ffreestanding` xtensa-esp-elf.

| header | libc++ 21 (`$ZIG_016` legacy bundle) | libc++ 22 (`$ZIG` canonical 0.17 bundle) | libstdc++ 15 (`$GXX`) |
|---|---|---|---|
| `<simd>` (P1928) | ✗ MISSING | ✗ MISSING — frontier item, not landed in libc++ 22 either | ✗ MISSING — not in libstdc++ 15 either (same upstream gap) |
| `<experimental/simd>` (TS) | ✓ parses | ✓ parses, **but** operator+/-/*/etc. binary forms are stubs: | ✓ parses **hosted** — but `bits/requires_hosted.h` blocks `-ffreestanding` (the canonical embedded compile mode), so unreachable on bare-metal xtensa-esp-elf |

```
error: invalid operands to binary expression
  ('stdx::native_simd<int>' and 'stdx::native_simd<int>')
note: candidate function not viable: requires 0 arguments, but 2 were provided
  137 |   simd operator+() const noexcept { return *this; }
```

So you can declare a `native_simd<int>` and read elements, but you can't
add two vectors together — the libc++ TS implementation is incomplete in
both 21 and 22. libstdc++ 15 ships `<experimental/simd>` on disk but
`bits/requires_hosted.h` errors `"This header is not available in
freestanding mode."` under `-ffreestanding`, so the embedded build can't
include it. Even if libc++/libstdc++ shipped P1928 tomorrow, the codegen
story is unchanged on Xtensa: the LLVM Xtensa backend has no vector
register class or cost model (§"Why it's this way"), so
`std::simd<int, 4> a, b; a + b;` would scalarize to 4× `add.n` just like
clang's `vector_size(16)`, zig's `@Vector(16,i8)`, rust's
`core::simd::i8x16`, and D's `__vector(byte[16])` do today. **C++26
`<simd>` is the missing portable SIMD API across every C++ standard
library in this matrix, but landing it wouldn't help ESP32-S3 reach
`EE.*` without an upstream cost-model patch.**

## Why it's this way & how to actually SIMD on S3

The `EE.*`/PIE extension is a **non-standard Xtensa option**; the LLVM Xtensa
backend (and GCC) expose the *instructions* (via `esp32s3ops`) but model neither a
vector register class nor vectorization cost, so the optimizers can't use them.
In practice you get S3 SIMD through:

- **ESP-DSP** (`espressif/esp-dsp`) — hand-written `EE.*` assembly kernels (FFT,
  dot-product, conv, matrix), the standard route.
- **Inline asm** as above — portable across clang/gcc/zig (mind the q-register
  clobbers / a non-clobbered scratch policy).
- **`esp-rs/rust` #265** requests a `qreg` `asm!` register class so rustc can
  *allocate* q registers instead of hardcoding `q0`/`q1` — i.e. better inline-asm
  ergonomics, still not autovectorization.

So on the SIMD axis the **six toolchains** are at parity in the negative
direction: none autovectorize for Xtensa (Rust `core::simd`, Zig `@Vector`,
clang `vector_size`, **D `__vector(byte[16])`**, and TinyGo's plain loops
all scalarize), and only five reach the S3 unit through hand-written `EE.*`
— C/C++ with a `"memory"` clobber, **Zig** with the modern struct clobbers
(`.{ .memory = true, .q0 = true, … }`), **Rust** with `core::arch::asm!`
under `#![feature(asm_experimental_arch)]` (no `qreg` class yet — esp-rs
#265), and **D** with `ldc.llvmasm.__asm` using LLVM constraint strings
(`"r,r,r,~{memory}"`; `experiments/simd/ee.d` emits the same 4 `EE.*`).
**TinyGo has no Xtensa inline-asm directive and no SIMD intrinsic library**
on v0.41.1 — neither autovectorized nor reachable, the strictest "no S3 SIMD"
of any toolchain here. The 324 `ee.*` instructions that show up in a
`tinygo build -opt=0` linked ELF are from the TinyGo runtime's picolibc /
startup code, not from user Go.

## ESP32-P4 RISC-V vendor SIMD (ESPV / Xespv / Xesploop)

The riscv twin of the s3 EE.* story. `experiments/simd/run.sh §7` exercises
it, reproducing the same autovec / explicit-type / inline-asm trichotomy.

### What the extensions actually are

`clang --target=riscv32-esp-elf --print-enabled-extensions -mcpu=esp32p4`:

| extension | version | enabled on | role |
|---|---|---|---|
| `Xespv` | 2.2 | esp32p4 (default) | ESPV PIE 128-bit vector ops |
| `Xespv1v` | 2.1 | esp32p4eco4 only | ESPV PIE older revision |
| `Xesploop` | 1.0 | both | zero-overhead hardware loops (analog of xtensa LOOP/LOOPGTZ) |
| `Xespdsp` | 2.1 | neither default | DSP, opt-in via `-march=...xespdsp` |

The ISA string emitted for esp32p4:

```
rv32i2p1_m2p0_a2p1_f2p2_c2p0_b1p0_zicsr2p0_zifencei2p0_zmmul1p0_zaamo1p0
_zalrsc1p0_zca1p0_zcb1p0_zcf1p0_zcmt1p0_zba1p0_zbb1p0_zbc1p0_zbs1p0
_xesploop1p0_xespv2p2
```

So esp32p4 is rv32imafc + B (zba/zbb/zbc/zbs) + extensive Zc compressed
extensions + the two vendor extensions. ABI is ilp32f. Vector regs are
**q0..q?**, accumulators **qacc** and **xacc** — same conceptual model as
xtensa s3 EE.*, all 128-bit wide.

### Mnemonics

`esp.*` family (lowercase, dotted) — riscv analog of xtensa `EE.*`.
Subfamilies (412 mnemonics total in `libLLVM.so.21.1` strings for
ESPV 2.1 / esp32p4eco4):

| subfamily | examples |
|---|---|
| vector load/store | `esp.vld.128.{ip,xp}`, `esp.vst.128.{ip,xp}`, `esp.vldbc.{8,16,32}.{ip,xp}` (broadcast), `esp.vldext.{s,u}{8,16}.{ip,xp}` (load-extend) |
| vector ALU | `esp.vadd.{s,u}{8,16,32}`, `esp.vsub`, `esp.vmul`, `esp.vmax/vmin`, `esp.vclamp`, `esp.vrelu`/`vprelu`, `esp.vsadds`/`vssubs` (saturating), `esp.vsl/vsr` (shifts) |
| complex / DSP | `esp.cmul.{s,u}{8,16}`, `esp.cmulas`, `esp.macs16x{1,2}`, `esp.macs32`, `esp.muls32` |
| FFT (the standout) | `esp.fft.ams.s16.*`, `esp.fft.bitrev`, `esp.fft.cmul.s16.*`, `esp.fft.r2bf.s16` (radix-2 butterfly), `esp.fft.vst.r32.decp` |
| accumulator / state | `esp.zero.q`, `esp.zero.qacc`, `esp.ldqa.{s,u}{8,16}.128.{ip,xp}`, `esp.ld.qacc.{l,h}.{l,h}.128.ip` |
| hardware loops | `esp.lp.setup`, `esp.lp.setupi`, `esp.lp.endi`, `esp.lp.count` |

ESPV 2.2 spellings are not yet publicly documented; the mainstream esp32p4
chip uses 2.2, the eco4 variant uses 2.1. **The two opcode tables are
wire-incompatible** — assembling `esp.vadd.s8 q2, q0, q0` against
`-mcpu=esp32p4` errors with `'Espressif ESPV 2.1' required`, while
`-mcpu=esp32p4eco4` accepts it. Use `-mcpu=esp32p4eco4` for any inline-asm
work today.

### Autovec + explicit vector types — same null result as xtensa s3

```
== 7.1 autovec on rv32imafc: vadd.c -O3 -> esp.* count    0
== 7.2 explicit vector types  -> scalarized:
        clang vector_size(16) esp.*=0  (scalar add x16)
        zig @Vector esp.*=0
```

No LLVM cost model exists for ESPV; the autovectorizer doesn't know the
PIE instructions are useful. Same situation as xtensa s3: `core::simd`,
`@Vector(16, u8)`, `int8_t __attribute__((vector_size(16)))`, and D's
`__vector(byte[16])` all scalarize. Only inline asm reaches the q-regs.

### Inline asm cross-frontend parity — byte-identical

Same five-instruction kernel (vld×2 → vadd → vst → ret), four LLVM
frontends. Source `experiments/simd/esp.c`:

```c
void esp_add(signed char* d, const signed char* a, const signed char* b){
  __asm__ volatile(
    "esp.vld.128.ip q0, %1, 0\n"
    "esp.vld.128.ip q1, %2, 0\n"
    "esp.vadd.s8    q2, q0, q1\n"
    "esp.vst.128.ip q2, %0, 0\n"
    : : "r"(d), "r"(a), "r"(b) : "memory");
}
```

Encoding output from `experiments/simd/run.sh §7.3`:

```
clang 0201a03b | 0202243b | 065f 06a0 283b | 8201 | 8082
zig   0201a03b | 0202243b | 065f 06a0 283b | 8201 | 8082
d     0201a03b | 0202243b | 065f 06a0 283b | 8201 | 8082
rs    0201a03b | 0202243b | 065f 06a0 283b | 8201 | 8082
```

Byte-identical across clang / zig / LDC / rust. The libLLVM RISC-V
assembler is shared across all four frontends, so inline-asm encodings
match by construction — same parity result the xtensa s3 EE.* block
produced.

The disassembler is incomplete in LLVM 21's RISC-V pretty-printer: the
third encoding `065f 06a0 283b` (the 6-byte `esp.vadd.s8 q2, q0, q1`)
renders as `<unknown>`, and the fourth `8201` (which is `esp.vst.128.ip
q2, %0, 0`) renders as `c.srli64 a2`. These are pretty-printer bugs, not
codegen issues; the bytes are correct (verified by hand-assembling against
the ESPV 2.1 opcode table) and all frontends agree on them.

### No intrinsic headers

```
$ find /home/user/toolchains/esp-clang/lib/clang -name "esp_pie*" -o -name "*xespv*"
(empty)
$ grep -l "xespv\|esp\.vld" /home/user/toolchains/esp-clang/lib/clang/21/include/*.h
(empty)
```

esp-clang ships generic riscv intrinsic headers (`riscv_vector.h`,
`riscv_bitmanip.h`, `riscv_corev_alu.h`, `riscv_crypto.h`, vendor
`andes_vector.h`, `sifive_vector.h`) but **no esp32p4 / esp_pie / xespv
header**. `riscv_vector.h` can't be used either: its bodies gate on
`__riscv_v_intrinsic` + the standard `V` / `Zve*` feature, and `vsetvli`
rejects with `'V' / 'Zve32x' required` on esp32p4. esp32p4 defines
`__riscv_xespv=2002000` macro but no header consumes it.

**Implication**: `asm volatile("esp.*")` is the ONLY emittable path today
for esp32p4 PIE. Same situation xtensa s3 EE.* was in before public helper
macros appeared. A vendor-supplied `esp_pie.h` would be the cleanest fix.

### esp32c3 has no SIMD

```
== 7.5 esp.* on esp32c3 -> assembler rejects:
    'instruction requires the following: Espressif ESPV 2.1/2.2'
   → matches xtensa: vendor SIMD only on the chip that has the unit.
```

Same selectivity as the EE.* probe on esp32 (LX6 has no SIMD; only s3 does).
The matrix is symmetric: vendor SIMD is per-chip, not per-architecture.

### esp32s31 — same ESPV 2.2 vendor SIMD as esp32p4

Announced March 2026, ESP32-S31 is Espressif's converged RISC-V SoC: P4-class
HP core IP + S3-class peripherals (USB / LCD / camera / JPEG codec) + WiFi 6
(802.11ax) + Bluetooth 5.4 + 802.15.4 (Thread/Zigbee/Matter) + **Gigabit
Ethernet**. At the LLVM level (commit
[c50ef2b](https://github.com/espressif/llvm-project/commit/c50ef2b)
"[RISCV] Define Espressif CPUs", 2026-03-02) the s31 RISCVProcessorModel is
**identical to esp32p4**: same `FeatureEspL5 + FeatureVendorXespv (ESPV 2.2)
+ FeatureVendorXesploop`. Codegen output uses the same instruction set, but
TuneFeature heuristics differ — `experiments/simd/run.sh §8.1` shows s31
emits Zba `sh{1,2,3}add` fusion where p4 emits `slli + add` pairs (both
legal on either CPU since the B extension is enabled on both; the choice is
a scheduler heuristic).

The same `experiments/simd/esp.c` / `.zig` / `.d` probes work unchanged on
`-mcpu=esp32s31`: vld/vst encodings are byte-identical across clang / zig /
LDC frontends; `esp.vadd.s8` still requires ESPV 2.1 (`esp32p4eco4`) — the
ESPV 2.2 mnemonic gap (§7.4) extends to s31 unchanged.

Toolchain matrix for esp32s31:

| frontend | flag |
|---|---|
| esp-clang 21.1.3 | `--target=riscv32-esp-elf -mcpu=esp32s31` |
| Zig 0.17.0-xtensa | `-target riscv32-freestanding-none -mcpu=esp32s31` |
| LDC 1.42.0 | `-mtriple=riscv32-unknown-none-elf -mcpu=esp32s31` |
| rustc 1.95-nightly | `--target riscv32imafc-unknown-none-elf -C target-cpu=esp32s31` |
| esp-gcc (riscv) | `-march=rv32imafc_b_xesploop_xespv -mabi=ilp32f` (no `-mcpu` form yet; riscv-esp-elf-gcc 15.2.0 not in this repo's setup) |
| TinyGo 0.41.1 | ✗ — bundled LLVM 20.1.1 predates the s31 ProcessorModel |

### TinyGo coverage

TinyGo v0.41.1 ships an `esp32p4` device-tree register definition file
(`device/esp/esp32p4.go`) — peripheral SVD bindings only, no ESPV asm
emission. TinyGo bundles LLVM 20.1.1 which predates esp-clang's 21.1.3
RISC-V vendor extension support; even if you tried `import "esp32p4"`
through TinyGo's `device/esp` package, the only access is to MMIO
registers, not the vector unit. TinyGo remains outside the SIMD probe matrix
for the same reason it's outside the FFI matrix (docs/24).
