# 05 — Deep dive: the struct-argument ABI divergence (alignment, not size)

This is the one place the shared backend does **not** give a shared ABI. It is
subtle: the trigger is **struct alignment**, not struct size, and it only affects
by-value struct *arguments* (returns are fine).

## The discriminator is alignment

`experiments/abi-structs/sweep.sh` forwards a by-value struct to an external
function and classifies how clang vs zig pass it on esp32:

```
struct        align  clang IR arg   | clang        zig            FFI
[8]u8           1     [2 x i32]      | REGISTERS    STACK (movsp)  MISMATCH
[16]u8          1     [4 x i32]      | REGISTERS    STACK (movsp)  MISMATCH
[24]u8          1     [6 x i32]      | REGISTERS    STACK (movsp)  MISMATCH
{2 x u32}       4     [2 x i32]      | REGISTERS    REGISTERS      ok
{6 x u32}       4     [6 x i32]      | REGISTERS    REGISTERS      ok
```

- **align-1 byte arrays diverge at every size — even 8 bytes.**
- **align-4 structs match at every size — even 24 bytes.**

So the earlier intuition "small structs OK, large structs broken" was a
confound: our `Point` (8 B) is `{i32,i32}` (align 4) and our `Blob` (24 B) is
`[24]u8` (align 1). Size was never the variable; **alignment is.**

## What clang/rust/gcc do

They implement the Xtensa C ABI in the frontend: any aggregate of ≤ 6 words is
flattened to `[N x i32]` and passed in `a2..a7`, **regardless of alignment**.

```llvm
define i32 @c_blob_sum([6 x i32] %0)      ; rust identical; 24-byte [24]u8 → registers
```

## What Zig does

Zig forwards the raw `extern struct` to LLVM (`i32 @zig_blob_sum(%Blob)`) and
inherits LLVM's default calling-convention lowering. That default only passes the
aggregate in registers when it is naturally word-aligned; an under-aligned
(align-1) aggregate is passed in memory.

### Proof at the call site (8-byte structs, `experiments/abi-structs`)

`[8]u8` (align 1) — clang registers, Zig stack:

```
clang caller:                          zig caller:
  entry a1,32                            entry a1,32
  mov.n a11,a3 ; mov.n a10,a2            mov.n a10..a15 (stage)
  callx8 <ext>                           addi a9,a1,-8 ; movsp a1,a9   ; grow stack
                                         l8ui/s32i  spill 2 words to a1+0,a1+4
                                         callx8 <ext> ; movsp a1,+8 (restore)
```

`{u32,u32}` (align 4, *same 8 bytes*) — clang and Zig **byte-identical**:

```
entry a1,32 ; mov.n a11,a3 ; mov.n a10,a2 ; callx8 <ext> ; mov.n a2,a10 ; retw.n
```

A clang/rust/gcc ↔ zig call with an **under-aligned by-value struct argument**
reads the bytes from the wrong place ⇒ silent corruption on hardware. Word-aligned
structs are safe. (The host test in doc 03 passes regardless because x86_64 SysV
memory-passes these structs in a way both sides agree on.)

## Struct *returns* are fine even when under-aligned

`make_blob` returns `[24]u8` (align 1). clang uses an explicit `sret` pointer in
`a2`; Zig returns by value in IR but the backend lowers it to the *same* sret
convention (Zig just builds the value in its frame then copies it to the caller's
buffer). Compatible — the divergence is specific to under-aligned *arguments*.

## Not Xtensa-only — RISC-V has a *different* Zig struct bug

This particular manifestation (under-aligned arg → stack) is Xtensa-specific: the
same `[8]u8` caller on RISC-V esp32c3 passes by reference in `a0` for both clang
and Zig. **But RISC-V is not bug-free for Zig** — there the *small* `{i32,i32}`
`Point` is mis-lowered to `[2 x i64]` (wrong registers), which the Xtensa path
handles correctly. So Zig's experimental ESP targets each have a by-value
struct-argument gap, just in different cases; Rust/clang/gcc are correct on both.
The RISC-V case even reproduces on upstream Zig. See
[docs/09](09-riscv.md) and [docs/10](10-zig-rust-parity.md). The common root is
that Zig defers aggregate ABI to LLVM's default instead of implementing the
platform C ABI in the frontend (which clang and rust both do). This is an
**upstream Zig** gap, not the espressif fork: `kassane/zig-espressif-bootstrap`
patches only LLVM/LLD/Clang (no Zig `src/` changes), and Xtensa is still being
finalized upstream under `ziglang/zig` #5467 (**CLOSED 2026-05-06**, milestone 0.17.0). See
[docs/17](17-rust-zig-interop.md).

## Cost & mitigation

- Code-size symptom on esp32: Zig's 9-function lib is **715 B** of `.text` vs
  clang **223 B** / gcc **201 B** (real `.text`, `llvm-size -A`; the often-quoted
  647 B counted zig's default `.eh_frame` — docs/15) — the bloat is the
  byte-by-byte stack marshalling above.
- **Mitigations** (any one): keep cross-language structs **word-aligned** (the
  common case — any struct with an `int`/pointer member already is); or pass
  byte-array/packed/`align(1)` structs **by pointer**; or avoid by-value
  aggregates on Zig boundaries entirely. Returns need no mitigation (sret).
