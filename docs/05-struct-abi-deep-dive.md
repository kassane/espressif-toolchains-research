# 05 — Deep dive: the struct-argument ABI divergence (alignment, not size)

**As of 2026-05-30** the canonical lane (zig 0.17, clang 21.1.3, rust 21.1.3,
**LDC 1.42.0 / LLVM 22.1.4**, esp-gcc 15.2.0, TinyGo 0.41.1) has **TinyGo
(byte-array case) as the only remaining language with a struct-by-value gap
on Xtensa**. Two long-standing bugs closed:

- Zig 0.17 (`$ZIG`) flattens aggregates to `[N x i32]` like clang —
  align-1 by-value structs pass cleanly. See "Zig 0.17 status" below.
- LDC 1.42.0 (the maintainer-republished tarball, `kassane/esp-idf-dlang`
  `xtensa-toolchain` release) drops the universal `byval`/`sret` aggregate
  lowering that LDC 1.42-git on LLVM 21.1.3 carried, and now emits the same
  `[N x i32]` form clang does. See "LDC 1.42 status" below.

The rest of this doc traces what *was* broken and what each fix landed.
The original framing — "shared backend doesn't give a shared ABI; trigger
is alignment not size; only by-value arguments" — held for every frontend
that deferred aggregate lowering to LLVM's default. By construction the
two frontends that didn't defer (clang/gcc — the C ABI authors) were
already correct. Rust matched them. The Zig and D frontends were the
deferring ones; both have now stopped deferring.

## The discriminator is alignment

`experiments/abi-structs/sweep.sh` forwards a by-value struct to an external
function and classifies how every available toolchain passes it on esp32
(the **canonical** lane: `$ZIG` = 0.17 / LLVM 22.1.4):

```
struct                align  clang IR arg   | clang        gcc          rust         zig            D            TinyGo
[8]u8                  1     [2 x i32]      | REGISTERS    REGISTERS    REGISTERS    REGISTERS *    REGISTERS    REGISTERS
[16]u8                 1     [4 x i32]      | REGISTERS    REGISTERS    REGISTERS    REGISTERS *    REGISTERS    REGISTERS
[24]u8                 1     [6 x i32]      | REGISTERS    REGISTERS    REGISTERS    REGISTERS *    REGISTERS    REGISTERS
{2 x u32}              4     [2 x i32]      | REGISTERS    REGISTERS    REGISTERS    REGISTERS      REGISTERS    REGISTERS
{6 x u32}              4     [6 x i32]      | REGISTERS    REGISTERS    REGISTERS    REGISTERS      REGISTERS    REGISTERS

* on the legacy `$ZIG_016` lane (Zig 0.16 / LLVM 21.1.0), all three Zig
  align-1 rows are STACK (movsp) — the original docs/05 bug. Switch with
  `ZIG=$ZIG_016 bash experiments/abi-structs/sweep.sh esp32` to reproduce.

C-bitfield rows (clang/gcc/zig packed struct(uN)/D — rust + TinyGo have no
native bitfield syntax):

bf 16b(4+4+8)          2     i32            | REGISTERS    REGISTERS    n/a          REGISTERS      REGISTERS    n/a
bf 32b(8+8+16)         4     i32            | REGISTERS    REGISTERS    n/a          REGISTERS      REGISTERS    n/a
bf 64b(32+32)          8     [1 x i64]      | REGISTERS    REGISTERS    n/a          REGISTERS      REGISTERS    n/a
```

- **align-1 byte arrays USED to diverge at every size — even 8 bytes** —
  five of six toolchains classified REGISTERS while **Zig 0.16 alone used
  movsp**. Zig 0.17 (`$ZIG` canonical) now flattens to `[N x i32]` like clang
  and matches; only the legacy `$ZIG_016` lane reproduces the old break.
