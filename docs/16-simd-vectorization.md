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

## C++26 `<simd>` (P1928) — not yet a path

The natural seventh row in the parity table would be C++26's
`std::simd` ([P1928](https://wg21.link/P1928)), the standardized version
of `std::experimental::simd` (TS). It's the C++-language analog of Rust's
`core::simd` / Zig's `@Vector` / D's `__vector(byte[16])` — a portable
fixed-width vector type with abi tags (`std::simd_abi::native_abi<T>`).
Status as of writing, probed at the shell against both clang versions
in this matrix (`zig c++` 21.1.0 / libc++ 21; `kassane/zig-mos-bootstrap`
v0.17.0-dev = clang 22.0.0git / libc++ 22):

| header | libc++ 21 (Zig 0.16 bundle) | libc++ 22 (v0.17.0-dev bundle) |
|---|---|---|
| `<simd>` (P1928) | ✗ MISSING | ✗ MISSING — frontier item, not landed in libc++ 22 either |
| `<experimental/simd>` (TS) | ✓ parses | ✓ parses, **but** operator+/-/*/etc. binary forms are stubs: |

```
error: invalid operands to binary expression
  ('stdx::native_simd<int>' and 'stdx::native_simd<int>')
note: candidate function not viable: requires 0 arguments, but 2 were provided
  137 |   simd operator+() const noexcept { return *this; }
```

So you can declare a `native_simd<int>` and read elements, but you can't
add two vectors together — the libc++ TS implementation is incomplete in
both 21 and 22. Even if libc++ ships P1928 tomorrow, the codegen story is
unchanged on Xtensa: the LLVM Xtensa backend has no vector register class
or cost model (§"Why it's this way"), so `std::simd<int, 4> a, b; a + b;`
would scalarize to 4× `add.n` just like clang's `vector_size(16)`,
zig's `@Vector(16,i8)`, rust's `core::simd::i8x16`, and D's
`__vector(byte[16])` do today. **C++26 `<simd>` is the missing portable
SIMD API in this matrix, but landing it wouldn't help ESP32-S3 reach
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
