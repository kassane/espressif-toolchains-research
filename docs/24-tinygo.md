# 24 — TinyGo on Xtensa: a 6th toolchain, with a hard interop boundary

[TinyGo](https://github.com/tinygo-org/tinygo) is a Go-to-LLVM compiler for
embedded targets. v0.41.1 ships with its own bundled **LLVM 20.1.1** (a third
LLVM family in the matrix, after the 21.1.x trio and the upstream-22 LDC), and
its target list includes `esp32-coreboard-v2` / `esp32-generic` /
`esp32s3-generic` / `esp32c3-generic` and a handful of board specifics — **but
no esp32-s2**.

Why TinyGo isn't a drop-in 6th column in `experiments/ffi-matrix`: TinyGo is a
**whole-program compiler**. It always builds a firmware (`.bin` flash image for
ESP32, or a kernel ELF on other targets) — there's no `-c` flag for relocatable
objects, and `-buildmode=c-shared` is gated to wasm only. So you can't co-link a
TinyGo object with clang/rust/zig/D/gcc objects under `ld.lld -T xtensa.ld` the
way the five LLVM/GCC frontends co-link. The exploration belongs in
`experiments/tinygo/run.sh` instead, which pins what TinyGo CAN do on Xtensa
and where the boundary is.

## What `experiments/tinygo/run.sh` measures

### (a) Version + esp targets
```
tinygo version 0.41.1 linux/amd64 (using go version go1.24.7 and LLVM version 20.1.1)
esp targets: adafruit-esp32-feather-v2 esp-c3-32s-kit esp32-c3-devkit-rust-1
             esp32-coreboard-v2 esp32-generic esp32-mini32 esp32c3-12f
             esp32c3-generic esp32c3-supermini esp32s3-generic esp32s3-supermini
             makerfabs-esp32c3spi35 qtpy-esp32c3 xiao-esp32c3 xiao-esp32s3
```
ESP32 + ESP32-S3 + ESP32-C3 — three of the four families this repo covers
(esp32s2 absent).

### (b) Implicit `-mattr` for esp32: nearly the same C-ABI essentials

TinyGo's `-x` reveals the LLVM `-mattr` it applies. Compare with
`esp-clang`'s implicit target-features for `-mcpu=esp32`:

|  | TinyGo only | both | esp-clang only |
|---|---|---|---|
| feature | `+atomctl`, `+memctl`, `+timerint` | `+bool, +clamps, +coprocessor, +debug, +density, +dfpaccel, +div32, +exception, +fp, +highpriinterrupts, +interrupt, +loop, +mac16, +minmax, +miscsr, +mul32, +mul32high, +nsa, +prid, +regprotect, +rvector, +s32c1i, +sext, +threadptr, +windowed` | `+dcache, +expstate, +highpriinterrupts-level7, +mul16, +timers3` |

The disjoint parts are mostly cache/timer/peripheral-control bits, not codegen
ABI bits. The **C-ABI essentials** — `+windowed` (windowed register-stack call
convention), `+density` (2-byte compact insns), `+mul32`, `+div32`, `+s32c1i`
(native CAS) — are in both. So a TinyGo image and a clang/rust/zig/D image
agree on call-shape and atomic primitives.

### (c) Triple + datalayout
```
LLVM triple:       xtensa
GOARCH:            arm
TinyGo IR datalayout: e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32
clang/rust/zig/D ref: e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32
```
Byte-identical datalayout — same memory model. The triple is just `xtensa` (no
`-esp-elf` suffix); `GOARCH` is `arm` because Go's `runtime/GOARCH` doesn't
include `xtensa` as a value, so TinyGo borrows `arm` for the build-tag plumbing.

### (d) The output format
TinyGo emits an **ESP32 flash image** (header `e9 02 02 1f`), not a relocatable
ELF. `llvm-nm` / `llvm-objdump` can't parse it. To get a relocatable .o you'd
need either a TinyGo flag that doesn't exist (`-buildmode=c-shared` is wasm-
only), or to fork TinyGo's link driver. So the firmware is the unit of
deployment, not a contributable object.

### (e) Struct ABI in the IR
```
define i32 @go_point_dot(i32 %a.X, i32 %a.Y, i32 %b.X, i32 %b.Y)
```
TinyGo **flattens** the struct into individual scalar fields at the IR level —
closer to clang's `[2 x i32]` coercion than to Zig/D's "direct %T" pattern.
Each i32 lands in `a2`/`a3`/`a4`/`a5` per the Xtensa SysV-style ABI, so the
machine ABI matches clang exactly. That makes TinyGo's `//export go_*` C-ABI
calls trivially compatible with C consumers, IF you could link them.

## Why the LLVM-20 version skew matters less than you'd expect

TinyGo on LLVM 20.1.1, the others on 21.1.x / 22.1.2: a *cross-language LTO*
between TinyGo and any other frontend would fail (we don't have LLVM-20
binutils; the esp-lld is 21.1.3, which rejects 20.x bitcode the same way it
rejects 21.1.0 zig bitcode — docs/04). But **TinyGo wouldn't expose bitcode for
LTO consumption anyway**, so the version skew is academic.

For *object-level FFI*: the C ABI is the same (datalayout matches, +windowed
matches, GOARCH=arm-tagged but Xtensa-coded). If TinyGo ever ships a
`-buildmode=c-shared` for Xtensa or a `-c relocatable.o` flag, the resulting
objects should link cleanly under `ld.lld` against clang/rust/D/zig/gcc
objects.

## How TinyGo fits today

- **Standalone**: build complete ESP32 firmware in Go — the natural use case.
  `tinygo flash -target=esp32-coreboard-v2 main.go`.
- **As an interop peer**: not yet — the deployment boundary is a whole image,
  not a `.o`. To use Go for one library in a polyglot codebase, you'd either
  (a) compile the Go side to wasm and run it under a wasm runtime, or
  (b) compile a host-side Go shared library and let other languages call into
  it via syscalls / IPC.
- **As an LLVM-20 testbed**: TinyGo's bundled LLVM 20 is the only LLVM-20 in
  the matrix. IR emitted by TinyGo can be inspected with `tinygo build
  -internal-printir` (the test does this for the `xtensa` triple/datalayout
  derivation above).

## Reproducing

```bash
./scripts/setup.sh                                 # now also fetches TinyGo
source scripts/env.sh
bash experiments/tinygo/run.sh                     # all of the above
```

`scripts/env.sh` exports `$TINYGO` and `$TINYGO_DIR`; `setup.sh` extracts the
tarball to `$TC/tinygo`.

## Verdict

TinyGo is a useful 6th toolchain for studying yet-another-LLVM-version (LLVM
20.1.1) on the same espressif Xtensa target, and for end-to-end Go-firmware
work on esp32/s3/c3. It does **not** belong in `experiments/ffi-matrix` as a
co-linkable column because the toolchain's output format is a flash image, not
a relocatable object. Where the other five languages each contribute a `.o`
that participates in one mutual ELF, Go contributes its own complete image.
The interop boundary is the device (or qemu) at runtime, not the linker.
