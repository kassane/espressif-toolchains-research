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

## The full FFI matrix run — and the ABI bug, live

`qemu_main.c` calls the `c_/cpp_/rs_/zig_/d_` functions and reports per language.
`scripts/run-qemu.sh` runs it on `-machine sim -cpu dc233c`:

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
Xtensa core**: scalars interoperate across every FFI-matrix language; the align-1 `Blob`
by value is **misread by Zig** (`409 ≠ 300` — stack-spilled under-aligned struct
while the clang driver passed it in registers). **D** fails *both* the align-4
`Point` (`point_dot`) and `blob_sum` — it marks every aggregate `byval`/`sret`, so
it diverges more broadly than Zig (docs/19). Passing the same struct **by
pointer** works for all. (The `got=` values on the FAIL rows are whatever stale
data sat in the stack slots, so they vary run-to-run; the *mismatch* is the
point.) Static disassembly (docs/05, docs/19) and live execution agree.

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
ELF at `0x80000000`). It surfaces a **different** Zig bug than Xtensa
(`zig point_dot FAIL` on the small `{i32,i32}` struct, while `blob_sum` passes);
see [docs/09](09-riscv.md).
