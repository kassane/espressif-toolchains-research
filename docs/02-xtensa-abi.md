# 02 — Xtensa ABI & CPU features

## Windowed call ABI (what all four toolchains use by default)

ESP32-class Xtensa cores have the **register-windowed** ABI enabled (`+windowed`
feature). Every non-leaf function we compiled — across clang, rust, zig and gcc —
uses it:

- **Prologue** `entry a1, N` — atomically rotates the register window and
  allocates an `N`-byte frame on `a1` (the stack pointer).
- **Epilogue** `retw.n` — window-return.
- **Integer/pointer arguments**: `a2..a7` (callee view), up to 6 words; overflow
  on the stack.
- **Return value**: `a2` (and `a3` for 8-byte values).
- **Calls**: `call8`/`callx8` rotate the window by 8, so the caller stages
  outgoing args in `a10..a15` (= callee `a2..a7`) and reads the result from
  `a10` (= callee `a2`).
- **64-bit values**: even/odd register pairs (`a2:a3`, `a4:a5`, …).
- **Floating point**: passed in **integer** `a`-registers (there are no FP
  argument registers); the FPU, when present, is used only inside the function.

This is verified directly in [03-ffi-matrix.md](03-ffi-matrix.md) and
[05-struct-abi-deep-dive.md](05-struct-abi-deep-dive.md).

### Aggregate (struct) rules — the subtle part

The Xtensa C ABI (as implemented by clang/rust/gcc):

| case | convention | IR shape (clang/rust) |
|------|-----------|------------------------|
| struct ≤ 16 B, by value | flattened into `a`-registers | `[N x i32]` direct |
| struct passed by value, ≤ 6 words (24 B) arg | in `a2..a7` | `[6 x i32]` direct |
| struct > 16 B returned | hidden `sret` pointer in `a2` | `ptr sret(...)` |

Zig's experimental target does **not** reproduce all of these (it passes raw
aggregates); the large by-value-argument case is where it diverges — see
[05-struct-abi-deep-dive.md](05-struct-abi-deep-dive.md).

## CPU feature parity across frontends

The three LLVM frontends agree exactly on the per-core feature set. Verified with
`rustc --print cfg`, clang's `target-features` attribute, and
`zig build-obj --show-builtin` (regenerate via `scripts/analyze.sh <cpu>`).

| feature | esp32 | esp32s2 | esp32s3 | meaning |
|---------|:----:|:------:|:------:|---------|
| `windowed` | ✓ | ✓ | ✓ | register-windowed ABI |
| `density`  | ✓ | ✓ | ✓ | 16-bit `*.n` instructions |
| `fp`       | ✓ | — | ✓ | single-precision FPU |
| `loop`     | ✓ | — | ✓ | zero-overhead loops |
| `mac16`    | ✓ | — | ✓ | 16-bit multiply-accumulate |
| `s32c1i`   | ✓ | — | ✓ | atomic compare-swap |
| `bool`     | ✓ | — | ✓ | boolean registers |
| `mul32`    | ✓ | ✓ | ✓ | 32-bit multiply |
| `esp32s2ops` | — | ✓ | — | S2 ISA extension |
| `esp32s3ops` | — | — | ✓ | S3 ISA extension |

**Key consequence:** `esp32s2` has **no FPU**. `f32` math compiles to hardware
`mul.s` on esp32/esp32s3 but to a `__mulsf3` soft-float call on esp32s2 — while
the *ABI* (floats in `a`-registers) stays identical, so FFI is unaffected.

```
; c_mul_f32 on esp32 (hardware FPU)        ; c_mul_f32 on esp32s2 (soft float)
entry a1,32                                 entry a1,32
wfr   f9,a2 ; wfr f8,a3                      mov.n a10,a2 ; mov.n a11,a3
mul.s f8,f9,f8                               callx8 <__mulsf3>
rfr   a2,f8                                  mov.n a2,a10
retw.n                                       retw.n
```

`add_i32` is byte-identical on all three cores (same windowed ABI everywhere).
