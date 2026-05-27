# 11 — Use-case: mixing Rust + Zig in one bare-metal ESP image

A concrete, runnable example of the practical pattern this repo's findings point
to: a Rust `#![no_std]` application that offloads a compute kernel to Zig, with
Zig calling back into Rust — linked into a single bare-metal ELF and executed on
qemu. Source: `experiments/baremetal-mixin/`; run with
`experiments/baremetal-mixin/run.sh [riscv|xtensa]`.

## Shape

```
   app.rs  (Rust #![no_std])            dsp.zig (Zig, export fn)
   ─────────────────────────            ────────────────────────
   app_main(out*)                       zig_scale(buf*, n, factor)  ──┐
     ├─ zig_scale(buf, 8, 2) ──────────────────────────────────────┐ │ calls back
     │     (Rust → Zig, buffer by ptr)                              │ │
     │     rs_progress(i, n)  ◀───────────────────────────────────────┘  (Zig → Rust)
     └─ zig_sum_of_squares(buf, 8) ─────▶ zig_sum_of_squares(buf*, n)
           (Rust → Zig, result by value, buffer by ptr)
   main.c  (glue + semihosting): calls app_main, prints result, exits
```

The interop is the **C ABI** (`#[no_mangle] extern "C"` ⇄ `export fn`), and it
deliberately uses only the **universally ABI-safe** shapes from docs/05/09/10:

- **buffers passed by pointer** (`*const i32` / `[*]const i32`), never by-value
  aggregates — this sidesteps the Zig by-value struct-arg gaps entirely;
- **scalars by value**, results by value or by pointer;
- a **callback** (`rs_progress`) — Zig calling back into Rust.

## Result (both architectures)

```
$ experiments/baremetal-mixin/run.sh riscv     # esp32c3 / qemu-system-riscv32
Rust+Zig bare-metal mixin on emulated ESP
  Rust app -> zig_scale(x2) -> zig_sum_of_squares (buffers by pointer)
  result = 816  OK (expected 816)

$ experiments/baremetal-mixin/run.sh xtensa    # esp32 / qemu-system-xtensa
  ... result = 816  OK (expected 816)
```

`buf = [1..8] ×2 = [2,4,…,16]`, `Σ squares = 816`. Rust drives, Zig computes, Zig
calls back into Rust, and it runs identically on RISC-V and Xtensa.

## How to build it yourself

- Rust side: `#![no_std]`, `crate-type = ["staticlib"]`, `panic = "abort"`,
  built with `cargo build -Z build-std=core --target <xtensa-esp32-none-elf |
  riscv32imc-unknown-none-elf>`.
- Zig side: `export fn`, built with `zig build-obj -target <…>-freestanding-none
  -mcpu=<esp32|esp32c3>`.
- Link the Rust `.a` + Zig `.o` (+ any C glue) with `ld.lld` and the matching
  compiler-rt builtins; supply your real esp-idf/bootloader entry instead of the
  demo reset shim for actual hardware.

## Caveats (from the rest of this study)

- Keep large/under-aligned structs **off** the by-value Zig boundary — pass by
  pointer (docs/05, docs/09). Scalars/pointers/callbacks are always safe.
- The demo kernel uses `i32` (not `i64`) only so it runs on qemu's generic
  `dc233c` core, which lacks esp32's `mul32high`; real esp32 silicon handles
  `i64` fine (docs/08).
- For cross-language **LTO**/inlining across the Rust↔Zig boundary, keep every
  bitcode producer on one LLVM point release (docs/04).
