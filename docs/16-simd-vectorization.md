# 16 — SIMD & vectorization on Xtensa

Where ESP Xtensa stands on SIMD, autovectorization, and the inline-asm path.
Reproduce with `experiments/simd/run.sh`.

## TL;DR

- **Only ESP32-S3 has a SIMD unit** — the 128-bit `EE.*` "PIE" extension
  (q0–q7). ESP32 (LX6) and ESP32-S2 have **no** SIMD (`EE.*` is rejected:
  *"instruction use requires an option to be enabled"*).
- **No autovectorization, anywhere.** Neither LLVM (clang / rust / zig) nor GCC
  vectorizes to the S3 unit. Vectorizable loops compile to **scalar** code;
  explicit vector types (`__attribute__((vector_size))`, Zig `@Vector`) are
  **scalarized** (16× scalar ops). The LLVM Xtensa backend has no codegen-usable
  vector register class for q0–q7, so the loop/SLP vectorizer has nothing to
  target.
- **Inline assembly is the only way** to use S3 SIMD — and all three toolchains
  (clang, gcc, zig) assemble `EE.*` fine.

## Autovectorization (esp32s3, `-O3`) — all four scalarize

```
vadd loop (i8/i16/i32/f32)       →  clang 0 · gcc 0 · zig 0 · rust 0  EE.*  (scalar)
vector_size(16) int8 add (clang) →  0 EE.*, 16 scalar add.n
@Vector(16,i8) add (zig)         →  0 EE.*, 17 scalar adds
core::simd i8x16 add (rust)      →  0 EE.*, 18 scalar adds
```

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

Verified on Zig 0.16 (espressif bootstrap): assembles the same 4 `EE.*`
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

So on the SIMD axis all four toolchains are at **parity**: none autovectorize for
Xtensa (Rust `core::simd`, Zig `@Vector` and clang `vector_size` all scalarize),
and each reaches the S3 unit only through hand-written `EE.*` —
C/C++ with a `"memory"` clobber, **Zig** with the modern struct clobbers
(`.{ .memory = true, .q0 = true, … }`), **Rust** with `core::arch::asm!` under
`#![feature(asm_experimental_arch)]` (no `qreg` class yet — esp-rs #265).
