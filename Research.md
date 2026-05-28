# Cross-language FFI on Xtensa via the shared espressif/llvm-project backend

A study of how far the *shared LLVM Xtensa backend* takes us toward a *shared
ABI* between Zig, Rust, D and C/C++ on ESP32-class chips — and where it breaks.

All numbers, disassembly and IR in this document were produced on an x86_64
Linux host from the six toolchains pinned in [docs/01-toolchains.md](docs/01-toolchains.md).
Everything here is reproducible with `scripts/build-ffi.sh` + `scripts/analyze.sh`.

---

## 1. Hypothesis

`espressif/llvm-project` carries the production Xtensa target. **Five
language frontends** now ride an LLVM with that backend:

- **clang** — espressif's LLVM directly (`clang` 21.1.3).
- **rustc** — esp-rs ships a rustc built against the same LLVM (1.95-nightly, *LLVM 21.1.3*).
- **zig** — kassane's `zig-espressif-bootstrap` builds Zig against the same LLVM (0.16.0, *clang/LLVM 21.1.0*).
- **D / LDC** — `kassane/esp-idf-dlang` ships LDC 1.42-git built against the
  same espressif LLVM 21.1.3 (`-betterC` for bare-metal). Joined the fork in
  docs/23, dropping five workarounds. The upstream-LLVM-22 LDC stays as
  `$LDC2_UPSTREAM` for the side-by-side. Deep dive: [docs/19](docs/19-dlang-ldc.md).
- **TinyGo** — v0.41.1 bundles its own LLVM 20.1.1 fork (`tinygo-org/llvm-project`)
  and targets esp32 + esp32s3 + esp32c3 (no s2). Whole-program compiler,
  doesn't co-link with the rest; explored standalone in [docs/24](docs/24-tinygo.md).

