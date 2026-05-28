# 06 — Binary & symbol comparison

## Code size — same 9 functions, esp32, size-optimized

**real `.text`** bytes (`llvm-size -A`, `-Os` / `-O ReleaseSmall`) — *not* the
Berkeley `llvm-size` "text" column, which folds in zig's default `.eh_frame`:

| toolchain | `.text` (bytes) | notes |
|-----------|:--------------:|-------|
| gcc 15.2 (C) | **174** | smallest; mature Xtensa codegen, uses zero-overhead `loop` |
| rust 1.95 | ~171 | matches gcc/clang closely (per-function sections) |
| clang 21 (C) | 192 | (`+ mov.n a7,a1` frame setup at `-Os`; Berkeley "text" 196) |
| clang 21 (C++) | 204 | templates fully inlined; C-ABI exports only |
| D 1.42 (LDC, `-betterC`) | ~366 | between clang and zig; verbose byte loops in `make_blob`/`blob_sum` (docs/19) |
| zig 0.16 (Zig) | **443** | ~2.3× — non-C-ABI large-struct marshalling (doc 05) |

The Zig outlier is entirely `blob_sum`/`make_blob`: the byte-by-byte stack
shuffling for the large by-value struct. On scalar/callback/small-struct
functions Zig matches the others closely. (The often-quoted "647 B" is the
Berkeley `llvm-size` total, which adds ~200 B of `.eh_frame` unwind tables that
zig's *driver* emits by default — see docs/15; the actual code is 443 B.) D sits
in between — its `make_blob`/`blob_sum` byte loops (131/123 B) inflate it much
like zig's, the rest is tight.

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
