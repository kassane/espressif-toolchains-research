# 06 — Binary & symbol comparison

## Code size — same 9 functions, esp32, size-optimized

**real `.text`** bytes (`llvm-size -A`, `-Os` / `-O ReleaseSmall`) — *not* the
Berkeley `llvm-size` "text" column, which folds in zig's default `.eh_frame`:

| toolchain | `.text` (bytes) | notes |
|-----------|:--------------:|-------|
| gcc 15.2 (C) | **201** | smallest; mature Xtensa codegen, uses zero-overhead `loop` |
| rust 1.95 | ~179 | matches gcc/clang closely (per-function sections) |
| clang 21 (C) | 223 | (`+ mov.n a7,a1` frame setup at `-Os`) |
| clang 21 (C++) | 212 | templates fully inlined; C-ABI exports only |
| D 1.42 (LDC esp-fork, `-betterC`) | 533 | between clang and zig; verbose byte loops in `make_blob`/`blob_sum` (docs/19, /23) |
| zig 0.16 (Zig) | **715** | ~3× — non-C-ABI large-struct marshalling (doc 05) |
| TinyGo v0.41.1 | *whole firmware ~140 KB ELF (docs/24)* | not directly comparable: TinyGo emits a flash image (header `e9 02 02 1f`), not a per-function `.o`; the included Go runtime + std lib dominate. At -opt=0 the single-function disasm matches Rust release in 7 bytes (docs/22 §g). |

Re-derive with `./scripts/analyze.sh esp32` (writes
`build/analysis/sizes-esp32.txt`). The Zig outlier is entirely
`blob_sum`/`make_blob`: the byte-by-byte stack shuffling for the large by-value
struct. On scalar/callback/small-struct functions Zig matches the others
closely. D sits in between — its `make_blob`/`blob_sum` byte loops inflate it
much like zig's, the rest is tight. The D figure is for the canonical
espressif-fork LDC; the upstream-LLVM-22 LDC produces a *smaller* `.text`
(~366 B) but with non-compact codegen (docs/22) — the fork now uses the same
`.n` compact forms as clang, so its individual functions are tighter even
though the total grew slightly from a different byte-loop shape.

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

Zig emits the exported name as an **alias** to a private, module-qualified
definition:

```llvm
@zig_blob_sum = alias i32 (%Blob), ptr @lib_zig.zig_blob_sum
```

## Linker interoperability (recap from doc 03)

| objects | `ld.lld` | GNU `ld` |
|---------|:-------:|:--------:|
| all LLVM (clang/rust/zig) | ✓ 0 undef | ✓ 0 undef |
| GCC C + LLVM rest | ✓ 0 undef | ✓ (gcc-native) |

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
