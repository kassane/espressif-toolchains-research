# 09 — RISC-V control (ESP32-C3): the Zig gap is Xtensa-only

The same `espressif/llvm-project` LLVM 21 also hosts **riscv32** — in fact
`riscv32-esp-unknown-elf` is esp clang's *default* triple. The newer ESP32-C*
chips are RISC-V (ESP32-C3 = `rv32imc`). Repeating the FFI matrix here isolates
whether the struct-argument divergence (docs/05) is a Zig-FFI problem in general
or specific to Zig's experimental **Xtensa** target.

## Build

`scripts/build-ffi.sh esp32c3` builds the same four-language matrix for ESP32-C3:

- C / C++: `clang --target=riscv32-esp-elf -mcpu=esp32c3`
- Rust: `cargo build -Z build-std=core --target riscv32imc-unknown-none-elf`
- Zig: `zig build-obj -target riscv32-freestanding-none -mcpu=esp32c3`
- link: `ld.lld` + the `rv32imc_ilp32` compiler-rt builtins

Result: one `EM_RISCV` ELF, **0 undefined symbols** — clang C + clang C++ + Rust
+ Zig interoperate and link, exactly as on Xtensa.

## The struct argument that breaks on Xtensa — matches on RISC-V

`blob_sum(Blob)` with `Blob = [24]u8` (align 1). The RISC-V calling convention
passes a struct larger than 2 words **by reference** (a pointer in `a0`), and
**both clang and Zig do exactly that**:

```
; clang c_blob_sum            ; zig zig_blob_sum
mv   a1, a0   ; a0 = &Blob     mv   a1, a0   ; a0 = &Blob
lbu  a3, 0(a1); sum in place   addi a0, sp, 0xc ; memcpy &Blob -> local
add  a0, a0, a3                li   a2, 0x18    ;  (24 bytes), then sum
...                            ...
```

Both receive the struct as a **pointer in `a0`** — the RISC-V ABI. Zig makes a
redundant local copy (less efficient), but the **ABI matches**: a clang↔zig call
here is correct.

## Contrast

| target | large by-value struct arg | clang/rust | zig | FFI |
|--------|---------------------------|-----------|-----|-----|
| **Xtensa** esp32 | `[24]u8` (align 1) | `[6 x i32]` in `a2..a7` (registers) | stack-spill | **mismatch** |
| **RISC-V** esp32c3 | `[24]u8` (align 1) | pointer in `a0` (by reference) | pointer in `a0` | **match** |

The RISC-V ABI's simple "large structs by reference" rule is implemented
correctly by Zig; the Xtensa ABI's "flatten small-enough aggregates into
registers" rule is not (yet). So the divergence is a gap in Zig's **Xtensa**
target, not in Zig FFI generally — consistent with Zig's RISC-V support being
mature and its Xtensa support experimental.

(Only static link + disassembly here; a RISC-V semihosting qemu run — expected
all-pass — is left as a follow-up, mirroring docs/08.)
