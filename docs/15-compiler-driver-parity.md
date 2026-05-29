# 15 — Compiler-driver parity: `zig cc`/`esp-clang`/`esp-gcc` (and the `++`s)

How interchangeable are the three C / C++ drivers for Xtensa esp32?
Reproduce with `experiments/compiler-parity/run.sh`. (For the LDC and TinyGo
*driver* peers — same backend family, different invocation surface — see
docs/19/23 and docs/24 §b; this doc keeps its narrow C/C++ scope.)

| | `zig cc` / `zig c++` | `esp-clang` / `esp-clang++` | `esp-gcc` / `esp-g++` |
|---|---|---|---|
| engine | clang/LLVM **22.1.4** (bundled in Zig 0.17 canonical; the legacy `$ZIG_016` bundle is LLVM **21.1.0**) | clang/LLVM **21.1.3** (espressif fork) | GCC **15.2** |
| C target flag | `-target xtensa-freestanding-none -mcpu=esp32` | `--target=xtensa-esp-elf -mcpu=esp32` | `XTENSA_GNU_CONFIG=…esp32.so` |
| C ABI (windowed) | ✓ | ✓ | ✓ |
| C++ ABI (Itanium) | ✓ | ✓ | ✓ |

For the related LLVM-driver peers in the 6-toolchain matrix not covered here:

| | LDC (espressif-fork) | TinyGo |
|---|---|---|
| engine | LDC 1.42-git / LLVM **21.1.3** (espressif fork; docs/23) | tinygo 0.41.1 / LLVM **20.1.1** (tinygo-org fork; docs/24) |
| C-ABI bridge | `extern(C)` / `extern(C++)` | `//export` (cgo on host; firmware-only on Xtensa) |
| `-mattr` for `-mcpu=esp32` | mirrors esp-clang's set (via env.sh `ldc_xtensa_flags`) | `+atomctl,+memctl,+timerint` instead of esp-clang's `+dcache,+expstate,+highpriinterrupts-level7,+mul16,+timers3` — C-ABI essentials (+windowed,+density,+mul32,+s32c1i) in both |
| relocatable `.o` for the cross-toolchain link? | ✓ direct `-c` since docs/23 | ✗ flash-image only; docs/24 |

## C parity (`zig cc` × `esp-clang` × `esp-gcc`)

- **ABI: identical.** All three use the Xtensa windowed C ABI — `c_point_dot`
  takes the two `Point`s in `a2/a3` and `a4/a5`, returns in `a2`. Verified across
  the whole FFI matrix (docs/03).
- **Codegen: `zig cc` ≈ `esp-clang`** (same clang/LLVM 21 + espressif backend).
  Per-function code is near-identical; the only systematic difference is that
  **esp-clang keeps a frame pointer** (`mov.n a7,a1`) by default while **zig cc
  omits it**, so zig cc is marginally *smaller*. GCC agrees on the ABI but uses
  its own register allocation / frame size (`entry a1,48` vs `a1,32`).
- **Real code size** (`llvm-size -A` `.text`, 9-fn lib, `-Os`):
  `esp-gcc 174 · zig cc 178 · esp-clang 192` — all within ~10%.

## C++ parity (`zig c++` × `esp-clang++` × `esp-g++`)

- **Itanium C++ ABI: byte-identical.** Mangled names and vtable symbols match
  exactly across all three: `_ZN4demo3addEii`, `_ZN4Base1fEi`, `_ZTV7Derived`.
  So C++ symbols, overloads and vtable layout are interchangeable.
- **Codegen**: same as C — `zig c++` ≈ `esp-clang++` (frame-pointer default
  aside); g++ same ABI, different regalloc.
- **Real code size** (`.text`, `-Os -fno-exceptions -fno-rtti`):
  `esp-g++ 174 · zig c++ 190 · esp-clang++ 204`.

## The one real difference: driver **defaults**, not the ABI

`zig cc`/`zig c++` are tuned for hosted Zig builds, so by default they:

- **emit `.eh_frame` unwind tables** (~200 B for the 9-fn lib) — even for
  freestanding C and `-fno-exceptions` C++. esp-clang/gcc emit none. For
  bare-metal, strip with `-fno-unwind-tables -fno-asynchronous-unwind-tables`.
- enable **ubsan-rt** and (for C++) **libc++**; on bare metal pass
  `-nostdlib`/`-ffreestanding` (+ `-fno-sanitize=undefined`), and add `-lc++`
  only if you actually use libc++ (docs/12). esp-clang/gcc don't pull these.

> This is also why the FFI-matrix size table is measured with `llvm-size -A`
> (real `.text`), not the Berkeley `llvm-size` "text" column — the latter folds in
> zig's default `.eh_frame` and overstated the zig-*language* lib as 647 B when
> its actual code is **715 B** today (still the largest, from the struct-marshalling
> of docs/05 — but a fair comparison vs clang's 223 B, not an unwind-inflated 647).

## Verdict

- **`zig cc` ⇄ `esp-clang` are effectively the same C/C++ compiler** (the same
  espressif clang/LLVM 21 backend); differences are driver *defaults*
  (eh_frame/ubsan/libc++), trivially flag-controlled. Either produces
  ABI-compatible, near-identical Xtensa code.
- **clang-family ⇄ gcc**: full ABI parity (windowed C ABI; identical Itanium C++
  mangling & vtables), different code generation; gcc is slightly smaller. Objects
  from all three interlink (docs/03).
