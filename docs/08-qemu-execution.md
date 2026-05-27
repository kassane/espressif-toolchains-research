# 08 — Executing on emulated Xtensa (qemu)

The analysis in docs 03–06 is static (link + disassembly). This page is the
attempt to make it dynamic by running the code on the **Espressif qemu fork**.

## Toolchain

- **espressif/qemu** `esp-develop-9.2.2-20260417`,
  asset `qemu-xtensa-softmmu-esp_develop_9.2.2_20260417-x86_64-linux-gnu.tar.xz`
  (download URL in the repo history; extracted to `$TC/qemu`).
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

## What doesn't (yet): the full FFI matrix run

`qemu_main.c` calls `c_/cpp_/rs_/zig_` functions and reports per language. It
passes the first checks then hangs. The exception log
(`-d int`) shows the window overflow/underflow handlers firing **once**, then an
unhandled general exception cascading into a **double-exception loop**:

```
do_interrupt(5)  pc=fe006a15   ; window handler runs
do_interrupt(10) pc=fe006a4e
do_interrupt(12) pc=fe0007fa   ; then loops here ~forever
```

Root cause: the harness installs only the **window** vectors, not the
kernel/user/double **exception** vectors. Deep windowed-ABI call nesting plus the
library runtime needs the full XEA2 exception vector table and handlers (or a
`-mabi=call0` rebuild that avoids register windows entirely). That is a complete
bare-metal RTOS-style bring-up — out of scope for this static-ABI study, and it
would only re-confirm what the disassembly already proves.

## Status & options to finish it

The runtime execution is **not required** for the conclusions: the ABI agreement
(and the under-aligned-struct divergence) is established statically and
unambiguously in docs 03–05. To complete a runtime demonstration later, easiest
first:

1. **Use `-machine esp32` with the real ROM** (`esp32-v3-rom.bin` ships in the
   qemu package) — the ROM sets up vectors/handlers — packaged as a proper
   esp-idf flash image.
2. **Add the XEA2 kernel/user/double exception vectors** to `start.S` and a
   minimal handler, extending the window-only table already present.
3. **Rebuild the matrix with `-mabi=call0`** (no register windows ⇒ no window
   exceptions) for a simpler bring-up — at the cost of testing the call0 rather
   than the default windowed ABI.

The expected runtime result, once it executes, is the docs/05 prediction: scalar
and align-4 struct calls pass for all four languages; the align-1 `blob_sum`
by-value call fails for Zig only.
