# 06 — Binary & symbol comparison

## Code size — same 9 functions, esp32, size-optimized

**real `.text`** bytes (`llvm-size -A`, `-Os` / `-O ReleaseSmall`) — *not* the
Berkeley `llvm-size` "text" column, which folds in zig's default `.eh_frame`:

| toolchain | `.text` (bytes) | notes |
|-----------|:--------------:|-------|
| gcc 15.2 (C) | **201** | smallest; mature Xtensa codegen, uses zero-overhead `loop` |
| rust 1.95 | 171 | matches gcc/clang closely (per-function sections) |
| clang 21 (C) | 219 | (`+ mov.n a7,a1` frame setup at `-Os`) |
| clang 21 (C++) | 204 | templates fully inlined; C-ABI exports only |
| **zig 0.17** (LLVM 22.1.4, `$ZIG` canonical) | **375** | ~1.8× clang — frontend now flattens aggregates to `[N x i32]` (docs/05 §"Zig 0.17 status"), so `blob_sum`/`make_blob` no longer shuffle bytes through the stack; the residual gap is from the `.eh_frame` Zig still emits by default (220 B, see docs/15) plus a more verbose per-function prologue |
| zig 0.16 (`$ZIG_016` legacy) | 715 | ~3× — old non-C-ABI large-struct marshalling (doc 05); kept here for the comparison |
| D 1.42.0 (LDC esp-fork, `-betterC`) | 516 | per-function sections sum; canonical LDC 1.42.0 (LLVM 22.1.4, 2026-05-30 maintainer re-upload) **closes** the universal byval/sret aggregate bug — `d_point_dot` is now byte-identical to `c_point_dot`. `.text` went UP slightly (489 → 516 B) because `d_blob_sum`'s in-register byte unpacking (`srli`/`extui`/`and`) takes a few more instructions than the old indirect byte loads did, but qemu xtensa now reports 0 D failures (docs/05 §"LDC 1.42 status", docs/19, /23). |
| TinyGo v0.41.1 | *whole firmware ~140 KB ELF (docs/24)* | not directly comparable: TinyGo emits a flash image (header `e9 02 02 1f`), not a per-function `.o`; the included Go runtime + std lib dominate. At -opt=0 the single-function disasm matches Rust release in 7 bytes (docs/22 §g). |

Re-derive with `./scripts/analyze.sh esp32` (writes
`build/analysis/sizes-esp32.txt`). The 0.16 → 0.17 Zig flip cuts `.text` from
715 to 375 bytes on the same source — the savings are concentrated in
`blob_sum` / `make_blob`, where 0.16 had per-byte stack marshalling and 0.17
loads/stores six full words. **D now leads the residual outlier list** — its
`make_blob`/`blob_sum` byte loops inflate it (489 B sum), the rest is tight.
The D figure is for the canonical espressif-fork LDC; the upstream-LLVM-22
LDC produces a *smaller* `.text` (~366 B) but with non-compact codegen
(docs/22) — the fork uses the same `.n` compact forms as clang, so its
individual functions are tighter even though the total grew slightly from a
different byte-loop shape.

## Endianness & machine

Every object from every toolchain is `ELF 32-bit **LSB** (little-endian),
EM_XTENSA (0x5E)` — *once* GCC is given `XTENSA_GNU_CONFIG` (its default core is
big-endian; see doc 01).

## Symbol naming / mangling

The FFI surface is pure C ABI, so all *exported* symbols are flat C names
(`c_*`, `cpp_*`, `rs_*`, `zig_*`, `d_*`) regardless of source language:

| language | export mechanism | exported symbol | internal mangling |
|----------|------------------|-----------------|-------------------|
| C | (default) | `c_add_i32` | n/a |
| C++ | `extern "C"` | `cpp_add_i32` | Itanium `_Z…` for non-`extern "C"` symbols |
| Rust | `#[no_mangle] pub extern "C"` | `rs_add_i32` | v0 `_R…` (e.g. `_RNvNtCs…17compiler_builtins3mem6memcpy`) |
| Zig | `export fn` | `zig_add_i32` | module-qualified `lib_zig.*`; exports are aliases to them |
| D | `extern(C)` | `d_add_i32` | D `_D…`; `extern(C++)` → Itanium `_Z…`/`_ZN…` (docs/19) |
| TinyGo | `//export go_add_i32` | `go_add_i32` | package-qualified `main.go_add_i32`; `//export` adds a bare-C alias |

Zig emits the exported name as an **alias** to a private, module-qualified
definition:

```llvm
@zig_blob_sum = alias i32 (%Blob), ptr @lib_zig.zig_blob_sum
```

## Linker interoperability (recap from doc 03)

| objects | `ld.lld` | GNU `ld` |
|---------|:-------:|:--------:|
| all LLVM (clang/rust/zig/D) | ✓ 0 undef | ✓ 0 undef |
| GCC C + LLVM rest | ✓ 0 undef | ✓ (gcc-native) |
| + TinyGo `.o` | ✓ links per-symbol, but the consumer must provide `_heap_start`/`_heap_end`/`tinygo_swapTask`/`tinygo_startTask`/`tinygo_scanCurrentStack` (docs/24 §d) | same |

Both linkers resolve both object families; relocations and section layout from
LLVM and GNU producers are mutually consumable. (GNU `ld` warns about the
RWX `LOAD` segment — an artifact of our deliberately minimal demo linker script,
not an interop issue.)

## Runtime builtins

Soft-float and 64-bit helpers (`__muldf3`, `__mulsf3`, …) resolve from either:

- clang per-multilib compiler-rt:
  `esp-clang/lib/clang-runtimes/xtensa-esp-unknown-elf/<cpu>/lib/libclang_rt.builtins.a`
- gcc libgcc: `xtensa-esp-elf/lib/gcc/xtensa-esp-elf/15.2.0/libgcc.a`

Rust's `compiler_builtins` (pulled in by `-Z build-std`) provides its own copies;
the linker de-duplicates at resolve time. We link the LLVM images against
compiler-rt and observe 0 unresolved symbols.