Every LLVM frontend requires some fork of LLVM (four on the espressif fork,
TinyGo on its own bundled fork). Stock upstream LLVM's Xtensa is still
experimental (esp32/esp8266 only). `esp-rs/rust` is a fork of rustc (stock has
Tier-3 target *specs* only). Upstream Zig 0.16 has no esp32 CPU; 0.17.0 ships
it (Zig #5467 *closed* May 2026, milestone 0.17.0). "Shared backend" throughout
this report means *the espressif LLVM fork* (TinyGo's matching-datalayout
LLVM-20 fork joins the IR-comparison axis but not the linking axis).

A sixth toolchain, **GCC 15.2** from `espressif/crosstool-NG`, shares *no* code
with LLVM and acts as an independent control for ABI questions.

If "shared backend ⇒ shared ABI" held strictly, the six should interoperate
perfectly. The interesting part is exactly where that implication leaks.

## 2. The backend really is shared

The four espressif-LLVM frontends expose the **identical Xtensa CPU feature
model**. For `esp32`, `rustc --print cfg`, clang's `target-features` attribute,
`zig build-obj --show-builtin` and LDC's `-mattr` all enumerate the same set
(`+fp,+windowed,+mac16,+loop,+s32c1i,+density,…`). For `esp32s2` all drop
`fp`/`loop`/`mac16`/`s32c1i` and add `esp32s2ops`; for `esp32s3` all add
`esp32s3ops`. TinyGo's bundled LLVM 20 diverges slightly
(`+atomctl/+memctl/+timerint` extra; `+dcache/+expstate/+highpriinterrupts-level7/+mul16/+timers3`
absent) but agrees on every codegen-relevant essential. (Full tables:
[docs/02-xtensa-abi.md](docs/02-xtensa-abi.md), [docs/24](docs/24-tinygo.md) §b.)

Every LLVM frontend emits the **byte-identical LLVM `target datalayout`**:

```
e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32
```

Only the target *triple* differs cosmetically (`xtensa-esp-unknown-elf` vs
`xtensa-unknown-none-elf` vs `xtensa-unknown-unknown-unknown` vs bare `xtensa`).
The upstream-LLVM-22 LDC used to differ (`…i8:8:32-i16:16:32…`, no
`v1:8:8`/`i128:128`) — that one historical mismatch is preserved in
[docs/23](docs/23-ldc-espressif-fork.md) §e for the comparison toolchain.
A compatible datalayout is the precondition for IR-level mixing (§6).

## 3. Method

`experiments/ffi-matrix` defines one C-ABI contract (`include/ffi_abi.h`) of nine
functions chosen to hit every ABI corner: `i32`/`i64` add, `f32`/`f64` mul, small
struct (`Point`, 8 B) return + by-value, large struct (`Blob`, 24 B) return +
by-value, and an indirect callback (`apply`). Each language implements the whole
set under its own prefix (`c_`, `cpp_`, `rs_`, `zig_`, `d_`). A single C `driver.c`
calls **all** of them, so every build links objects from five compilers.

Two tiers of evidence:

- **Host (x86_64)** — the driver is built with `printf` and **executed**, giving a
  runtime PASS/FAIL on actual cross-language interop.
- **Xtensa (esp32 / s2 / s3)** — freestanding objects are linked into one ELF and
  **disassembled**; we read the calling convention straight out of the machine code.

## 4. What works (the large majority)

### 4.1 Host run: every FFI-matrix language interoperates

```
== c == ok ×9   == cpp == ok ×9   == rs == ok ×9   == zig == ok ×9   == d == ok ×9
total failures: 0
RESULT: PASS (all 5 languages interop)
```

45/45 cross-language calls succeed at runtime, including struct-by-value, sret
returns, `f32`/`f64`, `i64` and C callbacks invoked from each language. (On the
x86_64 host D follows the SysV ABI and passes everything, incl. by-value structs;
its Xtensa/RISC-V struct-arg divergence is a backend-lowering issue — §5.)

### 4.2 Xtensa: everything links, under both linkers, even mixing GCC + LLVM

For each of esp32/s2/s3 we link three ELFs and check for unresolved symbols:

| image | C from | C++/Rust/Zig/D from | linker | undefined |
|-------|--------|---------------------|--------|-----------|
| `ffi_llvm.elf`  | clang | LLVM | `ld.lld` | **0** |
| `ffi_mixed.elf` | **gcc** | LLVM | `ld.lld` | **0** |
| `ffi_gnuld.elf` | clang | LLVM | **GNU `ld`** | **0** |

So `ld.lld` links GCC-produced Xtensa objects, GNU `ld` links LLVM-produced
objects, and a single image can contain GCC C + clang C++ + Rust + Zig + D.
(D's object needs a literal-pool re-assembly with esp clang — a real LDC-Xtensa
bug, docs/19 — but then links cleanly with the rest.)

### 4.3 The ABI is identical in the disassembly

`add_i32` on esp32, every FFI-matrix toolchain uses the **windowed ABI** — `entry a1,32`,
args in `a2`/`a3`, result in `a2`, `retw.n`. clang-C and clang-C++ are
byte-identical; rust and zig identical to each other; D matches the same windowed
convention (docs/19); gcc differs only in commutative operand order:

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

## 5. Where it leaks: by-value struct *arguments* on the defer-to-backend frontends

This is where the "shared backend ⇒ shared ABI" implication leaks — on the two
frontends (**Zig** and **D/LDC**) that hand aggregates to the LLVM backend
instead of coercing them to the Xtensa C ABI in the frontend like clang/rust do.
For Zig the trigger is **struct alignment, not size**, and it affects only
by-value struct *arguments* (returns are fine); D is broader (§5.1).

clang and rust **lower aggregates to the Xtensa C ABI in the frontend** — any
≤ 6-word struct is flattened to `[N x i32]` and passed in `a2..a7`, *regardless of
alignment*:

```llvm
define i32 @c_blob_sum([6 x i32] %0)      ; rust identical; 24-byte [24]u8 → registers
```

Zig forwards the **raw aggregate** (`i32 @zig_blob_sum(%Blob)`) and inherits
LLVM's default lowering, which only register-passes a *naturally word-aligned*
aggregate. A size×alignment sweep (`experiments/abi-structs/sweep.sh`)
isolates it; the extended sweep also covers D and C-style bitfields:

```
struct           align  clang IR arg | clang        zig            D            FFI
[8]u8              1    [2 x i32]    | REGISTERS    STACK (movsp)  REGISTERS    MISMATCH (zig)
[16]u8             1    [4 x i32]    | REGISTERS    STACK (movsp)  REGISTERS    MISMATCH (zig)
[24]u8             1    [6 x i32]    | REGISTERS    STACK (movsp)  REGISTERS    MISMATCH (zig)
{2 x u32}          4    [2 x i32]    | REGISTERS    REGISTERS      REGISTERS    ok
{6 x u32}          4    [6 x i32]    | REGISTERS    REGISTERS      REGISTERS    ok          <- 24 bytes, fine

bf 16b(4+4+8)      2    i32          | REGISTERS    REGISTERS      REGISTERS    D-IR=byval(%s.T)
bf 32b(8+8+16)     4    i32          | REGISTERS    REGISTERS      REGISTERS    D-IR=byval(%s.T)
bf 64b(32+32)      8    [1 x i64]    | REGISTERS    REGISTERS      REGISTERS    D-IR=byval(%s.T)
```

clang flattens bitfields to their scalar backing type and Zig matches when
you give `packed struct(uN)` an explicit backing integer; D wraps every
bitfield struct as `byval(%s.T)` at the IR level, same as every other
aggregate — confirming D's struct-ABI bug is universal (docs/05/19).

So the earlier intuition "small OK / large broken" was a confound: `Point` (8 B)
is `{i32,i32}` (align 4) and `Blob` (24 B) is `[24]u8` (align 1). At the call
site, clang stages the words in `a10..a15`; Zig does `movsp` to grow the stack and
spills the under-aligned struct to memory → a clang/rust/gcc ↔ zig call reads the
bytes from the wrong place ⇒ silent corruption on hardware. (The host test passes
only because x86_64 SysV memory-passes these structs where both agree.) Code-size
symptom: Zig's 9-function lib is **715 B** of `.text` vs clang **223 B** / gcc
**201 B** (real `.text` via `llvm-size -A`; docs/06/15).

Root cause: Zig's experimental ESP targets don't implement the C-ABI aggregate
coercion clang/rust do; they defer to LLVM's default lowering. This is **not
Xtensa-only** — RISC-V (ESP32-C3) has a *different* Zig struct-arg bug: the small
`{i32,i32}` `Point` is mis-lowered to `[2 x i64]` (wrong registers), even though
the large `[24]u8` is fine there (by reference). The RISC-V case reproduces on
*upstream* Zig too (`pip install ziglang`), so it is an upstream Zig frontend bug,
not the espressif fork. Rust, clang and gcc are correct on both architectures.
Full teardown: [docs/05](docs/05-struct-abi-deep-dive.md),
[docs/09](docs/09-riscv.md), [docs/10](docs/10-zig-rust-parity.md).

### 5.1 D/LDC: the same root cause, broader

D goes further than Zig: LDC marks **every** by-value aggregate `byval(ptr)` and
**every** struct return `sret` — *explicitly indirect* in the IR — then defers to
the backend, whose Xtensa lowering passes them in **memory**, not the C ABI's
registers. So D diverges for *every* register-passed struct, not just
under-aligned ones: on Xtensa both the align-4 `Point` (`point_dot`) **and** the
align-1 `Blob` (`blob_sum`) fail, plus the 8-byte struct *return* (`make_point`,
which clang returns in `a2:a3` but D returns via a hidden pointer). The only
struct case D gets right is the >16-byte `sret` return — where the C ABI is
*also* indirect. On RISC-V the asymmetry confirms the cause: D's small struct is
passed as a real pointer and **faults**, while the large `Blob` *passes* (the
RISC-V C ABI itself passes >16 B by reference, so D's `byval` matches). Host
(x86_64 SysV) interop is perfect, so this is a backend-lowering issue, not a
D-language one. Full teardown: [docs/19](docs/19-dlang-ldc.md).

**Confirmed at runtime.** The matrix runs on qemu (`scripts/run-qemu.sh`):
on `qemu-system-xtensa` the align-1 `Blob` gives `zig FAIL (got≈242 want=300)` and
D fails both `point_dot` and `blob_sum`; on `qemu-system-riscv32` the `Point`
gives `zig FAIL (got=-2130706553 want=11)` (D's `point_dot` faults there, so it's
gated) while `Blob` passes for both. Passing the same struct **by pointer** works
for every FFI-matrix language. All match the disassembly. See
[docs/08](docs/08-qemu-execution.md), [docs/19](docs/19-dlang-ldc.md).

## 6. Mixing LLVM IR across frontends — is it possible?

Yes, with a version caveat.

- **Textual IR / datalayout**: identical (§2), so the IRs are mutually
  well-formed for the same target.
- **`llvm-link`**: merges the modules into one — *now demonstrated*. espressif's
  clang ships only `llc`/`ld.lld` (no `llvm-link`/`opt`/`llvm-dis`), and the host's
  are LLVM 18 and reject LLVM-21 IR (`getelementptr … nuw`, `captures(none)`,
  `initializes(…)`). Adding the matching **LLVM 22.1.2 binutils** (the LLVM LDC is
  built on; `setup.sh LLVM22=1`) reads all of it and **merges every LLVM frontend's
  IR into one 42-function module**; `opt -O2` then inlines across the merge.
- **`llc`**: espressif's `llc -mcpu=esp32` consumes IR emitted by clang, rust
  **and** zig — they all feed the one backend. (Upstream LLVM-22's `llc` lacks the
  `esp32` CPU, so esp32 *codegen* of merged/22 IR still needs the espressif backend.)
- **Cross-language LTO** (the practical IR-merge path): compile to LLVM bitcode
  and let `ld.lld` merge it. **clang↔rust LTO succeeds** (both 21.1.3) and — more
  surprisingly — **clang↔D succeeds** too (the esp 21.1.3 LTO reader accepts LDC's
  LLVM **22.1.2** bitcode and inlines across the boundary). **clang↔zig LTO fails**
  — `ld.lld: error: … Invalid record` — because Zig's bitcode is LLVM **21.1.0**.
  So bitcode skew is not a simple "must match" rule. Details:
  [docs/04-llvm-ir-and-mixing.md](docs/04-llvm-ir-and-mixing.md).

## 7. Conclusions

1. **The shared backend buys a shared ABI for the 95% case.** Integers, floats,
   doubles, pointers, function-pointer callbacks, small structs and struct
   returns interoperate across clang, rust, zig, D and (independently) gcc — host
   runtime PASS for every FFI-matrix language, identical windowed convention in the disassembly.
   Cross-language FFI on Xtensa is real and practical today.
2. **Linkers are interchangeable.** lld and GNU ld each link both object
   families; GCC and LLVM (clang/rust/zig/D) objects coexist in one image.
3. **The leaks are by-value struct *arguments* on the two defer-to-backend
   frontends.** **Zig** — Xtensa under-aligned (`align(1)`) structs stack-spilled,
   RISC-V small `{i32,i32}` mis-lowered to `[2 x i64]` (reproduces on upstream
   Zig). **D/LDC** — marks every aggregate `byval`/`sret`, so it diverges for
   *all* register-passed structs + small-struct returns (broader than Zig).
   Rust/clang/gcc are correct everywhere. Confirmed live on qemu (xtensa + riscv).
4. **IR is portable; tooling versions are the gotcha.** A compatible datalayout
   makes IR mixing sound; with the matching LLVM-22 binutils `llvm-link` merges
   every LLVM frontend, while the *LTO* reader is pickier (accepts clang/rust 21.1.3
   and D 22.1.2, rejects zig 21.1.0) — "same LLVM version" is a rule of thumb, not
   absolute.

## 8. Practical FFI guidance for ESP32 polyglot projects

- Stick to the C ABI (`extern "C"` / `#[no_mangle]` / `export fn`) — done here.
- Scalars, pointers, enums, callbacks, and struct *returns*: free to cross any boundary.
- On any boundary that touches **Zig or D** (Xtensa or RISC-V), pass by-value
  structs **by pointer** — Zig mishandles different by-value struct-arg cases on
  each arch, and D mishandles every register-passed struct + small-struct return.
  Rust↔C/clang/gcc need no such caveat.
- For cross-language LTO, build every participant with the *same* LLVM point
  release, or don't LTO across the mismatched one.
- GCC interoperates fine at the object/link level; you don't have to go all-LLVM.

See [HANDOFF.md](HANDOFF.md) for status and follow-up ideas (qemu execution of
the Xtensa images, a 16 B boundary sweep, espidf targets, RISC-V ESP32-C cores).
