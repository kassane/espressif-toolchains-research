# 02 — Xtensa ABI & CPU features

## Windowed call ABI (what all six toolchains use by default)

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
aggregates); it diverges for **under-aligned** (`align(1)`) by-value struct
*arguments* — driven by alignment, not size — see
[05-struct-abi-deep-dive.md](05-struct-abi-deep-dive.md).

## Windowed vs call0, and `-mlongcalls`

The default everywhere (clang, rust, zig, gcc, LDC, TinyGo) is the **windowed** ABI above, and
the whole ESP ecosystem uses it. The alternative **call0** ABI exists and is
reachable:

| ABI | prologue/epilogue | call | return addr | how to select |
|-----|-------------------|------|-------------|---------------|
| windowed (default) | `entry a1,N` / `retw.n` | `call8`/`callx8` (window rotates) | rotated `a0` | (default) |
| call0 | none / `ret.n` | `call0`/`callx0` | `a0`, flat regs | gcc `-mabi=call0`; LLVM by disabling the `windowed` feature |

```
add(int,int):  windowed -> entry a1,32 ; ... ; retw.n
               call0    -> ... ; ret.n          (no window, a0 = return address)
```

- **clang has no `-mabi=` flag** for xtensa, but call0 is reachable via the target
  feature: `clang -mcpu=esp32 -Xclang -target-feature -Xclang -windowed`
  produces `ret.n` / `callx0` (verified). Zig/rust can reach it the same way
  (drop the `windowed` CPU feature).
- **windowed and call0 are mutually incompatible ABIs.** A `callx8` caller rotates
  the register window; a call0 callee expects the return address in `a0` and no
  rotation. You must build an entire program (all languages, all libs) with **one**
  ABI — mixing windowed and call0 objects breaks calls regardless of the shared
  backend. Since esp clang/rust/zig and ESP-IDF all default to windowed, that is
  the safe project-wide choice (and what this repo uses).
- **`-mlongcalls`** is a GCC option (clang warns "argument unused"). It only
  changes how *direct* calls to far symbols are encoded (`l32r`+`callx` instead of
  a range-limited `call`); it does **not** change the ABI, so it is FFI-neutral.

### Mechanized: `experiments/call0-abi/run.sh`

Flips every frontend in the matrix between windowed and CALL0 on every Xtensa
core and confirms the prologue/epilogue swap. The CALL0 selector differs by
toolchain — the LLVM trio reaches it via *feature subtraction* on `-mcpu=`,
GCC has a dedicated `-mabi=` flag, all five end up at the same `ret.n`:

| frontend | windowed (default) | CALL0 selector |
|---|---|---|
| esp-clang 21.1.3 | `--target=xtensa-esp-elf -mcpu=esp32` | `… -Xclang -target-feature -Xclang -windowed` |
| esp-gcc 15.2.0 | `XTENSA_GNU_CONFIG=$(xtensa_cfg esp32) xtensa-esp-elf-gcc` | `… -mabi=call0` |
| zig 0.16/0.17 | `zig build-obj -mcpu=esp32` | `zig build-obj -mcpu=esp32-windowed` |
| LDC 1.42 (espressif LLVM 21.1.3) | `ldc2 -mtriple=xtensa-esp-elf -mcpu=esp32` | `… -mattr=-windowed` |
| rustc 1.95-nightly | `--target xtensa-esp32-none-elf` (windowed default) | `… -C target-feature=-windowed` |

The script is across the matrix on every core (`esp32` / `esp32s2` / `esp32s3`)
and reports a one-line summary per object:

```
build/call0-abi/zig_w_esp32.o    WINDOWED (entry+retw.n)
build/call0-abi/zig_c0_esp32.o   CALL0    (no-entry+ret.n)
```

Run with `source scripts/env.sh && bash experiments/call0-abi/run.sh`. The
zig 0.17 fix lane (`$ZIG_017`, see docs/05 §"Zig 0.17 status") doesn't change
this story — the windowed/CALL0 selector lives in LLVM, both 21.1.0 and
22.1.4 honour `-mcpu=<core>-windowed` identically.

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
