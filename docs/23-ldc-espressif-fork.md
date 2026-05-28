# 23 — LDC on the espressif fork: same frontend, two LLVM backends, what flips

> **Mirror unavailable (since 2026-05-28):** the `kassane/esp-idf-dlang`
> `xtensa-toolchain` asset is no longer fetchable from the previously-pinned
> URL, so a clean `./scripts/setup.sh` falls back to the upstream-LLVM-22 LDC
> (`$LDC2_UPSTREAM`) — which means the workarounds this doc documents as
> "dropped" come back for fresh installs.
> If you have the original 49 MB tarball (sha256 `0e99b893bb64ae0e6f6c888afd196cc9088a629dde1f57779f1b9ee888291211`),
> drop it at `$DL/ldc-esp.tar.xz` and re-run setup to keep the canonical fork
> path. The architectural intent below is the steady-state; the operational
> reality may be the fallback. See HANDOFF.md §"Known outages".

The 5th frontend (D) has, until now, sat on a different LLVM than the other four:
clang/rust/zig ride the **espressif/llvm-project** fork (`esp-21.1.3`, plus zig
0.16's bundled 21.1.0); LDC 1.42-git rode **upstream LLVM 22.1.2**, the only
toolchain in the repo carrying upstream-LLVM Xtensa (still listed
*experimental* there). That worked but cost three workarounds:

1. `ldc2 -c` produced an object whose `l32r` literal pool wasn't 4-aligned, so
   `ld.lld` rejected it (`R_XTENSA_SLOT0_OP … not aligned to 4 bytes`).
2. Only `esp32` was a recognized `-mcpu` value — `esp32s2`/`s3` were
   `'not a recognized processor for this target (ignoring processor)'`
   ([ldc#4919](https://github.com/ldc-developers/ldc/issues/4919)).
3. LDC's LLVM-22 IR used a *slightly* different datalayout (`i8:8:32-i16:16:32`
   instead of the trio's `v1:8:8-i128:128`); `llvm-link` warned but merged.

`kassane/esp-idf-dlang` now publishes a [`xtensa-toolchain`
release](https://github.com/kassane/esp-idf-dlang/releases/tag/xtensa-toolchain)
that pairs the SAME LDC frontend (DMD 2.112.1) with `espressif/llvm-project`
**LLVM 21.1.3** as its backend, byte-matched to esp-clang and rustc. We swapped
that in as the canonical 5th frontend; the upstream-22 LDC stays as
`$LDC2_UPSTREAM`, gated by `LDC_UPSTREAM=1`, used only by
`experiments/ldc-fork-comparison`.

`experiments/ldc-fork-comparison/run.sh` runs the two LDCs side by side and is
the source of truth for everything below.

## What flipped — backend-driven, fixed by the swap

| dimension | upstream-22 LDC | fork (espressif-21) LDC |
|---|---|---|
| LLVM version | 22.1.2 | 21.1.3 (matches esp-clang) |
| `-mcpu=help` (xtensa) | `esp32 esp8266 generic` | `cnl esp32 esp32s2 esp32s3 esp8266 generic` |
| `-mcpu=esp32s2`/`s3` | `'not a recognized processor' (ignoring)` | `Targeting 'xtensa-esp-unknown-elf' (CPU 'esp32sN')` |
| direct `ldc2 -c` -> `ld.lld -T xtensa.ld` | FAIL (`not aligned to 4 bytes` on `__muldf3` literal) | OK (274 084 B `.elf`, 0 undef) |
| datalayout | `e-m:e-p:32:32-i8:8:32-i16:16:32-i64:64-n32` | `e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32` (== clang/rust/zig) |
| `add_i32` codegen (-Os) | 7 lines, no `.n` compact forms (35 % bigger; docs/22 §5) | byte-identical to clang (`mov.n`/`s32i.n`/`l32i.n`/`add.n`) |
| `.text` per `lib_d.o` (esp32) | ~366 B (docs/06) | 533 B¹ |
| llvm-link datalayout warning | yes | gone |

¹ The total grew slightly even though `add_i32` shrank: the espressif-21 backend
selects a different set of compact `.n` forms for the byte-loop in `d_blob_sum`
(24× `l8ui`+`add.n` instead of word-loads). Run `./scripts/analyze.sh esp32`
for the up-to-date per-object size table.

The pre-bundled `etc/ldc2.conf/55-target-xtensa.conf` also defines a
`xtensa-esp32-none-elf` triple alias that auto-applies `-mcpu=esp32`; we still
spell `-mtriple=xtensa-esp-elf -mcpu=...` explicitly so the same invocation
drives both LDCs in the comparison.

## What didn't flip — frontend-driven, still broken

LDC's frontend marks **every by-value aggregate** as `byval(...)` (args) or
`sret(...)` (returns) regardless of size, alignment, or target — visible in the
IR for both LDCs:

```
fork     d_point_dot: (ptr byval(%lib_d.Point) %a, ptr byval(%lib_d.Point) %b)
         d_blob_sum has byval(%lib_d.Blob); d_make_point has sret(%lib_d.Point)
upstream d_point_dot: (ptr byval(%lib_d.Point) %a, ptr byval(%lib_d.Point) %b)
         d_blob_sum has byval(%lib_d.Blob); d_make_point has sret(%lib_d.Point)
```

clang/rust by contrast coerce small aggregates to `[N x i32]` *in the frontend*
(matching the Xtensa SysV-style C ABI). Same espressif backend, different IR
shape going in → different machine ABI coming out.

Runtime (`scripts/run-qemu.sh xtensa`) confirms the bug is not LLVM-version
sensitive:

```
- point_dot: 8B struct by value ==11    d FAIL (got=4548 want=11)
- blob_sum:  24B struct by value ==300  d FAIL (got=695 want=300)
- blob_sum BY POINTER ==300              d ok  (300)   ← scalar arg is fine
```

This is the same family of bug as
[kassane/dlang-mos-hello-world#1](https://github.com/kassane/dlang-mos-hello-world/issues/1)
on MOS 6502 — D's frontend ignores narrow-target constraints (there it picks
`i32` instead of `i16` for `size_t`; here it picks `byval` instead of `[N x i32]`).
That issue is labelled **wontfix**; this one tracks in
[ldc#4725](https://github.com/ldc-developers/ldc/issues/4725) plus the upstream
DMD-ABI-config gap.

`experiments/abi-structs/sweep.sh` shows the same finding from the *caller*
side: D never emits `movsp` (the windowed register-stack adjust), so by the
movsp heuristic it classifies as REGISTERS for every shape — but
`d_point_dot`'s first instruction in `experiments/dlang/run.sh §(c)` is still
`l32i.n a8, a1, 32` (a1 = SP), reading the argument *off the stack* via the
byval slot rather than out of `a4/a5`. The whole story:

- frontend IR shape (`byval`) — D-specific, both LDCs identical
- caller-side disasm (no `movsp`) — D matches clang
- callee-side disasm (`l32i a*, a1, *`) — D reads the byval slot
- runtime result — FAIL on Xtensa, scalar by-pointer path works

## Toolchain inventory after the swap

```
$LDC2          = /home/user/toolchains/ldc-xtensa/bin/ldc2                  (canonical)
$LDC2_UPSTREAM = /home/user/toolchains/ldc2-c8305d0a-linux-x86_64/bin/ldc2  (comparison only)
$LDC_LLVM_DIR  = /home/user/toolchains/llvm-22.1.2-linux-x86_64             (LLVM-22 binutils;
                                                                              only needed for
                                                                              the comparison)
```

`./scripts/setup.sh` fetches the fork by default. `LDC_UPSTREAM=1
./scripts/setup.sh` adds the upstream LDC (~57 MB), required to run
`experiments/ldc-fork-comparison`. The LLVM-22 binutils (`LLVM22=1`) are no
longer needed for canonical IR work — esp-clang's own 21.1.3 binutils version-
match the fork LDC and read its bitcode natively. They're kept for
`experiments/llvm-ir-mix` to confirm the merge works at the LLVM-22 level too
and for any future upstream-LDC analysis.

`scripts/env.sh:ldc_xtensa_flags()` now pairs `-mcpu=<cpu>` with an explicit
`-mattr=<feature-list>` that mirrors what `esp-clang` implicitly enables for the
same `-mcpu`. The feature set is the intersection of features both LDCs
recognize, so `experiments/ldc-fork-comparison` can drive the upstream LDC's
arm with the same string. `-mcpu` alone would also work on the fork (it ships
fork-only features like `+esp32s2ops`/`+esp32s3ops`/`+expstate` via the CPU
definition), but pinning them in `-mattr` makes the dependency explicit and
survives any future per-CPU default change.

## Build path simplifications

`scripts/build-ffi.sh:ldc_xtensa_obj()` collapses from:

```bash
# (old: upstream-22 LDC)
ldc2 -mtriple=xtensa-esp-elf <flags> -betterC -Os -output-s -of=lib_d.s lib_d.d
sed -E -i '/^[[:space:]]*\.cfi_/d' lib_d.s            # CFI not supported by esp-clang's Xtensa MC
clang --target=xtensa-esp-elf -mcpu=$CPU -c lib_d.s -o lib_d.o
```

to:

```bash
# (new: fork-21 LDC)
ldc2 -mtriple=xtensa-esp-elf <flags> -betterC -Os -c -of=lib_d.o lib_d.d
```

DWARF survives end-to-end now (the workaround dropped it on re-assembly). The
fork's producer DIE reads `LDC 1.42.0-git-04a6c8b (LLVM 21.1.3)` in
`dwarfdump`; the upstream LDC's re-assembled object has no producer string at
all.

## Reproducing

```bash
# Default install (canonical fork-LDC, no upstream):
./scripts/setup.sh

# To also run experiments/ldc-fork-comparison:
LDC_UPSTREAM=1 ./scripts/setup.sh
LLVM22=1      ./scripts/setup.sh         # only if you want LLVM-22 binutils

source scripts/env.sh
./scripts/build-ffi.sh all                                                   # host PASS + xtensa-{esp32,s2,s3} + riscv-esp32c3, 0 undef everywhere
./scripts/run-qemu.sh xtensa                                                 # 3 fails (zig blob_sum + d point_dot/blob_sum)
./scripts/run-qemu.sh riscv                                                  # 1 fail (zig point_dot)
bash experiments/ldc-fork-comparison/run.sh                                  # side-by-side both LDCs (needs $LDC2_UPSTREAM)
```

## Verdict

Five workarounds dropped (literal-pool re-assembly, `.cfi_*` strip, `-output-s`
intermediate, `-mattr` fallback for s2/s3, LLVM-22 binutils dependency for
canonical IR work). Codegen quality reaches clang-parity. The one finding that
*didn't* flip — D's universal `byval`/`sret` aggregate lowering — is now
isolated as a frontend bug, repeatably observable on either LLVM, and aligned
with the same-family `wontfix` mos6502 issue. That makes it a real bug-report
candidate against LDC's DMD ABI rather than something downstream toolchain
maintainers can fix.

Closes the LDC slot in the docs/00 matrix and rewrites the LLVM-version-bound
claims in docs/04/06/19/22.
