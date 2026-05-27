# Cross-language FFI on Xtensa via the shared espressif/llvm-project backend

A study of how far the *shared LLVM 21 Xtensa backend* takes us toward a *shared
ABI* between Zig, Rust and C/C++ on ESP32-class chips — and where it breaks.

All numbers, disassembly and IR in this document were produced on an x86_64
Linux host from the four toolchains pinned in [docs/01-toolchains.md](docs/01-toolchains.md).
Everything here is reproducible with `scripts/build-ffi.sh` + `scripts/analyze.sh`.

---

## 1. Hypothesis

`espressif/llvm-project` carries the work-in-progress Xtensa target. Three
language frontends consume (a fork of) it:

- **clang** — espressif's LLVM directly (`clang` 21.1.3).
- **rustc** — esp-rs ships a rustc built against the same LLVM (1.95-nightly, *LLVM 21.1.3*).
- **zig** — kassane's `zig-espressif-bootstrap` builds Zig against the same LLVM (0.16.0, *clang/LLVM 21.1.0*).

A fourth toolchain, **GCC 15.2** from `espressif/crosstool-NG`, shares *no* code
with LLVM and acts as an independent control for ABI questions.

If "shared backend ⇒ shared ABI" held strictly, the four should interoperate
perfectly. The interesting part is exactly where that implication leaks.

## 2. The backend really is shared

The three LLVM frontends expose the **identical Xtensa CPU feature model**. For
`esp32`, `rustc --print cfg`, clang's `target-features` attribute and
`zig build-obj --show-builtin` all enumerate the same 30 features
(`+fp,+windowed,+mac16,+loop,+s32c1i,+density,…`). For `esp32s2` all three drop
`fp`/`loop`/`mac16`/`s32c1i` and add `esp32s2ops`; for `esp32s3` all three add
`esp32s3ops`. (Full tables: [docs/02-xtensa-abi.md](docs/02-xtensa-abi.md).)

They also emit the **identical LLVM `target datalayout`**:

```
e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32
```

Only the target *triple* differs cosmetically (`xtensa-esp-unknown-elf` vs
`xtensa-unknown-none-elf` vs `xtensa-unknown-unknown-unknown`). Identical
datalayout is the precondition for IR-level mixing (§6).

## 3. Method

`experiments/ffi-matrix` defines one C-ABI contract (`include/ffi_abi.h`) of nine
functions chosen to hit every ABI corner: `i32`/`i64` add, `f32`/`f64` mul, small
struct (`Point`, 8 B) return + by-value, large struct (`Blob`, 24 B) return +
by-value, and an indirect callback (`apply`). Each language implements the whole
set under its own prefix (`c_`, `cpp_`, `rs_`, `zig_`). A single C `driver.c`
calls **all** of them, so every build links objects from four compilers.

Two tiers of evidence:

- **Host (x86_64)** — the driver is built with `printf` and **executed**, giving a
  runtime PASS/FAIL on actual cross-language interop.
- **Xtensa (esp32 / s2 / s3)** — freestanding objects are linked into one ELF and
  **disassembled**; we read the calling convention straight out of the machine code.

## 4. What works (the large majority)

### 4.1 Host run: all four languages interoperate

```
== c ==  ok ×9     == cpp == ok ×9     == rs == ok ×9     == zig == ok ×9
total failures: 0
RESULT: PASS (all 4 languages interop)
```

36/36 cross-language calls succeed at runtime, including struct-by-value, sret
returns, `f32`/`f64`, `i64` and C callbacks invoked from each language.

### 4.2 Xtensa: everything links, under both linkers, even mixing GCC + LLVM

For each of esp32/s2/s3 we link three ELFs and check for unresolved symbols:

| image | C from | C++/Rust/Zig from | linker | undefined |
|-------|--------|-------------------|--------|-----------|
| `ffi_llvm.elf`  | clang | LLVM | `ld.lld` | **0** |
| `ffi_mixed.elf` | **gcc** | LLVM | `ld.lld` | **0** |
| `ffi_gnuld.elf` | clang | LLVM | **GNU `ld`** | **0** |

