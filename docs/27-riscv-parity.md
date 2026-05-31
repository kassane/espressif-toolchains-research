# 27 — RISC-V parity for zero-cost (docs/25), TMP (docs/26), and SIMD (docs/16)

The last three PRs (#27/#28/parent) established Xtensa esp32 baselines for
zero-cost abstractions, template-metaprogramming feature surface, and SIMD.
This doc extends each to the **RISC-V branch of the ESP chip family**:
**esp32c3** (rv32imc, single-core, no SIMD) and **esp32p4** (rv32imafc,
dual-core with Espressif vendor PIE/ESPV vector extensions).

Reproduce with:

```bash
experiments/zero-cost/run.sh  {esp32|esp32c3|esp32p4}
experiments/tmp-parity/run.sh {esp32|esp32c3|esp32p4}
experiments/simd/run.sh       # always runs xtensa s3 + riscv p4 (the two ESP SIMD chips)
```

All script output below is real.

## TL;DR

1. **Zero-cost and TMP results are ISA-portable.** The IR-level optimization
   is frontend work, runs before backend selection; every monomorphization /
   inlining / CTFE / constexpr / static-if conclusion from docs/25-26 holds
   identically on rv32imc esp32c3 and rv32imafc esp32p4. The absolute insn
   and byte counts differ because the ABIs differ, but the "what disappeared"
   table is preserved.
2. **esp32p4 has a vendor SIMD unit; esp32c3 doesn't.** The esp32p4 unit is
   the Espressif PIE/ESPV vector extension — `xespv` (v2.2) on plain
   esp32p4, `xespv1v` (v2.1) on esp32p4eco4, plus `xesploop`
   (zero-overhead loops) on both. q0..q? + qacc/xacc 128-bit regs, same
   model as xtensa s3 EE.* but riscv `esp.*` mnemonics.
3. **ESPV 2.1 and 2.2 are wire-incompatible.** The publicly-documented 412
   mnemonics belong to ESPV 2.1 (esp32p4eco4). esp32p4 (ESPV 2.2) uses
   different opcode tables whose spellings aren't yet public. **Use
   `-mcpu=esp32p4eco4` for any inline-asm work today.**
4. **All four LLVM frontends — clang, zig, LDC, rustc — produce
   byte-identical esp32p4 SIMD encodings via inline asm.** The libLLVM
   RISC-V assembler is shared across them.
5. **No frontend ships esp32p4 SIMD intrinsics.** `riscv_vector.h` requires
   the standard V extension that esp32p4 doesn't enable. Only `asm volatile`
   access path, same situation s3 EE.* was in before the public helper
   macros existed.

## Toolchain matrix for RISC-V ESP targets

| frontend | esp32c3 (rv32imc) | esp32p4 (rv32imafc) | esp32p4 SIMD asm |
|---|---|---|---|
| **esp-clang 21.1.3** | `--target=riscv32-esp-elf -mcpu=esp32c3` | `--target=riscv32-esp-elf -mcpu=esp32p4` | yes; `-mcpu=esp32p4eco4` for ESPV 2.1 mnemonics |
| **LDC 1.42.0** (LLVM 22.1.4) | `-mtriple=riscv32-unknown-none-elf -mattr=+m,+c` | `-mtriple=riscv32-unknown-none-elf -mattr=+m,+a,+f,+c` | `-mattr=+m,+a,+f,+c,+xespv1v,+xesploop` |
| **Zig 0.17.0-xtensa** | `-target riscv32-freestanding-none -mcpu=esp32c3` | `-target riscv32-freestanding-none -mcpu=esp32p4` | `-mcpu=esp32p4eco4` |
| **rustc 1.95-nightly** | `--target riscv32imc-unknown-none-elf` | `--target riscv32imafc-unknown-none-elf` | `-C target-cpu=esp32p4eco4` |

All four frontends accept their target's CPU name (or recognize the rv32 base
ISA via `-mattr=`/`-mcpu=generic_rv32`). LDC uniquely has no riscv CPU model
names and must enumerate features with `-mattr`. Rust currently has no
`riscv32imafc-esp-elf` target — `riscv32imafc-unknown-none-elf` + `-C
target-cpu=esp32p4eco4` is the working combination.

