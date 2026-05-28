# 03 — The FFI matrix

`experiments/ffi-matrix` is the core experiment: one C-ABI contract, five
implementations, one driver that calls all of them. TinyGo is exercised
standalone in `experiments/tinygo/` instead — its `.o` is co-linkable in
principle (docs/24 §d) but pulls a 196 KB Go runtime that this matrix's
`xtensa.ld` doesn't define symbols for.

## The contract (`include/ffi_abi.h`)

Nine functions per language, each prefixed `c_`/`cpp_`/`rs_`/`zig_`/`d_`:

| function | signature | ABI corner exercised |
|----------|-----------|----------------------|
| `add_i32` | `(i32,i32)->i32` | integer regs `a2,a3`→`a2` |
| `add_i64` | `(i64,i64)->i64` | 64-bit register pairs |
| `mul_f32` | `(f32,f32)->f32` | FP in `a`-regs / FPU |
| `mul_f64` | `(f64,f64)->f64` | double in `a2:a3` / soft-float |
| `make_point` | `(i32,i32)->Point` | small (8 B) struct return |
| `point_dot` | `(Point,Point)->i32` | small struct by value |
| `make_blob` | `(u8)->Blob` | large (24 B) struct return (sret) |
| `blob_sum` | `(Blob)->u32` | large struct by value |
| `apply` | `(fn,i32,i32)->i32` | indirect call / callback |

The driver passes a C function pointer into every `*_apply`, exercising calls
**back** into C from each language.

## Tier 1 — host (x86_64), executed

```
$ ./scripts/build-ffi.sh host
== c    ==  ok ×9
== cpp  ==  ok ×9
== rs   ==  ok ×9
== zig  ==  ok ×9
== d    ==  ok ×9
total failures: 0
RESULT: PASS (all 5 languages interop)
```

Built with `zig cc`/`zig c++` (C/C++), esp `rustc` via cargo (Rust, host target),
`zig build-obj` (Zig) and `ldc2 -betterC` (D), linked by `zig cc`. This is a
genuine runtime proof that the C-ABI contract is consistent across all
implementations. (D's by-value struct *args* pass on the x86_64 host — SysV
matches — but diverge on Xtensa/RISC-V; see [docs/19](19-dlang-ldc.md).)

> Caveat: the host SysV ABI masks the Xtensa large-struct bug (§05) because a
> 24-byte struct is memory-passed on x86_64 where clang and zig happen to agree.
> Tier 2 is what exposes target-specific ABI.

## Tier 2 — Xtensa (esp32 / esp32s2 / esp32s3), linked & disassembled

For each core, `build-ffi.sh` produces three fully-resolved ELFs and reports
unresolved symbols (always 0):

| image | C compiler | rest | linker | result |
|-------|-----------|------|--------|--------|
| `ffi_llvm.elf`  | clang | clang++/rustc/zig | `ld.lld` | 0 undefined |
| `ffi_mixed.elf` | **gcc** | clang++/rustc/zig | `ld.lld` | 0 undefined |
| `ffi_gnuld.elf` | clang | clang++/rustc/zig | **GNU `ld`** | 0 undefined |

Conclusions from Tier 2:

1. **Linkers are cross-compatible** — `ld.lld` happily consumes GCC-emitted
   Xtensa objects, and GNU `ld` consumes clang/rust/zig (lld-style) objects.
2. **GCC and LLVM coexist in one image** (`ffi_mixed.elf`) — different IRs,
   different code generators, same ABI, same ELF.
3. **All three cores behave identically** at the FFI level; only intra-function
   codegen changes with the feature set (e.g. esp32s2 soft-float).

The bare-metal images use a deliberately minimal linker script
(`experiments/ffi-matrix/xtensa.ld`, esp32 DRAM) and a stub `_start`
(`entry_xtensa.c`). They are **not** runnable firmware — no bootloader header,
vectors or flash layout — they exist to be statically linked and disassembled.
Soft-float/64-bit helpers come from clang's per-multilib
`libclang_rt.builtins.a`.

## ABI agreement, read from the machine code

`add_i32`, esp32 (`scripts/analyze.sh esp32` → `build/analysis/disasm-esp32.txt`):

```
c_add_i32 / cpp_add_i32 :  entry a1,32 ; mov.n a7,a1 ; add.n a2,a3,a2 ; retw.n
rs_add_i32 / zig_add_i32:  entry a1,32 ;               add.n a2,a3,a2 ; retw.n
gcc c_add_i32           :  entry a1,32 ;               add.n a2,a2,a3 ; retw.n
```

`apply` (callback), byte-identical across C/Rust/Zig:

```
entry a1,32 ; mov.n a11,a4 ; mov.n a10,a3 ; callx8 a2 ; mov.n a2,a10 ; retw.n
```

`a2` holds the incoming function pointer; `callx8` is the windowed indirect call;
args go out in `a10`/`a11`; the result returns in `a10`→`a2`. Identical
convention ⇒ callbacks cross language boundaries safely.

The struct cases are dissected in [05-struct-abi-deep-dive.md](05-struct-abi-deep-dive.md).