- **D bitfields USED to lower as `byval(%s.T)` on every width** — the LDC
  1.42-git build on LLVM 21.1.3 wrapped every aggregate in `byval`/`sret`,
  including the bitfield rows above (note the now-deleted "D IR:
  byval(%s.T)" annotation that used to live next to the 64-bit row).
  **LDC 1.42.0** (the 2026-05-30 maintainer-republished tarball on LLVM
  22.1.4) flattens the same way clang does — every D bitfield row above
  now classifies REGISTERS without footnote. The legacy 21.1.3 LDC bug
  is preserved on the `$LDC2_UPSTREAM` arm and recorded in docs/23.
- **align-4 structs match at every size — even 24 bytes.**
- **Bitfields: clang/gcc flatten to the scalar backing type** (`i32`/`i32`/
  `[1 x i64]` for the 16/32/64-bit total widths). **Zig matches clang
  exactly** when you give the `packed struct(uN)` an explicit backing
  integer; without the backing, Zig errors:
  ```
  parameter of type 'F' not allowed in function with calling convention 'xtensa_call0'
  note: inferred backing integer of packed struct has unspecified signedness
  ```
  **D — on the *legacy* LDC 1.42-git build (LLVM 21.1.3) — wrapped every
  bitfield struct in `byval(%s.T)` at the IR level**, same as every other
  aggregate. The movsp heuristic still classified the caller as REGISTERS
  (the backend lowers byval to pointer-passthrough without movsp), but the
  *machine* ABI was still indirect — a clang caller expecting the scalar
  flattening would mismatch on any case where the function actually read
  its bitfields from `a2` (not `[a1 + off]`). That *was* the strongest
  evidence yet that D's struct-ABI bug was universal: byte-array, word-array,
  bitfield — every aggregate shape lowered the same broken way. **The
  2026-05-30 LDC 1.42.0 maintainer re-upload (LLVM 22.1.4) closes the bug
  end-to-end** — every D row in the table above now classifies REGISTERS at
  both heuristic AND IR level. See "LDC 1.42 status" below. The legacy
  `$LDC2_UPSTREAM` arm (LDC on upstream LLVM 22.1.2, no aggregate-
  flattening fix) still reproduces the broken IR for regression-tracker
  purposes.
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

## What Zig *used to* do (0.16 lane, fixed in 0.17)

Zig 0.16 forwarded the raw `extern struct` to LLVM (`i32 @zig_blob_sum(%Blob)`)
and inherited LLVM's default calling-convention lowering. That default only
passes the aggregate in registers when it is naturally word-aligned; an
under-aligned (align-1) aggregate was passed in memory. **Zig 0.17 closed this**
in the frontend by lowering aggregate args as `[N x i32]` exactly like clang
does (the same `[6 x i32]` IR signature). See "Zig 0.17 status" at the bottom
of this doc for the IR diff; this section traces what the legacy `$ZIG_016`
lane still reproduces.

### Proof at the call site (8-byte structs, `experiments/abi-structs`)

`[8]u8` (align 1) — clang registers, Zig 0.16 stack (Zig 0.17 matches clang):

```
clang caller:                          zig 0.16 caller:
  entry a1,32                            entry a1,32
  mov.n a11,a3 ; mov.n a10,a2            mov.n a10..a15 (stage)
  callx8 <ext>                           addi a9,a1,-8 ; movsp a1,a9   ; grow stack
                                         l8ui/s32i  spill 2 words to a1+0,a1+4
                                         callx8 <ext> ; movsp a1,+8 (restore)
```

`{u32,u32}` (align 4, *same 8 bytes*) — clang and Zig (both 0.16 and 0.17)
**byte-identical**:

```
entry a1,32 ; mov.n a11,a3 ; mov.n a10,a2 ; callx8 <ext> ; mov.n a2,a10 ; retw.n
```

On the legacy `$ZIG_016` lane, a clang/rust/gcc ↔ zig call with an
**under-aligned by-value struct argument** reads the bytes from the wrong place
⇒ silent corruption on hardware. Word-aligned structs are safe. (The host test
in doc 03 passes regardless because x86_64 SysV memory-passes these structs in
a way both sides agree on.) Canonical zig 0.17 closes this — the bytes-from-
wrong-place hazard is now D-only on Xtensa.

## Struct *returns* are fine even when under-aligned

`make_blob` returns `[24]u8` (align 1). clang uses an explicit `sret` pointer in
`a2`; Zig returns by value in IR but the backend lowers it to the *same* sret
convention (Zig just builds the value in its frame then copies it to the caller's
buffer). Compatible — the divergence is specific to under-aligned *arguments*.

## D/LDC and TinyGo: two more "defer to backend" stories

Zig isn't the only frontend that *used to* hand aggregates raw to the LLVM
Xtensa backend. Two more did, in different ways.

**D/LDC used to mark every aggregate `byval`/`sret`.** Whether the input
was `Point{int x, int y}`, `Blob{ubyte[24] data}`, or anything else, the
LDC 1.42-git build's IR put every parameter behind a pointer with `byval`.
The backend lowered that as "copy to caller's frame, read via SP". So D
failed *every* by-value struct case the C ABI puts in registers:
`point_dot` (align-4) **and** `blob_sum` (align-1) **and** the 8-byte
struct return. The lone case D got right was the >16-byte `sret` return,
where the C ABI is *also* indirect.
[experiments/ldc-fork-comparison](../experiments/ldc-fork-comparison/run.sh)
proved the bug was frontend-side: the espressif-fork LDC (LLVM 21.1.3) and
the upstream-22 LDC produced byte-identical broken IR.

**LDC 1.42.0 (2026-05-30) closes this hole.** The maintainer-republished
tarball at `kassane/esp-idf-dlang/releases/download/xtensa-toolchain/`
bumps the canonical LDC to **LDC 1.42.0 (release, no -git suffix) on LLVM
22.1.4**, and the frontend now emits the same `[N x i32]` aggregate
flattening clang does. `d_point_dot`'s IR is
`define i32 @d_point_dot([2 x i32] %a_arg, [2 x i32] %b_arg)`; the disasm
is `mull a8,a5,a3; mull a9,a4,a2; add.n a2,a9,a8; retw.n` — **byte-
identical to clang's `c_point_dot`**. `d_make_point` is `entry/retw.n` —
return is in `a2/a3`, no `sret` slot. qemu xtensa drops to **0 failures**;
abi-structs sweep reports REGISTERS for D on every row (small/large align,
bitfield, return). Full account in [docs/19](19-dlang-ldc.md) +
[docs/23](23-ldc-espressif-fork.md) §"LDC 1.42 status". The legacy
behaviour is preserved on `$LDC2_UPSTREAM` (which is still the pre-fix
LDC on upstream LLVM 22.1.2) for regression-tracker purposes.

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

The cumulative score at align-1 on Xtensa, with **Zig 0.17 canonical** and
**LDC 1.42.0 canonical** (2026-05-30): **TinyGo (byte-array case) is the only
diverging frontend**. Zig 0.16 (`$ZIG_016`) and the legacy `$LDC2_UPSTREAM`
(LDC on upstream LLVM 22.1.2, pre-fix) reproduce the historical breaks as
two off-canonical rows. The mitigation for TinyGo is the same as it always
was: pass the byte-array aggregate by pointer.

## Not Xtensa-only — RISC-V *also* had a Zig struct bug (0.16, fixed in 0.17)

The Xtensa manifestation (under-aligned arg → stack) was Xtensa-specific: the
same `[8]u8` caller on RISC-V esp32c3 passes by reference in `a0` for both clang
and Zig. **But RISC-V wasn't bug-free for Zig 0.16 either** — there the
*small* `{i32,i32}` `Point` was mis-lowered to `[2 x i64]` (wrong registers),
which the Xtensa path handled correctly. Zig's two experimental ESP targets each
had a by-value struct-argument gap, in different cases; Rust/clang/gcc were
correct on both. The RISC-V case reproduced on upstream Zig too. **Both gaps
closed in 0.17.0** (`$ZIG` canonical) — verified at the shell, qemu
`zig_point_dot` flips from `FAIL` to `ok (11)` on riscv just as
`zig_blob_sum` flips on xtensa. See
[docs/09](09-riscv.md) and [docs/10](10-cabi-completeness.md). The common root
was that Zig 0.16 deferred aggregate ABI to LLVM's default instead of
implementing the platform C ABI in the frontend (which clang and rust both do).
This was an **upstream Zig** gap, not the espressif fork:
`kassane/zig-espressif-bootstrap` patches only LLVM/LLD/Clang (no Zig `src/`
changes), and Xtensa was finalized upstream under `ziglang/zig` #5467
(**CLOSED 2026-05-06**, milestone 0.17.0) — the fix shipped in 0.17 (verified
at the shell; see "Zig 0.17 status" below). See [docs/17](17-rust-zig-interop.md).

## Cost & mitigation

- Code-size symptom on the legacy `$ZIG_016` lane: Zig's 9-function lib was
  **715 B** of `.text` vs clang **223 B** / gcc **201 B** (real `.text`,
  `llvm-size -A`; the often-quoted 647 B counted zig's default `.eh_frame` —
  docs/15) — the bloat was the byte-by-byte stack marshalling above. **Zig
  0.17 (`$ZIG` canonical) regenerates the same `.text` shape as clang**, so
  the size gap closes on the canonical lane.
- **Mitigations** for the residual D/TinyGo gaps (and the legacy `$ZIG_016`
  lane): keep cross-language structs **word-aligned** (the
  common case — any struct with an `int`/pointer member already is); or pass
  byte-array/packed/`align(1)` structs **by pointer**; or avoid by-value
  aggregates on Zig boundaries entirely. Returns need no mitigation (sret).

## Zig 0.17 status — the bug is fixed in the canonical baseline

The canonical `$ZIG` is the **`kassane/zig-espressif-bootstrap` 0.17 release**
(`zig-0.17.0-relsafe-x86_64-linux-musl-baseline.tar.xz` under the
`0.16.0-xtensa-dev` tag, bundled clang/LLVM **22.1.4**). It closes both
struct-arg gaps relative to the legacy `$ZIG_016` lane:

- **Xtensa `zig_blob_sum`** (24-byte `[u8;24]`, align-1): qemu went from
  `FAIL (got=409 want=300)` on 0.16 to `ok (300)` on 0.17.
- **RISC-V `zig_point_dot`** (8-byte `{i32,i32}`): qemu went from `FAIL` on
  0.16 to `ok (11)` on 0.17.
- **`experiments/abi-structs/sweep.sh`** on every Xtensa core: every Zig row
  (`[8]u8` / `[16]u8` / `[24]u8` / `{2xu32}` / `{6xu32}`) now classifies
  **REGISTERS**, matching clang/gcc/rust/D/TinyGo.

The IR diff at `zig_blob_sum` shows the frontend change:

```
0.16 (LLVM 21.1.0):  i32 @lib_zig.zig_blob_sum(%lib_zig.Blob %0) … alloca [24 x i8], align 1
0.17 (LLVM 22.1.4):  i32 @lib_zig.zig_blob_sum([6 x i32]      %0) … alloca [24 x i8], align 4
```

Zig 0.17 now emits the same `[N x i32]` aggregate-flattening clang has been
emitting all along — passing the 6 words in `a2..a7` (after the windowed
rotation from caller's `a10..a15`) instead of growing the stack with
`movsp`. The 0.17 binary is the default `$ZIG`
(`/home/user/toolchains/zig-0.17-espressif/zig`); to reproduce the historical
bug, switch with `ZIG=$ZIG_016 ./scripts/build-ffi.sh esp32` and
`ZIG=$ZIG_016 ./scripts/run-qemu.sh xtensa`.

**This narrows the cumulative score**: at align-1 on Xtensa, the diverging
frontend is now just **TinyGo (byte-array case)** — both Zig 0.17 and LDC
1.42.0 have left the list. The original "Zig defers aggregate ABI to LLVM
default" diagnosis from `ziglang/zig` #5467 (closed 0.17 milestone,
2026-05-06) shipped, so the upstream lane caught up with what
clang+rust+gcc do. And the parallel "LDC marks every aggregate
`byval`/`sret`" diagnosis (docs/19/23) is now history on the canonical
LDC — see "LDC 1.42 status" below. TinyGo's `[N x i8]` shape (docs/24)
is unaffected — that bug is in the tinygo-org/llvm-project fork's
frontend pass, not in upstream LDC or Zig.

## LDC 1.42 status — the universal D byval/sret bug is fixed in the canonical baseline

The canonical `$LDC2` is now the **`kassane/esp-idf-dlang` 1.42 release**
(`ldc2-v1.42.0-espressif-linux-musl-static.tar.xz` under the
`xtensa-toolchain` tag, re-uploaded 2026-05-30; bundled **LLVM 22.1.4**).
It closes the universal aggregate ABI bug the previous LDC 1.42-git build
(on LLVM 21.1.3) carried — every divergence row in the deep-dive table
above now reads REGISTERS for D:

- **xtensa `d_point_dot`** (8-byte `{i32,i32}`, align-4): qemu went from
  `FAIL (got=4548 want=11)` on the old LDC to `ok (11)`.
- **xtensa `d_blob_sum`** (24-byte `[u8;24]`, align-1): qemu went from
  `FAIL (got=394 want=300)` to `ok (300)`.
- **xtensa `d_make_point`** (8-byte struct return in regs): used to be
  routed through an `sret` slot; now just `entry/retw.n` — return in
  `a2/a3` like clang.
- **`experiments/abi-structs/sweep.sh`** on every Xtensa core: every D
  row now classifies REGISTERS at both the heuristic AND the IR level
  (the 64-bit bitfield row's old "D IR: byval(%s.T)" annotation is gone).

IR diff at `d_point_dot`:

```
old LDC 1.42-git (LLVM 21.1.3): i32 @d_point_dot(ptr byval(%lib_d.Point) %a, ptr byval(%lib_d.Point) %b)
new LDC 1.42.0   (LLVM 22.1.4): i32 @d_point_dot([2 x i32] %a_arg, [2 x i32] %b_arg)
```

Disasm at the callee shifts from "spill to stack, read via SP" to
"args in `a2/a3/a4/a5`, multiply directly":

```
old (legacy LDC, still reproducible via $LDC2_UPSTREAM):
    l32i.n a8, a1, +N    ; first arg loaded from SP-relative stack slot
new (canonical $LDC2):
    mull   a8, a5, a3    ; b.y * a.y
    mull   a9, a4, a2    ; b.x * a.x
    add.n  a2, a9, a8    ; sum
    retw.n
```

The new disasm is **byte-identical to clang's `c_point_dot`** — D
finally produces register-passing C-ABI code by default.

`$LDC2` is `/home/user/toolchains/ldc-xtensa/bin/ldc2` (sha256 of the
tarball: `c2cd9f5b…becb548`; old tarball was `0e99b893…2114211`).
`$LDC2_UPSTREAM` (LDC on upstream LLVM 22.1.2, no Xtensa MC patches
and no aggregate-flattening fix) still reproduces the historical broken
IR — that's now the regression-tracker baseline. The bug was
**frontend-side**, confirmed both directions: same Xtensa MC patches as
the old LDC fork, different aggregate-lowering pass → correct IR. So
the 2026-05-30 maintainer re-upload is a frontend-driven win, not a
backend change.

**Caveat — LLVM cluster shift.** The new canonical LDC bundles LLVM
22.1.4 (was 21.1.3). That moves it out of the LLVM-21 cluster
(esp-clang + rust, both 21.1.3) and into the LLVM-22 cluster (zig 0.17
22.1.4 + `$LDC2_UPSTREAM` 22.1.2 + `$LDC_LLVM_DIR` binutils). `ld.lld`
LTO across canonical-LDC ↔ esp-clang/rust now fails with "Invalid
record" the same way clang↔zig LTO does — they're not in the same
cluster anymore. Object-level FFI is unaffected (datalayouts are still
byte-identical and we just rebuilt the full FFI matrix with 0 link
failures). See [docs/04](04-llvm-ir-and-mixing.md) §"Two LLVM
clusters" — that section needs a follow-up to move LDC from the LLVM-21
column to the LLVM-22 column.
