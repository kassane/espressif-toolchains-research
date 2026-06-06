# 08 — Executing on emulated Xtensa (qemu)

The analysis in docs 03–06 is static (link + disassembly). This page is the
attempt to make it dynamic by running the code on the **Espressif qemu fork**.

## Toolchain

- **espressif/qemu** `esp-develop-9.2.2-20260417`, two softmmu tarballs:
  `qemu-xtensa-softmmu-…` and `qemu-riscv32-softmmu-…` (x86_64-linux-gnu),
  extracted to `$TC/qemu` (gives `qemu-system-xtensa` and `qemu-system-riscv32`).
- The binary needs `libSDL2-2.0.so.0` and `libslirp.so.0` even headless:
  `apt-get install -y libsdl2-2.0-0 libslirp0`.
- `qemu-system-xtensa` machines: `esp32`, `esp32s3` (Espressif), and generic
  `sim` / `lx60` / `lx200`; CPU cores include `esp32`, `esp32s3`, `dc232b`,
  `dc233c`.

## What works: semihosting smoke test

`experiments/qemu-run` is a minimal bare-metal harness:

- `start.S` — a `.reset` stub at the `sim` core reset vector `0xFE000000`
  (`j _start`), a window overflow/underflow vector table, and `_start` which sets
  `VECBASE`, `WINDOWBASE/WINDOWSTART`, `PS.WOE=1` and the stack pointer, then calls
  `xmain`.
- `sim.ld` — places `.text` at `0xFE000000` (sysrom0) and data/stack in
  sysram0 (`0x00000000`), matching the `sim` machine's memory map.