So `ld.lld` links GCC-produced Xtensa objects, GNU `ld` links LLVM-produced
objects, and a single image can contain GCC C + clang C++ + Rust + Zig.

### 4.3 The ABI is identical in the disassembly

`add_i32` on esp32, all four toolchains use the **windowed ABI** — `entry a1,32`,
args in `a2`/`a3`, result in `a2`, `retw.n`. clang-C and clang-C++ are
byte-identical; rust and zig identical to each other; gcc differs only in
commutative operand order:

```
clang/c++:  entry a1,32 ; mov.n a7,a1 ; add.n a2,a3,a2 ; retw.n
rust/zig:   entry a1,32 ;               add.n a2,a3,a2 ; retw.n
gcc:        entry a1,32 ;               add.n a2,a2,a3 ; retw.n
```

**Callbacks** (`apply`, an indirect call) are byte-identical across C/Rust/Zig —
the windowed indirect call `callx8 a2`, outgoing args marshalled to `a10`/`a11`,
result returned in `a10`→`a2`:

```
entry a1,32 ; mov.n a11,a4 ; mov.n a10,a3 ; callx8 a2 ; mov.n a2,a10 ; retw.n
```

**`f64`** is passed in integer register pairs (`a2:a3`, `a4:a5`) and `esp32`'s
single-precision FPU is used for `f32` (`wfr`/`mul.s`/`rfr`) while `esp32s2`
falls back to `__mulsf3` — but the *ABI* (FP values in `a`-registers) is uniform,
and clang/zig generate identical `mul_f64` sequences calling `__muldf3`.

**Small structs** (`Point`, 8 B) match too: `make_point`/`point_dot` are
byte-identical between clang and zig.

**Struct *returns*** (`Blob`, 24 B) match: clang emits an explicit `sret` pointer
in `a2`; Zig returns the aggregate by value in IR, but the LLVM backend lowers
that to the *same* sret-pointer-in-`a2` convention. Zig just builds the result in
its own frame and memcpys it to the caller's buffer (less efficient, same ABI).

## 5. The one real incompatibility: under-aligned by-value struct *arguments*

This is the single place the "shared backend ⇒ shared ABI" implication leaks. The
trigger is **struct alignment, not size**, and it affects only by-value struct
*arguments* (returns are fine).

clang and rust **lower aggregates to the Xtensa C ABI in the frontend** — any
≤ 6-word struct is flattened to `[N x i32]` and passed in `a2..a7`, *regardless of
alignment*:

```llvm
define i32 @c_blob_sum([6 x i32] %0)      ; rust identical; 24-byte [24]u8 → registers
```

Zig forwards the **raw aggregate** (`i32 @zig_blob_sum(%Blob)`) and inherits
LLVM's default lowering, which only register-passes a *naturally word-aligned*
aggregate. A size×alignment sweep (`experiments/abi-structs/sweep.sh`) isolates it:

```
struct      align   clang        zig            FFI
[8]u8         1     REGISTERS    STACK (movsp)   MISMATCH    <- even 8 bytes
[16]u8        1     REGISTERS    STACK (movsp)   MISMATCH
[24]u8        1     REGISTERS    STACK (movsp)   MISMATCH
{2 x u32}     4     REGISTERS    REGISTERS       ok
{6 x u32}     4     REGISTERS    REGISTERS       ok          <- 24 bytes, fine
```

So the earlier intuition "small OK / large broken" was a confound: `Point` (8 B)
is `{i32,i32}` (align 4) and `Blob` (24 B) is `[24]u8` (align 1). At the call
site, clang stages the words in `a10..a15`; Zig does `movsp` to grow the stack and
spills the under-aligned struct to memory → a clang/rust/gcc ↔ zig call reads the
bytes from the wrong place ⇒ silent corruption on hardware. (The host test passes
only because x86_64 SysV memory-passes these structs where both agree.) Code-size
symptom: Zig's 9-function lib is **647 B** vs clang **196 B** / gcc **174 B**.

