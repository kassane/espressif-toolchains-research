# 22 — DWARF & codegen parity audit across all 6 toolchains (Xtensa)

A compiler-engineering / reverse-engineering audit of what each of the six
toolchains in the matrix (gcc, esp-clang, zig, ldc2, rustc, **TinyGo**)
actually emits for the **same trivial function** on the espressif Xtensa
target. The bones of an embedded toolchain — DWARF version, debug-section
sizes, frame info, and the shape of the disassembled code — are surprisingly
different across them. Reproduce with `experiments/dwarf-parity/run.sh`
(TinyGo is reported in §g separately; its byte counts include the whole
program because TinyGo doesn't emit relocatable `.o`, docs/24). All output
below is real.

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
| **LDC** (fork, 21.1.3) | 69 | 162 | 76 | 278 | — |

(LDC's row used to be 75/168/76/284 on the upstream-LLVM-22 build; the
espressif-fork LDC produces slightly tighter DWARF. See
[docs/23](23-ldc-espressif-fork.md) §(f) for the side-by-side.)

TinyGo is reported separately (§g) because its `.debug_*` sections cover the
**full firmware** — Go runtime + standard library + the function — not the
single-function `.o` of the other five rows.

Two genuine surprises:

- **Zig's `.debug_str` is 12 KB for a one-line function** — Zig embeds full
  source paths, type names and `error{…}` set names verbatim into the string
  table. On a small esp32 program this adds up fast.
- **Rust uses `.debug_loc` (variable-location lists) and the others don't** — a
  consequence of `-C debuginfo=2` on the release profile. clang/gcc/zig at
  these opt levels store locations inline in `.debug_info` instead.

## 2. DWARF version: a 4/5 split (now 2-of-6 emit v5)

```
clang   DWARFv5 (format = DWARF32)
gcc     DWARFv5 (format = DWARF32)
rust    DWARFv4 (format = DWARF32)
zig     DWARFv4 (format = DWARF32)
LDC     DWARFv4 (format = DWARF32)
TinyGo  DWARFv4 (format = DWARF32)
```

clang and gcc default to **DWARFv5**; rust, zig, LDC, TinyGo still emit
**DWARFv4**. DWARFv5 brings `.debug_addr` / `.debug_str_offsets` (smaller
binaries, faster parse) and accelerator tables, so the v4 emitters carry
slightly more weight. For a debugger this is invisible — every modern GDB/LLDB
handles both — but for post-mortem tooling (DWARF parsers, BPF, perf) it
matters. TinyGo's producer DIE reads `clang version 20.1.1 (tinygo-org/llvm-project ...)`,
pinning it to a third LLVM family on top of the 21.1.x trio and the LDC-fork's
21.1.3.

## 3. Function DIE — pre-link string resolution differs

Dumping the `DW_TAG_subprogram` for `add_i32` from an *unlinked* `.o` reveals an
artifact: **DWARFv4 producers (rust/zig/LDC) need link-time relocations to
resolve `.debug_str` references**, so pre-link their `DW_AT_name` /
`DW_AT_linkage_name` look like garbage — typically the *producer* string of the
compile unit:

```
rust    DW_AT_name ("clang LLVM (rustc version 1.95.0-nightly …)")
zig     DW_AT_name ("pre")
LDC     DW_AT_name ("LDC 1.42.0 (LLVM 22.1.4)")     # canonical post-2026-05-30; was "LDC 1.42.0-git-04a6c8b (LLVM 21.1.3)"
TinyGo  DW_AT_producer ("clang version 20.1.1 (tinygo-org/llvm-project 6707598…)")  [linked ELF]
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
clang   add_i32
gcc     add_i32
rust    add_i32          (#[no_mangle] pub extern "C")
zig     add_i32          (export fn ... callconv(.c))
LDC     add_i32          (extern(C))
TinyGo  main.go_add_i32  (//go:noinline + //export — package-qualified by Go's mangling)
```

The first five expose the bare C name as expected — the cross-language FFI
surface this repo measures everywhere. TinyGo mangles as `<package>.<func>`
even when `//export` is present (the `//export` directive aliases a C-ABI
name only when the function is actually referenced as cgo, which doesn't
apply on baremetal Xtensa). For C-callable Go on baremetal you instead use
`//go:linkname` or build with a host-side cgo shim.

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

zig (-O Debug):                LDC (-g):                      TinyGo (-opt=0, linked):
  entry  a1, 48                  entry  a1, 48                  entry  a1, 32
  mov.n  a7, a1                  mov.n  a7, a1     ← =clang     add.n  a2, a2, a3
  s32i.n a2, a7, 0               s32i.n a2, a7, 4               retw.n
  s32i.n a3, a7, 4               s32i.n a3, a7, 0
  add.n  a2, a2, a3               l32i.n a8, a7, 4
  retw.n                          l32i.n a9, a7, 0
                                  add.n  a2, a8, a9
```

Four observations a reverse-engineer cares about:

1. **Rust (release) AND TinyGo (-opt=0) both collapse to 7 bytes** — `entry
   a1,32; add.n; retw.n`. Rust gets there because `cargo build --release` (with
   `debug=full`) keeps the debug info but optimizes; TinyGo gets there because
   even at `-opt=0` it always runs through `--lto-O2` (TinyGo's link mode), and
   the LTO pipeline elides the prologue spill the others emit at `-O0`/Debug.
   Net: at the lowest meaningful "debug build" of each toolchain, Rust and
   TinyGo emit the tightest function.
2. **LDC's codegen now matches clang's** — the espressif-fork LDC (LLVM 21.1.3)
   reaches for `mov.n`/`s32i.n`/`l32i.n` compact forms; the function is 17 B,
   byte-identical to clang. The upstream-LLVM-22 LDC used to emit non-compact
   `or`/`s32i`/`l32i` and weigh 19 B (35 % bigger; that finding is preserved in
   [docs/23](23-ldc-espressif-fork.md) §(g) on the comparison toolchain).
3. **gcc and clang differ only in commutative operand order** on the final
   `add.n` — `a8,a9,a8` vs `a8,a9` source operands switched — but otherwise
   step-for-step the same windowed save/restore pattern.
4. **TinyGo's bitcode reveals the calling convention** — `define internal
   fastcc i32 @main.go_add_i32(i32 %a, i32 %b)` — Go uses `fastcc` (the LLVM
   private fast CC), NOT C-ABI. The Xtensa register assignment ends up the
   same (a2/a3 inputs, a2 output) because `fastcc` defaults to the platform
   ABI when nothing custom is specified for the target. This is why a TinyGo
   function call FROM Go works on Xtensa but co-linking with C is non-trivial
   (you'd need an explicit C-ABI wrapper).

## 6. Frame info: `.eh_frame` vs `.debug_frame`

| toolchain | `.eh_frame` | `.debug_frame` |
|---|---:|---:|
| clang | — | 40 |
| gcc | — | 72 |
| rust | — | 60 |
| zig 0.17 (canonical) | **220** | — |
| LDC (canonical) | **40** | — |
| TinyGo | (in linked ELF; see §g) | — |

(Numbers are the 9-fn lib `.text`-only single object, `llvm-size -A`. Zig 0.17's
220 B `.eh_frame` is much bigger than the 44 B figure that was here previously
— that was the 0.16 baseline; 0.17 with the struct-ABI fix routes more
prologue work through `.eh_frame`. LDC dropped from 44 → 40 B on the canonical
21.1.3 fork. Both numbers re-measured at `experiments/dlang/safety.sh`-time on
the canonical lane.)

DWARF distinguishes **debugging CFI** (`.debug_frame`, optional and per-DIE) from
**runtime unwind tables** (`.eh_frame`, used by libunwind/exception throwing).
clang/gcc/rust emit `.debug_frame` here; **Zig and LDC emit `.eh_frame`**, the
exception-handling form. On bare-metal with no unwinder this is wasted bytes —
Zig has a default `-fno-omit-frame-pointer`-style policy and LDC inherits LLVM's
default. (Aside: zig's stray `.eh_frame` is exactly the source of the ~200 B
over-count in docs/06 — see `llvm-size` Berkeley vs `-A`.) TinyGo emits
`.eh_frame` in the linked ELF too, alongside the conservative-GC stack-walk
metadata its runtime needs; the byte count isn't comparable here because the
section covers every function in the firmware.

## 7. Capability & known-vulnerability summary (the 5-toolchain rollup)

Distilling what the prior docs have established + this audit:

| toolchain | strengths on espressif | known gaps / bugs |
|---|---|---|
| **esp-clang** (LLVM 21.1.3, fork) | full esp32/s2/s3 (windowed ABI, FPU, SIMD on s3), DWARFv5, LTO with rust 21.1.3, all `EE.*` SIMD via inline asm (docs/16) | upstream LLVM Xtensa is experimental (esp32/8266 only); no `llvm-link`/`opt`/`llvm-dis` (use LDC LLVM-22 binutils) |
| **gcc 15.2** (espressif crosstool-NG) | smallest `.text` in the matrix (docs/06: 174 B); fully resolved DWARFv5 names pre-link; non-LLVM ABI check | default core is big-endian (must set `XTENSA_GNU_CONFIG`, docs/01); no LLVM IR mix path; `-mlongcalls` only matters for call encoding (docs/02) |
| **rustc 1.95-nightly** (esp-rs fork) | C-ABI parity bit-for-bit with clang/gcc (docs/03), cross-language LTO with esp-clang ✓ (docs/04), v0 mangling for own symbols, atomics use s32c1i (docs/17) | esp-rs is a **fork** — upstream rustc has Tier-3 specs but no Xtensa codegen (docs/00); `_R…` v0 unstable hash discourages calling D/zig from rust by mangled name (docs/12) |
| **Zig 0.17.0-xtensa** (espressif bootstrap fork, `$ZIG` canonical) | only host-capable C/C++ here (`zig cc`/`zig c++`, now clang 22.1.4 / libc++ 22 — handles C++26 P2686R5); native s32c1i atomics, smallest debug codegen, `EE.*` SIMD via struct-form clobbers (docs/16); **frontend `[N x i32]` flattening fixes the 0.16 by-value struct ABI hole** on both Xtensa and RISC-V (docs/05) | 22.1.4 bitcode incompatible with esp 21.1.3 LTO reader (docs/04 — the LLVM-21 vs LLVM-22 cluster split); huge `.debug_str` (§1); always emits `.eh_frame` (§6). Legacy `$ZIG_016` lane keeps the docs/05 + docs/09 break for repro purposes |
| **LDC 1.42.0** (LLVM 22.1.4, espressif fork — docs/23; 2026-05-30 maintainer re-upload) | canonical 5th frontend; Itanium-mangled `extern(C++[,"ns"])` for direct C++ template FFI (docs/21); compile-time reflection via `__traits`/`mixin`; `@safe`/`@live` static borrow analog (docs/20); **frontend `[N x i32]` aggregate lowering closes the universal byval/sret bug** (docs/05 §"LDC 1.42 status", docs/19, /23) — `d_point_dot` is byte-identical to `c_point_dot`; first-class esp32/s2/s3 `-mcpu`; direct `ldc2 -c` -> `ld.lld` still works (no re-assembly) | `cent`/`ucent` keywords formally obsoleted, no native 128-bit int in `-betterC` (docs/17 §g-D); `@live` silent without `-preview=dip1021` (docs/20); ICEs on Xtensa + EH + opt (ldc #5091); LTO now in the **LLVM-22 cluster** (cross-language LTO with clang/rust now fails since LDC moved out of the 21.1.3 cluster — use `$LDC_LLVM_DIR`'s lld for LTO with zig instead) |
| **TinyGo v0.41.1** (LLVM 20.1.1, bundled — docs/24) | bundled LLVM-20 is the only LLVM-20 in the matrix; targets esp32 + s3 + c3 (no s2); datalayout byte-identical to the 21.1.x trio; codegen at `-opt=0` collapses to clang/Rust-class 7-byte `add_i32`; `+atomctl/+memctl/+timerint` peripheral-control features not present in esp-clang's `-mcpu=esp32` set; pre-built `picolibc` + `compiler-rt-xtensa-esp32` shipped; conservative GC + cooperative scheduler in the runtime | **whole-program compiler** — no `-c` relocatable mode outside wasm, so the firmware is the unit (can't join the FFI matrix, docs/24); functions C-mangled as `<package>.<func>` (`main.go_add_i32`), not the bare C name; uses `fastcc` LLVM CC internally; `//export` doesn't make a function externally linkable on baremetal Xtensa; `-x` and stdout/stderr merge bug (`2>&1` truncates the log to "package command-line-arguments" and reports rc=1; split streams to work around it); files starting with `_` are silently ignored even when named on the command line |

## 8. Espressif baremetal advantages — the consolidated story

What this whole repo has demonstrated about polyglot FFI on **ESP32-class
hardware**:

1. **The shared LLVM Xtensa backend is real and now spans every LLVM frontend in this matrix**
   — clang, rust, **D** (since docs/23) all on espressif LLVM **21.1.3**; zig
   0.17 bundles LLVM **22.1.4** (the canonical `$ZIG`; the legacy `$ZIG_016` is
   on 21.1.0); **TinyGo** (docs/24) on its own bundled LLVM **20.1.1**.
   All of them emit the byte-identical Xtensa `target datalayout`
   (`e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32`, docs/04 + docs/24 §c). GCC
   sits outside as a non-LLVM independent control.
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
   smallest C code (`.text` 201 B for the 9-fn lib, docs/06); Rust for safe C
   ABI exports; clang for C++ template *providers* (consumed by everyone);
   LDC for compile-time reflection-heavy or borrow-checker-needing components
   (direct `-c` since docs/23, codegen matches clang); Zig for the host runner
   harness (`zig cc`/`zig c++` is the only host-capable C/C++ in the set);
   **TinyGo for standalone Go firmware** on esp32/s3/c3 (whole-program — not
   co-linkable with the others, but tightest debug codegen at -opt=0, docs/24).

## §g — TinyGo addendum (the 6th toolchain, with caveats)

TinyGo can't join §1's section-bytes table at apples-to-apples scale because
its linked ELF is the *whole firmware*: a single `int32` add accumulates
60 KB `.debug_info`, 46 KB `.debug_str`, 32 KB `.debug_loc`, 18 KB
`.debug_pubnames`, etc. — covering the Go runtime + standard library + scheduler
+ GC, plus the function itself. So §1 reports five rows; §g reports TinyGo's
function-level evidence in the same RE form:

```
TinyGo  DWARFv4   producer: "clang version 20.1.1 (tinygo-org/llvm-project 6707598…)"
TinyGo  go_add_i32 (-opt=0, linked ELF, main.go_add_i32):
        entry  a1, 32
        add.n  a2, a2, a3
        retw.n
TinyGo  bitcode IR signature: define internal fastcc i32 @main.go_add_i32(i32 %a, i32 %b)
TinyGo  symbol mangling: main.go_add_i32  (package-qualified Go scheme, not C)
```

The function lands at 7 bytes — tied with Rust release for tightest debug
codegen — using the exact same Xtensa `entry/add.n/retw.n` sequence. `fastcc`
in the IR confirms TinyGo doesn't enter `add_i32` via the C calling convention;
nothing about Xtensa's a2..a7 register window changes, but a C caller wanting
to invoke `main.go_add_i32` would need an explicit wrapper. The
`experiments/dwarf-parity/run.sh §g` block preserves TinyGo's `-work` work
dir and inspects the intermediate `main` ELF (the relocatable `main.o` is
LLVM bitcode, not yet an ELF, also re-runnable).

## Repro

```bash
./experiments/dwarf-parity/run.sh             # this doc's tables
./scripts/build-ffi.sh all && ./scripts/run-qemu.sh xtensa && ./scripts/run-qemu.sh riscv
./scripts/analyze.sh esp32
./experiments/dlang/safety.sh                 # docs/20 battery
./experiments/dlang/tmpffi.sh                 # docs/21 TMP FFI
```

Each script is self-contained and re-derives every claim from real tool output.