compiler-rt builtins for both targets ship under
`/home/user/toolchains/esp-clang/lib/clang-runtimes/riscv32-esp-unknown-elf/`
(esp-clang ships `rv32imc-…`, `rv32imafc-…`, and many `…_no-rtti` variants).

## §a — Zero-cost abstractions on RISC-V (extends docs/25)

The four scenarios from docs/25 cross-compiled to esp32c3:

```
== (a) Generic accumulator (sum) ==
  C   sum_c                          10 insn  24 B
  C++ sum_cpp_loop                   10 insn  24 B
  C++ sum_cpp_tmpl<int>              10 insn  24 B
  Rust sum_rs_loop                   10 insn  24 B (ICF-merged)
  Rust sum_rs_iter                   12 insn  26 B  ← lone outlier
  Rust sum_rs_generic<T>             10 insn  24 B
  D   sum_d_loop                     10 insn  24 B
  D   sum_d_tmpl!(int)               10 insn  24 B

== (b) Higher-order (apply f) ==
  ALL FORMS                          2 insn   4 B   (= slli a0, a0, 1 ; ret)

== (c) Static vs dynamic dispatch ==
  C++ static_via_template            6 insn   18 B
  C++ virtual_via_class             20 insn   42 B  (+14 insn / +24 B)
  Rust impl_trait_static             6 insn   18 B
  Rust dyn_trait_dynamic            21 insn   44 B  (+15 insn / +26 B)
  D struct-template static           6 insn   18 B

== (d) Heap allocation ==
  C++ Counter_cpp_new               14 insn  34 B
  Rust Box<Counter>                 14 insn  34 B
  D Counter (extern(C++) class)     14 insn  34 B
  D CounterStruct (value type)       3 insn   6 B   ← smallest of all
```

Cross-ISA comparison (esp32 xtensa → esp32c3 riscv):

- **§a sum**: xtensa 10-11 / 23-25 B; riscv 10-12 / 24-26 B. Same monomorph
  story; riscv is +1 B per function because rv32imc uses 4-byte `addi` for
  the literal counter inits where xtensa's `movi.n` is 2 bytes.
- **§b apply**: xtensa 3-4 insn; riscv 2 insn. **riscv is TIGHTER** because
  xtensa's register-window `entry/retw.n` pair costs ~6 B of frame setup;
  riscv has no register windows and the function body is literally
  `slli a0, a0, 1 ; ret`.
- **§c dispatch**: vtable cost is ~+14 insn / +24 B on riscv, vs ~+6 insn /
  +14 B on xtensa. Wider gap because riscv's indirect call (`jalr ra, rt, 0`)
  is 4 B and the vtable read needs `lw` + offset arithmetic, while xtensa
  packs more into each instruction.
- **§d heap**: xtensa 10-11 insn; riscv 14 insn. Heavier on riscv because
  `malloc(sizeof)` is one `addi a0, zero, 8` + `auipc/jalr` pair vs xtensa's
  `movi.n a10, 8 ; callx8 malloc`. D struct value-type: **riscv beats
  xtensa** (3 / 6 B vs 4 / 9 B) — fewer instructions to load + return a
  small value through a0/a1 than through xtensa's a2/a3 + register-window.

**Verdict**: every "zero-cost abstraction" claim from docs/25 holds on
RISC-V. The numbers shift because the ABIs and encodings shift; the
*relative* costs (static = free, dynamic = +14 insn, heap = ~14 insn) are
preserved.

## §b — TMP feature parity on RISC-V (extends docs/26)

The full 12-capability matrix from docs/26 reaches identical IR on all three
RISC-V targets. Every CTFE / constexpr / variadic-fold reduces to the same
constant:

```
== (e) Compile-time computation (fact(5) → 120) — esp32c3 ==
  cpp get_fact5_cpp  (2 insn)
                0: 07800513     	li	a0, 0x78
                4: 8082         	ret
  d   get_fact5     (2 insn)
                0: 07800513     	li	a0, 0x78
                4: 8082         	ret
  rs  get_fact5_rs  (2 insn)
                0: 07800513     	li	a0, 0x78
                4: 8082         	ret

== (g) Variadic (static_sum(10,20,12) → 42) ==
  cpp variadic_42_cpp:  li a0, 0x2a ; ret
  d   variadic_42:      li a0, 0x2a ; ret
  rs  variadic_42_rs:   li a0, 0x2a ; ret
```