The gap is **Xtensa-specific**: the same `[8]u8` caller on RISC-V esp32c3 passes
in `a0`/`a1` for *both* clang and Zig. Root cause: Zig's experimental Xtensa
target does not yet implement the C-ABI aggregate coercion clang/rust do. Full
teardown: [docs/05-struct-abi-deep-dive.md](docs/05-struct-abi-deep-dive.md).

**Confirmed at runtime.** Running the matrix on `qemu-system-xtensa`
(`experiments/qemu-run`, `scripts/run-qemu.sh`) reproduces the prediction live:
scalars and the align-4 `Point` interoperate across all four languages, while the
align-1 `Blob` passed by value yields `zig FAIL (got=242 want=300)` — Zig misreads
the under-aligned struct on the emulated core, exactly as the disassembly says.
See [docs/08-qemu-execution.md](docs/08-qemu-execution.md).

## 6. Mixing LLVM IR across frontends — is it possible?

Yes, with a version caveat.

- **Textual IR / datalayout**: identical (§2), so the IRs are mutually
  well-formed for the same target.
- **`llvm-link`**: would merge the modules, but needs a *version-matched* tool.
  espressif's clang ships only `llc` and `ld.lld` (no `llvm-link`/`opt`); the
  host's `llvm-link` is LLVM 18 and rejects LLVM-21 IR (`getelementptr … nuw`,
  `captures(none)`, `initializes(…)`).
- **`llc`**: espressif's `llc -mcpu=esp32` consumes IR emitted by clang, rust
  **and** zig — they all feed the one backend.
- **Cross-language LTO** (the practical IR-merge path): compile to LLVM bitcode
  and let `ld.lld` merge it. **clang↔rust LTO succeeds** (both are exactly
  21.1.3) and produces a single image where C calls Rust. **clang↔zig LTO fails**
  — `ld.lld: error: … Invalid record` — because Zig's bitcode is LLVM **21.1.0**
  and the espressif LTO reader is 21.1.3. A minor-version bitcode skew, not a
  fundamental barrier. Details: [docs/04-llvm-ir-and-mixing.md](docs/04-llvm-ir-and-mixing.md).

## 7. Conclusions

1. **The shared backend buys a shared ABI for the 95% case.** Integers, floats,
   doubles, pointers, function-pointer callbacks, small structs and struct
   returns are bit-identical across clang, rust, zig and (independently) gcc.
   Cross-language FFI on Xtensa is real and practical today.
2. **Linkers are interchangeable.** lld and GNU ld each link both object
   families; GCC and LLVM objects coexist in one image.
3. **The leak is narrow and identifiable.** *Under-aligned* (`align(1)`,
   e.g. byte-array/packed) by-value struct *arguments* are mishandled by Zig's
   experimental Xtensa target — at any size, and Xtensa-only. Word-aligned
   structs (the common case) are fine; otherwise pass them **by pointer**.
4. **IR is portable; tooling versions are the gotcha.** Identical datalayout
   makes IR mixing sound in principle; in practice keep the `llvm-link`/LTO tool
   at the *same* LLVM version as the bitcode producers.

## 8. Practical FFI guidance for ESP32 polyglot projects

- Stick to the C ABI (`extern "C"` / `#[no_mangle]` / `export fn`) — done here.
- Scalars, pointers, enums, callbacks, word-aligned structs: free to cross any boundary.
- On boundaries that touch Zig, keep by-value structs **word-aligned**, or pass
  **under-aligned/packed/byte-array structs by pointer** (returns are already safe).
- For cross-language LTO, build every participant with the *same* LLVM point
  release, or don't LTO across the mismatched one.
- GCC interoperates fine at the object/link level; you don't have to go all-LLVM.

See [HANDOFF.md](HANDOFF.md) for status and follow-up ideas (qemu execution of
the Xtensa images, a 16 B boundary sweep, espidf targets, RISC-V ESP32-C cores).
