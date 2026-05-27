# 05 — Deep dive: the large by-value struct ABI divergence

This is the one place the shared backend does **not** give a shared ABI. It is
worth a careful teardown because it is subtle, real, and easy to trip over.

## Setup

`Blob` is a 24-byte aggregate: `struct { uint8_t data[24]; }`. We look at two
operations from the FFI contract:

- `blob_sum(Blob) -> u32` — large struct **as an argument**.
- `make_blob(u8) -> Blob` — large struct **as a return**.

## Struct *return* (`make_blob`) — compatible

clang lowers the return to an explicit `sret` pointer:

```llvm
define void @c_make_blob(ptr sret(%struct.Blob) %0, i8 zeroext %fill)
```
```
; c_make_blob: writes directly through the caller's buffer (a2 = sret ptr, a3 = fill)
entry a1,32 ; loop: s8i a11,a10,0 (a10=a2+i, a11=fill+i) ; retw.n
```

Zig returns the aggregate *by value* in IR (`%Blob @zig_make_blob(i8)`), but the
LLVM backend lowers that to the **same sret-pointer-in-`a2`** convention. Zig just
builds the Blob in its own frame first, then copies it to the caller's buffer:

```
entry a1,64
; build data[i] = fill+i into local frame a1+0..23
loop: s8i a11,a10,0   (a10 = a1+i)
; then memcpy local frame -> caller's sret buffer in a2
loop: l8ui a8,a1,i ; s8i a8,a2,i      (i = 23..0)
retw.n
```

Same ABI (dest pointer in `a2`, `fill` in `a3`), just less efficient. **FFI-safe.**

## Struct *argument* (`blob_sum`) — INCOMPATIBLE

clang and rust flatten the 24-byte struct to six words passed in registers:

```llvm
define i32 @c_blob_sum([6 x i32] %0)     ; identical in rust
```
```
; c_blob_sum reads the struct out of a2..a7
entry a1,64
s32i.n a2,a1,0 ; a3,a1,4 ; a4,a1,8 ; a5,a1,12 ; a6,a1,16 ; a7,a1,20   ; spill 6 arg words
... sum the 24 bytes ...
```

Zig passes the raw aggregate (`i32 @zig_blob_sum(%Blob)`) and the backend chooses
a different, **memory-leaning** layout — it reconstructs the struct from a mix of
the low bytes of `a2..a7` *and* words read from the incoming stack area
(`a1+64 …`):

```
entry a1,64
l32i a8,a1,132 ; s8i a8,a1,23     ; byte 23 from stack word a1+132
... (bytes 22..6 likewise from a1+128 down to a1+64) ...
s8i a7,a1,5 ; a6,a1,4 ; a5,a1,3 ; a4,a1,2 ; a3,a1,1 ; a2,a1,0   ; bytes 5..0 from regs
```

## Proof at the call site (`experiments/abi-structs`)

Two callers forwarding a `Blob` to an external `blob_sum`, disassembled:

```
caller.c  (clang):                      caller.zig (zig):
  entry a1,32                             entry a1,32
  mov.n a10,a2 ; a11,a3 ; a12,a4          addi a9,a1,-72 ; movsp a1,a9   ; grow stack
        a13,a5 ; a14,a6 ; a15,a8          ; spill 18 words to a1+0..68
  callx8 <blob_sum>                       mov.n a10,a2 ... a15,a8        ; 6 in regs
  ; 24 bytes entirely in a10..a15         callx8 <blob_sum>
```

- **clang caller** places all 24 bytes in outgoing registers `a10..a15`.
- **zig caller** grows its frame (`movsp`), spills 18 words to the stack and puts
  only 6 in registers.

These layouts do not match. A `clang → zig` (or `rust → zig`, `gcc → zig`) call
with a `>16 B` by-value struct argument — or the reverse — reads the bytes from
the wrong place ⇒ **silent data corruption on hardware**. The host test (§03)
passes only because x86_64's SysV ABI memory-passes the struct in a way both
agree on.

## Why

Zig's Xtensa target is experimental and does not yet implement the C-ABI
aggregate coercion that clang and rust perform in the frontend. It forwards raw
`extern struct` types to LLVM and inherits the backend's default
calling-convention lowering, which is not the platform C ABI for large by-value
struct arguments. (Small structs and struct returns happen to coincide; large
by-value args do not.)

## Cost & mitigation

- Code-size symptom: Zig's 9-function lib is **647 B** vs clang **196 B** / gcc
  **174 B** on esp32 — the bloat is the byte-by-byte struct marshalling above.
- **Mitigation (one line):** on any FFI boundary touching Zig, pass large structs
  **by pointer** (`const Blob*` / `&Blob` / `*const Blob`). Pointer arguments use
  the universally-agreed integer-register convention, sidestepping the issue
  entirely. Returns are already safe (sret).