Byte-identical across the three LLVM frontends. The same body on xtensa is 3
instructions (`entry ; movi a2, 120 ; retw.n`) because of the
register-window prologue/epilogue. On riscv there's no entry/retw, just `li
; ret`. *This shrinks every leaf function by 1-2 insns vs xtensa* — a
systemic ABI win, not a TMP-specific one.

The TMP feature SURFACE (which language supports which capability) is
target-independent; refer to docs/26 §a-h for the catalog.

## §c — esp32p4 vendor SIMD (extends docs/16 / experiments/simd/)

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
Subfamilies cataloged in the agent research; representative examples:

| subfamily | examples |
|---|---|
| vector load/store | `esp.vld.128.{ip,xp}`, `esp.vst.128.{ip,xp}`, `esp.vldbc.{8,16,32}.{ip,xp}` (broadcast), `esp.vldext.{s,u}{8,16}.{ip,xp}` (load-extend) |
| vector ALU | `esp.vadd.{s,u}{8,16,32}`, `esp.vsub`, `esp.vmul`, `esp.vmax/vmin`, `esp.vclamp`, `esp.vrelu`/`vprelu`, `esp.vsadds`/`vssubs` (saturating), `esp.vsl/vsr` (shifts) |
| complex / DSP | `esp.cmul.{s,u}{8,16}`, `esp.cmulas`, `esp.macs16x{1,2}`, `esp.macs32`, `esp.muls32` |
| FFT (the standout) | `esp.fft.ams.s16.*`, `esp.fft.bitrev`, `esp.fft.cmul.s16.*`, `esp.fft.r2bf.s16` (radix-2 butterfly), `esp.fft.vst.r32.decp` |
| accumulator / state | `esp.zero.q`, `esp.zero.qacc`, `esp.ldqa.{s,u}{8,16}.128.{ip,xp}`, `esp.ld.qacc.{l,h}.{l,h}.128.ip` |
| hardware loops | `esp.lp.setup`, `esp.lp.setupi`, `esp.lp.endi`, `esp.lp.count` |

Full taxonomy: 412 mnemonics extracted from `libLLVM.so.21.1` strings for
ESPV 2.1 / esp32p4eco4. ESPV 2.2 spellings are not yet publicly documented.

### Cross-frontend parity probe

Same five-instruction kernel (vld×2 → vadd → vst → ret), four frontends:

```c
// experiments/simd/esp.c
void esp_add(signed char* d, const signed char* a, const signed char* b){
  __asm__ volatile(
    "esp.vld.128.ip q0, %1, 0\n"
    "esp.vld.128.ip q1, %2, 0\n"
    "esp.vadd.s8    q2, q0, q1\n"
    "esp.vst.128.ip q2, %0, 0\n"
    : : "r"(d), "r"(a), "r"(b) : "memory");
}
```

Encoding output from `experiments/simd/run.sh`:

```
clang 0201a03b | 0202243b | 065f 06a0 283b | 8201 | 8082
zig   0201a03b | 0202243b | 065f 06a0 283b | 8201 | 8082
d     0201a03b | 0202243b | 065f 06a0 283b | 8201 | 8082
rs    0201a03b | 0202243b | 065f 06a0 283b | 8201 | 8082
```

**Byte-identical across clang / zig / LDC / rust.** Same parity result the
xtensa s3 EE.* block produced in `experiments/simd/run.sh §3+§5` — the
libLLVM RISC-V assembler is shared across all four frontends, so inline-asm
encodings match by construction.

The disassembler is incomplete: it renders the third encoding `065f 06a0
283b` (the 6-byte `esp.vadd.s8 q2, q0, q1`) as `<unknown>`, and the fourth
`8201` (which is the assembled `esp.vst.128.ip q2, %0, 0`) as `c.srli64
a2`. These are pretty-printer bugs in LLVM 21's RISC-V disasm path, not
codegen issues — the bytes are correct (verified by hand-assembling against
the ESPV 2.1 opcode table) and the frontends all agree on them.

### Autovec + explicit vector types

Same null result as xtensa s3:

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

### ESPV revision mismatch

```
== 7.4 esp32p4 (ESPV 2.2) rejects esp.vadd.s8:
    'instruction requires the following: Espressif ESPV 2.1'
   → ESPV 2.1 / 2.2 are wire-incompatible opcode tables.