- `semihost.h` — output/exit via the Xtensa `simcall` opcode (qemu semihosting:
  `a2`=call#, `SYS_write`=4, `SYS_exit`=1).

```
$ scripts/run-qemu.sh
===== hello (semihosting smoke test) =====
HELLO from qemu-system-xtensa
```

This **runs real Xtensa machine code emitted by the espressif toolchain on an
emulated core and gets I/O back** — the harness, memory map, reset path,
window-ABI enable and semihosting are all working.

(Note: qemu's semihosting console swallows the very first output byte after
reset, so messages lead with a `\n`.)

## The full FFI matrix run — historical ABI bugs, live (now closed on the canonical lane)

`qemu_main.c` calls the `c_/cpp_/rs_/zig_/d_` functions (compiled by
**esp-clang** for C, **esp-clang++** for C++, **rustc** for Rust, **zig
build-obj** for Zig, and **LDC** for D — `scripts/build-ffi.sh esp32` is the
one-step setup) and reports per language. `scripts/run-qemu.sh` runs it on
`-machine sim -cpu dc233c`:

```
== FFI runtime on emulated ESP core (qemu) ==
- scalar add_i32(3,4)==7 [expect all ok]:
 c    ok (7)
 cpp  ok (7)
 rs   ok (7)
 zig  ok (7)
 d    ok (7)
- point_dot: 8B struct by value ==11 [xtensa: d FAIL; riscv: zig FAIL]:
 c    ok (11)
 rs   ok (11)
 zig  ok (11)
 d    FAIL (got=4548 want=11)
- blob_sum: 24B struct by value ==300 [xtensa: zig+d FAIL; riscv: ok]:
 c    ok (300)
 cpp  ok (300)
 rs   ok (300)
 zig  FAIL (got=409 want=300)
 d    FAIL (got=695 want=300)
- blob_sum BY POINTER ==300 [expect all ok incl. d]:
 c    ok (300)
 zig  ok (300)
 d    ok (300)
total failures: 3
```

This is the docs/05 + docs/19 predictions confirmed **at runtime on an emulated
Xtensa core**: scalars interoperate across every FFI-matrix language. The
output above is the **legacy-lane** capture (`$ZIG_016` + `$LDC2_UPSTREAM`)
preserved here as the bug-demonstration baseline; the align-1 `Blob` by value
was **misread by Zig** (`409 ≠ 300` — stack-spilled under-aligned struct while
the **clang** driver passed it in registers), and **D/LDC** failed *both* the
align-4 `Point` (`point_dot`) and `blob_sum` because the pre-fix DMD-ABI
lowering marked every aggregate `byval`/`sret`, diverging more broadly than
Zig (docs/19). **rust** and **gcc**-built C agreed with clang on every row,
so they're not visibly distinct in the output table. Passing the same struct
**by pointer** worked for all. On the canonical lane (`$ZIG` 0.17 + `$LDC2`
1.42.0, post-2026-05-30 re-upload) qemu reports **0 D failures and 0 Zig
failures** — every by-value case the legacy lanes failed now passes.
(The `got=` values on the FAIL rows are whatever stale data sat in the stack
slots, so they vary run-to-run; the *mismatch* is the point.) Static
disassembly (docs/05, docs/19) and live execution agree.

### Two bring-up issues solved to get here

1. **Window exceptions need handlers.** Deep windowed-ABI nesting raises
   WindowOverflow/Underflow; `start.S` installs the canonical XEA2 handlers at
   `VECBASE+0x000..0x140`, sets `VECBASE`, and pads the table to `0x400` so
   program code never overlaps a vector slot.
2. **Interrupts must be masked** (`PS.INTLEVEL=15`) or a stray IRQ vectors into
   the (then-unhandled) exception slots.
3. **ISA mismatch:** the `dc233c` sim core lacks esp32's `mul32high` (`muluh`),
   which the compiler emits for divide-by-10. The semihosting `putdec` therefore
   avoids `/` and `%` (subtraction + powers-of-ten table). The FFI functions
   under test use only common Xtensa ISA, so the esp32-built objects run as-is.

(`-cpu esp32` itself can't be used on the `sim` machine: it resets to the esp32
vector `0x50000000`, which `sim` doesn't map. A full `-machine esp32` + ROM +
flash-image run is the way to exercise the exact esp32 core, left as follow-up.)

## RISC-V too (`run-qemu.sh riscv`)

`qemu-system-riscv32 -machine virt` runs the same matrix for ESP32-C3 — far
simpler (no register windows, standard semihosting via the `ebreak` sequence,
ELF at `0x80000000`). It historically surfaced a **different** Zig 0.16 bug
than Xtensa (`zig point_dot FAIL` on the small `{i32,i32}` struct, while
`blob_sum` passed); **closed in Zig 0.17** (canonical `$ZIG`) — the legacy
`$ZIG_016` lane still reproduces it. See [docs/09](09-riscv.md).

## TinyGo on qemu — different harness, different boot

TinyGo's qemu story is **not** a drop-in to this `sim`/`virt` harness because
TinyGo emits a flash image (`tinygo build -target=esp32-coreboard-v2 -o
hello.bin`) — a ~2.6 KB raw binary containing TinyGo's startup, the Go
runtime, and the user code, intended to be flashed at offset `0x10000` of an
ESP32 SPI flash device. The Espressif qemu **does** ship the `-machine esp32`
and `-machine esp32s3` targets, but they require a full flash image (2/4/8/16
MB) including the **bootloader** at `0x0` and the partition table at `0x8000`:

```
$ qemu-system-xtensa -machine esp32 -drive file=hello.bin,if=mtd,format=raw
qemu-system-xtensa: Error: only 2, 4, 8, 16 MB flash images are supported
```

The right path is `esptool merge_bin` to pad bootloader + partition table +
TinyGo's app into a 4 MB flash image, then pass that to qemu — which means
pulling in ESP-IDF for the bootloader binary. That's out of scope for the
thin docs/08 semihosting harness. **What this means in practice**: TinyGo
exercises the same espressif Xtensa backend (`-mcpu=esp32`, windowed ABI,
`s32c1i` atomics) the FFI-matrix toolchains use — verified statically in
docs/22 §g and the `experiments/tinygo/run.sh` probe — but the runtime
proof for TinyGo is "flash an esp32-coreboard-v2 board" or "build a full
flash image and use `-machine esp32`", not the sim/virt path the rest of
this doc uses.

(The other five FFI-matrix toolchains — esp-clang, gcc, rustc, zig, LDC —
each produce a relocatable .o that the same `qemu_main.c` harness can
co-link, which is why the matrix runs together under one `dc233c` boot.)
