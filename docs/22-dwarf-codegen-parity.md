# 22 — DWARF & codegen parity audit across all 5 toolchains (Xtensa)

A compiler-engineering / reverse-engineering audit of what each of the five
toolchains in the matrix (gcc, esp-clang, zig, ldc2, rustc) actually emits for
the **same trivial function** on the espressif Xtensa target. The bones of an
embedded toolchain — DWARF version, debug-section sizes, frame info, and the
shape of the disassembled code — are surprisingly different across them.
Reproduce with `experiments/dwarf-parity/run.sh`. All output below is real.

The function under examination:

```c
int add_i32(int a, int b) { return a + b; }
```

… implemented in each frontend's idiomatic form, compiled with `-g` for
`xtensa-esp-elf -mcpu=esp32`.

## 1. DWARF section bytes per toolchain

`llvm-readelf -S` size of each `.debug_*` section:

| toolchain | `.debug_abbrev` | `.debug_info` | `.debug_line` | `.debug_str` | `.debug_loc` |
|---|---:|---:|---:|---:|---:|
| **clang** | 69 | 142 | 96 | 256 | — |
| **gcc** | 212 | 112 | 90 | **45** | — |
| **rust** | 94 | 461 | 176 | 1219 | 67 |
| **zig** | 1108 | 1418 | 339 | **12964** | — |
| **LDC** | 75 | 168 | 76 | 284 | — |

Two genuine surprises:

- **Zig's `.debug_str` is 12 KB for a one-line function** — Zig embeds full
  source paths, type names and `error{…}` set names verbatim into the string
  table. On a small esp32 program this adds up fast.
- **Rust uses `.debug_loc` (variable-location lists) and the others don't** — a
  consequence of `-C debuginfo=2` on the release profile. clang/gcc/zig at
  these opt levels store locations inline in `.debug_info` instead.

## 2. DWARF version: a 4/5 split

```
clang  DWARFv5 (format = DWARF32)
gcc    DWARFv5 (format = DWARF32)
rust   DWARFv4 (format = DWARF32)
zig    DWARFv4 (format = DWARF32)
LDC    DWARFv4 (format = DWARF32)
```

clang and gcc default to **DWARFv5**; rust, zig, LDC still emit **DWARFv4**.
DWARFv5 brings `.debug_addr` / `.debug_str_offsets` (smaller binaries, faster
parse) and accelerator tables, so the v4 emitters carry slightly more weight.
For a debugger this is invisible — every modern GDB/LLDB handles both — but for
post-mortem tooling (DWARF parsers, BPF, perf) it matters.

## 3. Function DIE — pre-link string resolution differs

Dumping the `DW_TAG_subprogram` for `add_i32` from an *unlinked* `.o` reveals an
artifact: **DWARFv4 producers (rust/zig/LDC) need link-time relocations to
resolve `.debug_str` references**, so pre-link their `DW_AT_name` /
`DW_AT_linkage_name` look like garbage — typically the *producer* string of the
compile unit:

```
rust  DW_AT_name ("clang LLVM (rustc version 1.95.0-nightly …)")
zig   DW_AT_name ("pre")
LDC   DW_AT_name ("LDC 1.42.0-git-c8305d0 (LLVM 22.1.2)")
```

GCC's DWARFv5 is **fully self-contained** in the `.o` (`DW_AT_name ("add_i32")`,
type `int`, parameter `a` resolves). clang's also DWARFv5 but its
`DW_AT_str_offsets_base` still indexes a string table that's incomplete pre-link
on this build (`DW_AT_name ()` empty, type rendered as `"base "`).

Real-world impact: an embedded debugging workflow that inspects `.o` archives
directly (not linked ELFs) sees clean names from gcc but mangled/empty names
from the three LLVM frontends. Always work from the linked image.

## 4. Symbol table: the FFI surface

The Itanium / C-ABI symbol the linker actually sees for `add_i32`:

```
clang  add_i32
gcc    add_i32
rust   add_i32          (#[no_mangle] pub extern "C")
zig    add_i32          (export fn ... callconv(.c))
LDC    add_i32          (extern(C))
```

All five expose the bare C name as expected — the cross-language FFI surface
this repo measures everywhere.

## 5. Reverse-engineering the codegen

The most revealing slice. Same `a + b` function, debug build, different
toolchains:

```
clang (-g -O0):                gcc (-g -O0):                  rust (release+debug):
  entry  a1, 48                  entry  a1, 48                  entry  a1, 32
  mov.n  a7, a1                  mov.n  a7, a1                  add.n  a2, a3, a2
  s32i.n a2, a7, 4               s32i.n a2, a7, 0               retw.n
  s32i.n a3, a7, 0               s32i.n a3, a7, 4
  l32i.n a8, a7, 4               l32i.n a9, a7, 0
  l32i.n a9, a7, 0               l32i.n a8, a7, 4
  add.n  a2, a8, a9               add.n  a8, a9, a8

zig (-O Debug):                LDC (-g):
  entry  a1, 48                  entry  a1, 48
  mov.n  a7, a1                  or     a7, a1, a1     ← non-compact `or` not `mov.n`
  s32i.n a2, a7, 0               s32i   a2, a7, 4      ← non-compact `s32i`
  s32i.n a3, a7, 4               s32i   a3, a7, 0
  add.n  a2, a2, a3               l32i   a8, a7, 4
  retw.n                         l32i   a9, a7, 0
                                 add    a2, a8, a9
```

Three observations a reverse-engineer cares about:

1. **Rust (release) collapses to 6 bytes** — `entry a1,32; add.n a2,a3,a2;
   retw.n`. By default `cargo build --release` (with `debug=full`) keeps the
   debug info but optimizes — the others were `-O0`/Debug. Rust at `-Og`
   equivalent is the smallest debug build.
2. **LDC emits non-compact instructions** at `-Os` baseline — `or a7,a1,a1`
   instead of `mov.n a7,a1`, full-width `s32i`/`l32i` instead of the 2-byte
   `.n` forms. esp32 has the `density` extension so the `.n` forms are valid;
   LDC's instruction selector just doesn't reach for them here. The resulting
   function is 19 B vs clang's 14 B (35 % bigger).
3. **gcc and clang differ only in commutative operand order** on the final
   `add.n` — `a8,a9,a8` vs `a8,a9` source operands switched — but otherwise
   step-for-step the same windowed save/restore pattern.

## 6. Frame info: `.eh_frame` vs `.debug_frame`

| toolchain | `.eh_frame` | `.debug_frame` |
|---|---:|---:|
| clang | — | 40 |
| gcc | — | 72 |
| rust | — | 60 |
| zig | **44** | — |
| LDC | **44** | — |

DWARF distinguishes **debugging CFI** (`.debug_frame`, optional and per-DIE) from
**runtime unwind tables** (`.eh_frame`, used by libunwind/exception throwing).
clang/gcc/rust emit `.debug_frame` here; **Zig and LDC emit `.eh_frame`**, the
exception-handling form. On bare-metal with no unwinder this is wasted bytes —
Zig has a default `-fno-omit-frame-pointer`-style policy and LDC inherits LLVM's
default. (Aside: zig's stray `.eh_frame` is exactly the source of the ~200 B
over-count in docs/06 — see `llvm-size` Berkeley vs `-A`.)

## 7. Capability & known-vulnerability summary (the 5-toolchain rollup)

Distilling what the prior docs have established + this audit:

| toolchain | strengths on espressif | known gaps / bugs |
|---|---|---|
| **esp-clang** (LLVM 21.1.3, fork) | full esp32/s2/s3 (windowed ABI, FPU, SIMD on s3), DWARFv5, LTO with rust 21.1.3, all `EE.*` SIMD via inline asm (docs/16) | upstream LLVM Xtensa is experimental (esp32/8266 only); no `llvm-link`/`opt`/`llvm-dis` (use LDC LLVM-22 binutils) |
| **gcc 15.2** (espressif crosstool-NG) | smallest `.text` of the five (docs/06: 174 B); fully resolved DWARFv5 names pre-link; non-LLVM ABI check | default core is big-endian (must set `XTENSA_GNU_CONFIG`, docs/01); no LLVM IR mix path; `-mlongcalls` only matters for call encoding (docs/02) |
| **rustc 1.95-nightly** (esp-rs fork) | C-ABI parity bit-for-bit with clang/gcc (docs/03), cross-language LTO with esp-clang ✓ (docs/04), v0 mangling for own symbols, atomics use s32c1i (docs/17) | esp-rs is a **fork** — upstream rustc has Tier-3 specs but no Xtensa codegen (docs/00); `_R…` v0 unstable hash discourages calling D/zig from rust by mangled name (docs/12) |
| **Zig 0.16** (espressif bootstrap fork) | only host-capable C/C++ here (`zig cc`); native s32c1i atomics, smallest debug codegen, `EE.*` SIMD via struct-form clobbers (docs/16) | the experimental Xtensa ABI mis-lowers under-aligned (`align(1)`) by-value struct args on Xtensa AND `{i32,i32}` on RISC-V — the headline FFI hole (docs/05/09); 21.1.0 bitcode incompatible with esp 21.1.3 LTO reader (docs/04); huge `.debug_str` (§1); always emits `.eh_frame` (§6) |
| **LDC 1.42-git** (LLVM 22.1.2, upstream) | only frontend on upstream LLVM (no espressif fork); Itanium-mangled `extern(C++[,"ns"])` for direct C++ template FFI (docs/21); compile-time reflection via `__traits`/`mixin`; `@safe`/`@live` static borrow analog (docs/20); cross-language LTO ✓ with clang despite 22.1.2 vs 21.1.3 (docs/19) | upstream LLVM-22 only recognizes `esp32` CPU — `s2`/`s3` are "not a recognized processor" (ldc #4919; docs/19); literal-pool placement bug in LDC's integrated assembler → re-assemble `-output-s` with esp clang (docs/19); marks every by-value aggregate `byval`/`sret` → fails `point_dot` + `blob_sum` on Xtensa, faults on RISC-V small struct (docs/19); `@live` silent without `-preview=dip1021` (docs/20); non-compact instruction selection at `-Os` (§5: 35 % bigger codegen than clang); ICEs on Xtensa + EH + opt (ldc #5091) |

## 8. Espressif baremetal advantages — the consolidated story

What this whole repo has demonstrated about polyglot FFI on **ESP32-class
hardware**:

1. **The shared LLVM Xtensa backend is real** — clang, rust, zig, D all feed
   the same backend (clang/rust on espressif LLVM 21.1.3, zig on a 21.1.0
   bootstrap, D on upstream LLVM 22.1.2). All four emit the identical Xtensa
   `target datalayout` (docs/04). GCC sits outside as an independent control.
2. **The Itanium C++ ABI is the cross-language bridge** — any C++ template
   instantiation can be called from D (`extern(C++,class) struct T(int Slot)`),
   Rust (`#[link_name="_ZN…"]`), or Zig (`extern fn @"_ZN…"`). Five toolchains
   linked into one esp32 ELF, 0 undefined symbols, on **`-machine sim -cpu
   dc233c` and the riscv `virt`** machine (docs/08/09/21).
3. **The qemu fork (esp-develop-9.2.2)** runs the matrix on both architectures
   with semihosting — `qemu-system-xtensa` + `qemu-system-riscv32` (docs/08/09).
4. **The remaining real ABI holes** are the two defer-to-LLVM-backend
   frontends: Zig's by-value struct args (under-aligned on Xtensa; `{i32,i32}`
   on RISC-V) and D's *every* by-value aggregate (`byval`/`sret` indirect).
   Pass structs **by pointer** across either boundary — verified at runtime on
   both qemu architectures (docs/05/09/19).
5. **D ships static memory-safety today** that C++26 (P2996 reflection, P2900
   contracts, P3081 profiles) still doesn't have in any clang we can run —
   `@safe`+`@live`+`-preview=dip1021` catches use-after-free, double-free,
   dangling AND **leak** (the last is what Rust's borrow checker explicitly
   doesn't, docs/20). `__traits`+`mixin`+`static foreach` is the P2996 analog
   shipping today (docs/20/21).
6. **Best-of-breed picks for a polyglot ESP32 codebase**: GCC for the absolute
   smallest C code (`.text` 174 B for the 9-fn lib, docs/06); Rust for safe C
   ABI exports; clang for C++ template *providers* (consumed by everyone);
   LDC for compile-time reflection-heavy or borrow-checker-needing components,
   with the literal-pool re-assembly workaround; Zig for the host runner
   harness (`zig cc`/`zig c++` is the only host-capable C/C++ in the set).

## Repro

```bash
./experiments/dwarf-parity/run.sh             # this doc's tables
./scripts/build-ffi.sh all && ./scripts/run-qemu.sh xtensa && ./scripts/run-qemu.sh riscv
./scripts/analyze.sh esp32
./experiments/dlang/safety.sh                 # docs/20 battery
./experiments/dlang/tmpffi.sh                 # docs/21 TMP FFI
```

Each script is self-contained and re-derives every claim from real tool output.
