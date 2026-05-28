# 09 — RISC-V (ESP32-C3): a *different* Zig struct-ABI gap

The same `espressif/llvm-project` LLVM 21 also hosts **riscv32** (it is esp clang's
*default* triple). ESP32-C3 = `rv32imc`. Repeating the matrix here was meant to
check whether the Zig struct-argument divergence (docs/05) is Xtensa-specific.
**TinyGo** also has an `esp32c3-generic` target (LLVM 20.1.1, docs/24) but is
firmware-only so doesn't join the link matrix here.

**It is not.** RISC-V has its *own*, different Zig struct-ABI bug — caught by the
qemu runtime test (docs/08-style), which a static spot-check of only the large
struct had missed. Rust, clang and gcc are correct on both architectures.

## Build & link — fine

`scripts/build-ffi.sh esp32c3` builds the **five-language** matrix for ESP32-C3
(clang C/C++, `cargo … --target riscv32imc-unknown-none-elf`,
`zig … -mcpu=esp32c3`, `ldc2 -mtriple=riscv32-unknown-none-elf -mattr=+m,+c`),
links one `EM_RISCV` ELF via `ld.lld` + rv32imc compiler-rt, **0 undefined
symbols**. As on Xtensa, everything links.

## Runtime (qemu-system-riscv32 `virt`)

`scripts/run-qemu.sh riscv` runs the matrix on the espressif qemu RISC-V build:

```
- scalar add_i32 : c ok, cpp ok, rs ok, zig ok, d ok
- point_dot  (8B {i32,i32} by value) : c ok, rs ok, zig FAIL (got=-2130706553 want=11)
                                       d SKIP (byval→ptr deref faults on riscv
                                              small struct; docs/19)
- blob_sum   (24B [24]u8 by value)   : c ok, cpp ok, rs ok, zig ok (300), d OK (300)
```

The **opposite** of Xtensa: Zig **passes** the large `blob_sum` here but **fails
`point_dot`**, the small two-`i32` struct. D's pattern flips relative to
Xtensa too: on RISC-V the >16-byte `Blob` happens to be passed by reference
in the C ABI itself, so D's universal `byval` *matches* — `d_blob_sum` PASSES.
The 8-byte `Point` would still go in registers per C, so D's pointer-deref
runs off into garbage, harness gates it as SKIP. The asymmetry is the proof
of docs/19's frontend-bug analysis: D is correct exactly when the C ABI is
*also* indirect.

## Why (the IR tells it)

| `point_dot(Point, Point)` arg | IR | machine |
|-------------------------------|----|---------|
| clang | `i32 ([2 x i32], [2 x i32])` | Point A in `a0,a1`; B in `a2,a3` |
| rust  | `i32 ([2 x i32], [2 x i32])` | same as clang |
| **zig** | `i32 ([2 x i64], [2 x i64])` | A in `a0,a1`; **B in `a4,a5`** |
| **D/LDC** | `i32 (byval ptr, byval ptr)` | both args pointer-passed; reads from caller's frame |

Zig lowers the 8-byte `extern struct { x: i32, y: i32 }` to **`[2 x i64]`** (16
bytes — each field widened) on RISC-V. So Zig reserves `a0..a3` for the first
`Point` and reads the second from `a4,a5`, while clang's driver placed it in
`a2,a3`. The bytes are read from the wrong registers → garbage. (Zig's
`make_point` *return* `{i32,i32}` and the large-struct `blob_sum` *by-reference*
`ptr` are both correct — it is specifically the small by-value struct *argument*.)

## The corrected cross-architecture picture

| by-value struct argument | Xtensa esp32 | RISC-V esp32c3 |
|--------------------------|--------------|----------------|
| small `{i32,i32}` (8 B, align 4) | zig **ok** | zig **BROKEN** (`[2 x i64]`) |
| `[24]u8` (24 B, align 1) | zig **BROKEN** (stack vs `[6 x i32]` regs) | zig **ok** (by-ref) |
| clang / rust / gcc | correct | correct |

So Zig's experimental ESP targets have **frontend C-ABI struct-lowering gaps on
both architectures** — different cases each — while Rust matches clang/gcc on
both. This is the concrete Zig⇔Rust ESP-maturity gap discussed in
[10-cabi-completeness.md](10-cabi-completeness.md). The shared backend gives a shared
ABI only where each frontend implements the platform C ABI correctly; Rust does,
Zig (for these WIP targets) does not yet.
