# 05 — Deep dive: the struct-argument ABI divergence (alignment, not size)

This is the one place the shared backend does **not** give a shared ABI. It is
subtle: the trigger is **struct alignment**, not struct size, and it only affects
by-value struct *arguments* (returns are fine).

## The discriminator is alignment

`experiments/abi-structs/sweep.sh` forwards a by-value struct to an external
function and classifies how every available toolchain passes it on esp32:

```
struct                align  clang IR arg   | clang        gcc          rust         zig            D            TinyGo
[8]u8                  1     [2 x i32]      | REGISTERS    REGISTERS    REGISTERS    STACK (movsp)  REGISTERS    REGISTERS
[16]u8                 1     [4 x i32]      | REGISTERS    REGISTERS    REGISTERS    STACK (movsp)  REGISTERS    REGISTERS
[24]u8                 1     [6 x i32]      | REGISTERS    REGISTERS    REGISTERS    STACK (movsp)  REGISTERS    REGISTERS
{2 x u32}              4     [2 x i32]      | REGISTERS    REGISTERS    REGISTERS    REGISTERS      REGISTERS    REGISTERS
{6 x u32}              4     [6 x i32]      | REGISTERS    REGISTERS    REGISTERS    REGISTERS      REGISTERS    REGISTERS

C-bitfield rows (clang/gcc/zig packed struct(uN)/D — rust + TinyGo have no
native bitfield syntax):

bf 16b(4+4+8)          2     i32            | REGISTERS    REGISTERS    n/a          REGISTERS      REGISTERS    n/a
bf 32b(8+8+16)         4     i32            | REGISTERS    REGISTERS    n/a          REGISTERS      REGISTERS    n/a
bf 64b(32+32)          8     [1 x i64]      | REGISTERS    REGISTERS    n/a          REGISTERS      REGISTERS    n/a   (D IR: byval(%s.T))
```

- **align-1 byte arrays diverge at every size — even 8 bytes.** Five of six
  toolchains classify REGISTERS; **Zig alone uses movsp**.
- **align-4 structs match at every size — even 24 bytes.**
- **Bitfields: clang/gcc flatten to the scalar backing type** (`i32`/`i32`/
  `[1 x i64]` for the 16/32/64-bit total widths). **Zig matches clang
  exactly** when you give the `packed struct(uN)` an explicit backing
  integer; without the backing, Zig errors:
  ```
  parameter of type 'F' not allowed in function with calling convention 'xtensa_call0'
  note: inferred backing integer of packed struct has unspecified signedness
  ```
  **D — including the new espressif-fork LDC (LLVM 21.1.3) — wraps every
  bitfield struct in `byval(%s.T)` at the IR level**, same as every other
  aggregate. The movsp heuristic still classifies the caller as REGISTERS
  (the backend lowers byval to pointer-passthrough without movsp), but the
  *machine* ABI is still indirect — a clang caller expecting the scalar
  flattening would mismatch on any case where the function actually reads
  its bitfields from `a2` (not `[a1 + off]`). This is the strongest
  evidence yet that D's struct-ABI bug is universal: byte-array, word-array,
  bitfield — every aggregate shape lowers the same broken way.
- **Rust + TinyGo have no native bitfield syntax** — Rust offers
  `bitfield-struct` and similar crates (not in this baremetal probe);
  TinyGo/Go has no analog at all.

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

## D/LDC and TinyGo: two more "defer to backend" stories

Zig isn't the only frontend that hands aggregates raw to the LLVM Xtensa
backend. Two more bend the matrix in different ways.

**D/LDC marks every aggregate `byval`/`sret`.** Whether the input is
`Point{int x, int y}`, `Blob{ubyte[24] data}`, or anything else, LDC's IR
puts the parameter behind a pointer with `byval`. Backend lowers that as
"copy to caller's frame, read via SP". So D fails *every* by-value struct
case the C ABI puts in registers: `point_dot` (align-4) **and** `blob_sum`
(align-1) **and** the 8-byte struct return. The lone case D gets right is
the >16-byte `sret` return, where the C ABI is *also* indirect.
[experiments/ldc-fork-comparison](../experiments/ldc-fork-comparison/run.sh)
proves the bug is frontend-side: the espressif-fork LDC (LLVM 21.1.3) and
the upstream-22 LDC produce byte-identical broken IR. Same family as
[kassane/dlang-mos-hello-world#1](https://github.com/kassane/dlang-mos-hello-world/issues/1)
on MOS 6502 (wontfix). Full account in [docs/19](19-dlang-ldc.md) +
[docs/23](23-ldc-espressif-fork.md) §(h).

**TinyGo splits the difference by field type.** A struct of scalars gets
flattened to its fields:

```
define i32 @go_point_dot(i32 %a.X, i32 %a.Y, i32 %b.X, i32 %b.Y)
```

— that lands in `a2..a5` and matches clang's C ABI. **But** a struct with a
byte-array field is left as `[N x i8]`:

```
define i32 @go_blob_sum([24 x i8] %b)
```

and the backend lowers it byte-per-register — caller emits 24 `s8i` stores,
callee reads them back as `l8ui`. A C caller written against clang's
`[6 x i32]` flattening would mismatch on the first word: clang puts byte 0
in `a2` bits 0-7, TinyGo reads all of `a2` as one byte. So TinyGo joins the
struct-arg list **for byte-array aggregates only**. Full detail in
[docs/24](24-tinygo.md) §(e).

The cumulative score at align-1 on Xtensa: **Zig**, **D/LDC**, and **TinyGo
(byte-array case)** all diverge from clang/rust/gcc. The mitigation is the
same for all three: pass aggregates by pointer.

## Not Xtensa-only — RISC-V has a *different* Zig struct bug

This particular manifestation (under-aligned arg → stack) is Xtensa-specific: the
same `[8]u8` caller on RISC-V esp32c3 passes by reference in `a0` for both clang
and Zig. **But RISC-V is not bug-free for Zig** — there the *small* `{i32,i32}`
`Point` is mis-lowered to `[2 x i64]` (wrong registers), which the Xtensa path
handles correctly. So Zig's experimental ESP targets each have a by-value
struct-argument gap, just in different cases; Rust/clang/gcc are correct on both.
The RISC-V case even reproduces on upstream Zig. See
[docs/09](09-riscv.md) and [docs/10](10-cabi-completeness.md). The common root is
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