```

The mainstream esp32p4 chip uses ESPV 2.2; the documented mnemonics are
ESPV 2.1 (esp32p4eco4 only). Until Espressif publishes the ESPV 2.2 spec
or LLVM picks up alternative spellings, **use `-mcpu=esp32p4eco4` for any
inline-asm work** to get the 412-mnemonic surface this experiment exercises.

### esp32c3 has no SIMD

```
== 7.5 esp.* on esp32c3 -> assembler rejects:
    'instruction requires the following: Espressif ESPV 2.1/2.2'
   → matches xtensa: vendor SIMD only on the chip that has the unit.
```

Same selectivity as the EE.* probe on esp32 (LX6 has no SIMD; only s3 does).
The matrix is symmetric: vendor SIMD is per-chip, not per-architecture.

### No intrinsic headers

```
$ find /home/user/toolchains/esp-clang/lib/clang -name "esp_pie*" -o -name "*xespv*"
(empty)
$ grep -l "xespv\|esp\.vld" /home/user/toolchains/esp-clang/lib/clang/21/include/*.h
(empty)
```

esp-clang ships generic riscv intrinsic headers (`riscv_vector.h`,
`riscv_bitmanip.h`, `riscv_corev_alu.h`, `riscv_crypto.h`, vendor
`andes_vector.h`, `sifive_vector.h`) but **no esp32p4 / esp_pie /
xespv header**. `riscv_vector.h` can't be used either: its bodies gate on
`__riscv_v_intrinsic` + the standard `V`/`Zve*` feature, and `vsetvli`
rejects with `'V' / 'Zve32x' required` on esp32p4. esp32p4 enables
`__riscv_xespv=2002000` macro but no header consumes it.

**Implication**: `asm volatile("esp.*")` is the ONLY emittable path today
for esp32p4 PIE. Same situation xtensa s3 EE.* was in before public helper
macros appeared. A vendor-supplied `esp_pie.h` would be the cleanest fix.

### tinygo coverage

TinyGo v0.41.1 ships an `esp32p4` device-tree register definition file
(`device/esp/esp32p4.go`) — peripheral SVD bindings only, no ESPV asm
emission. TinyGo bundles LLVM 20.1.1 which predates esp-clang's 21.1.3
RISC-V vendor extension support; even if you tried `import "esp32p4"`
through TinyGo's `device/esp` package, the only access is to MMIO
registers, not the vector unit. TinyGo remains outside the SIMD probe matrix
for the same reason it's outside the FFI matrix (docs/24).

## ABI implications observed in passing

A few RISC-V-ABI quirks the riscv runs of the existing experiments make
visible:

1. **No register windows** — rv32 functions don't carry an `entry/retw`
   pair, so every leaf function is 1-2 insns shorter than its xtensa peer.
   The riscv ABI passes args + return in `a0..a7` (no per-call rotation).
2. **2/4-byte instruction encoding** — `c.*` compressed instructions are
   2 bytes; non-compressed are 4 bytes (vs xtensa's 2/3 byte split). The
   bytes-per-function totals shift accordingly.
3. **`li` macro expansion** — `li a0, K` for K outside ±2KB expands to
   `lui a0, hi(K) ; addi a0, a0, lo(K)` (8 bytes total). `0x78` fits in
   12-bit imm so it stays 4 bytes. This makes the riscv `fact(5)` and
   `static_sum(42)` returns slightly tighter than xtensa where every
   const-return is `movi a2, K ; retw.n` (5-6 bytes).
4. **Vendor-extension MCA gap** — LLVM's RISC-V Machine Code Analyzer
   (`llvm-mca`) has no cost model for `Xespv` ops yet, so cycle counting
   the ESPV kernels needs manual lookup against the ESPV 2.1 ISA manual.

## Related docs

- docs/16 — original SIMD probe on xtensa s3 EE.*; this doc's §c is its
  riscv twin.
- docs/25 — zero-cost abstractions; this doc's §a is its riscv twin.
- docs/26 — TMP feature parity; this doc's §b confirms it holds on riscv.
- docs/09 — RISC-V baseline (esp32c3) FFI matrix overview from before this
  riscv extension; this doc adds the esp32p4 vendor SIMD layer.
- docs/24 — TinyGo standalone matrix (excluded from this doc's RISC-V SIMD
  probe; LLVM 20 backend, no esp.* asm support).
