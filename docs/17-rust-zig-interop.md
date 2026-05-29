# 17 — Rust ⇄ Zig frontend interop (deep dive)

Rust and Zig are the two **non-C** LLVM frontends on the shared espressif backend.
Where do *they specifically* agree or clash on Xtensa — beyond what the C ABI
covers? Reproduce with `experiments/rust-zig/run.sh`.

## 1. Scalar ABI: full parity — including types C can't express

For every scalar the two frontends agree at the machine level, so Rust↔Zig FFI
works for them. Notably this **exceeds Rust↔C on Xtensa**: clang and gcc reject
`__int128` and have no `_Float128`/`_Float16` there, but Rust (`u128`/`f128`/`f16`,
nightly) and Zig (`u128`/`f128`/`f16`, native) both have them.

| type | Rust IR | Zig IR | machine ABI |
|------|---------|--------|-------------|
| `u128`/`i128` | `(i128, ptr byval([16 x i8]))` | `(i128, i128)` | **same** — arg1 in `a2–a5`, arg2 on the stack |
| `f128` | `(fp128, ptr byval([16 x i8]))` | `(fp128, fp128)` | **same** (16-byte, like u128) |
| `f16` | `(half, half)` | `(half, half)` | same (`half` in an a-reg) |
| `bool` | `i1 zeroext` | `i1` | same (`xor a2,1`; both rely on the 0/1 invariant) |
| C enum | `i32` | `i32` (`enum(c_int)`) | same |

The `u128`/`f128` IR *looks* different — Rust's frontend applies the Xtensa C ABI
(a 16-byte value that won't fit in the remaining arg registers becomes an indirect
`byval` pointer), while Zig hands LLVM a direct `i128`/`fp128`. But the **backend
reconciles them**: in both, arg1 lands in `a2–a5` and arg2 spills to the incoming
stack area. Verified at the call site *and* callee, and at runtime:

```
$ run.sh   # Rust builds two u128, calls zig_add_u128, checks carry across 4 words
  rs_check_u128 = 1  OK (carry across 4 words, cross-language)   # on qemu-system-xtensa
```

(Contrast the earlier `mul_f64` case, docs/04: IR differs, machine ABI matches —
same lesson. The byval-vs-direct difference is *not* an ABI difference here.)

### Optional/nullable pointers — direct interop

Both languages represent "maybe a pointer" as a single **nullable pointer** (the
C `T*`-with-null convention), so they interoperate without any wrapper:

| Rust (FFI-safe) | Zig | IR |
|-----------------|-----|----|
| `Option<&T>` / `Option<NonNull<T>>` | `?*T` | `ptr` (null ⇒ None/null) |
| `Option<extern "C" fn()>` | `?*const fn() callconv(.c)` | `ptr` |

Rust's null-pointer optimization makes `Option<NonNull<u8>>` a single `i32 ptr`
(rustc even confirms it's **FFI-safe** — no `improper_ctypes`), identical to Zig's
`?*const u8`. Runtime-verified (`experiments/rust-zig/opt`): Rust passes
`Some(&X)`→address and `None`→0 to a Zig `?*const u8` and both arrive correctly.
So a nullable pointer crosses Rust↔Zig (and ↔C) transparently — no `*mut T` +
manual null dance needed.

## 2. The one real clash: by-value **struct arguments**

This is the single Rust↔Zig FFI break, and it's Zig's: Zig's experimental ESP
targets mis-lower by-value struct *arguments* where Rust (matching clang/gcc)
implements the platform C ABI:

- **Xtensa**: under-aligned (`align(1)`) structs — Rust passes `[N x i32]` in
  `a2..a7`, Zig stack-spills (docs/05). Runtime: `zig blob_sum FAIL` (docs/08).
- **RISC-V**: a small `{i32,i32}` — Rust passes `[2 x i32]` in regs, Zig lowers to
  `[2 x i64]` and reads the wrong registers (docs/09). Runtime: `zig point_dot FAIL`.

So a Rust↔Zig call passing such a struct **by value** corrupts data. Struct
*returns* (sret) are fine. **Mitigation:** pass structs **by pointer** across any
Rust↔Zig boundary — then everything (incl. u128/f128) interoperates.

**Provenance — it's upstream Zig, not the espressif fork.** The
`kassane/zig-espressif-bootstrap` README enumerates its 7 patches and **every one
targets LLVM/LLD/Clang/zlib build plumbing — none touch Zig's `src/`**. The fork
builds an upstream Zig 0.16.0-era commit (which already carries the `esp32`/s2/s3
CPU *models* — present in its `lib/std/Target/xtensa.zig`, absent from the tagged
0.16.0) against espressif LLVM 21.1.0. So the by-value aggregate mis-lowering is
in **upstream Zig's frontend C-ABI handling** (it defers to LLVM's default instead
of coercing per the platform C ABI), not a fork regression — consistent with the
RISC-V case reproducing on stock upstream Zig (docs/10). It's tracked upstream by
**ziglang/zig #5467 "Xtensa Support" CLOSED 2026-05-06 (milestone 0.17.0)** —
the umbrella issue is now done; Xtensa support landed in 0.17.0 (along with
#23088 for `xtensa(eb)-linux` tier). **The by-value aggregate mis-lowering DID
get fixed in that landing — verified at the shell against
`kassane/zig-espressif-bootstrap` `zig-0.17.0-relsafe-x86_64-linux-musl-baseline`
(bundled clang/LLVM 22.1.4, exposed as `$ZIG_017`).** The 0.17 zig frontend
now emits `i32 @lib_zig.zig_blob_sum([6 x i32] %0)` instead of
`i32 @lib_zig.zig_blob_sum(%lib_zig.Blob %0)` — same `[N x i32]` shape clang
has emitted all along. qemu xtensa `zig_blob_sum` flips from `FAIL (got=409)`
to `ok (300)`, qemu riscv `zig_point_dot` flips from `FAIL` to `ok (11)`,
and the abi-structs sweep shows REGISTERS in every Zig row on every Xtensa
core. The repo default `$ZIG` stays on 0.16 for snapshot continuity; switch
with `ZIG=$ZIG_017 ...`. Full account in docs/05 §"Zig 0.17 status".
(Cf. the *data-layout* gap upstream #16616 / PR #16632, already fixed.)

## 3. Linking & LTO

- **Object-level FFI: works.** A Rust `staticlib` links with a Zig object under
  `ld.lld` (and GNU `ld`); the u128 runtime above is a Rust↔Zig link. Symbols,
  the windowed ABI, and runtime builtins all resolve.
- **Cross-language LTO / IR-merge: fails** — `ld.lld: error: …rt.bc: Invalid
  record`. Rust's bitcode is LLVM **21.1.3**, Zig's is **21.1.0**; the LTO reader
  rejects the mismatched module. (Same skew that blocks clang↔zig LTO, docs/04;
  clang↔rust LTO works because both are 21.1.3.) To LTO across Rust↔Zig you'd need
  both on one LLVM point release.

## 4. Atomics — native and compatible

Shared atomic state across a Rust↔Zig boundary needs compatible atomic sequences.
Both frontends emit **native `s32c1i`** (esp32's compare-and-swap) with `memw`
fences — **no `__atomic`/`__sync` libcalls** in either:

```
rust rs_atomic_add: memw … wsr a11,scompare1 ; s32c1i a8,a2,0 ; beq (retry) … memw
zig  zig_atomic_add: memw … wsr a11,scompare1 ; s32c1i a8,a2,0 ; beq (retry) … memw
rs_atomic_cas == memw ; wsr scompare1 ; s32c1i ; memw   (same in both)
```

So a Rust `AtomicU32` and a Zig `@atomicRmw`/`@cmpxchg` on the same location
interoperate. (esp-rs #258's atomics symptom was a higher-level async/runtime
deadlock, not an atomic-lowering mismatch — the lowering itself is consistent.)

## 5. `packed` is a naming trap — different concepts

Rust `#[repr(packed)]` and Zig `packed struct` are **not** the same thing:

| | meaning | `{u8,u8}` | sub-byte fields |
|---|---------|-----------|-----------------|
| Rust `#[repr(packed)]` | byte-packed, padding removed, align 1 | 2 bytes | ✗ (no `u4`) |
| Zig `packed struct` | **bit-packed into a backing integer** | 2 (backing `u16`) | ✓ (`{u4,u4}` = 1 byte) |

So mapping a Zig `packed struct` onto a Rust `#[repr(packed)]` (or a C struct) is
wrong. Two saving graces:

- **Zig guards the boundary**: passing a `packed struct` *by value* through a
  C-ABI (`export`/`callconv(.c)`) function is a **hard compile error** —
  *"not allowed in function with calling convention 'xtensa_call0'"* (its backing
  integer's signedness is unspecified). So you can't accidentally FFI one — pass
  it **by pointer**. (Contrast: `extern struct` by value *is* allowed, and that's
  where the silent §2 mis-lowering lives.)
- **Use the C-layout types for FFI**: Zig `extern struct` ⇄ Rust `#[repr(C)]`
  (natural alignment + padding). Zig `packed struct` ≈ C bitfields (Rust has no
  native equivalent); Rust `#[repr(packed)]` ≈ a `__attribute__((packed))` C
  struct (Zig models that with `extern struct` + explicit alignment, not
  `packed`).

(For the 2-byte `extern struct {u8,u8}` itself, the §2 pattern recurs: Rust
coerces it to `i32`, Zig passes the raw aggregate — same byval-vs-direct story.)

## Verdict

Rust ⇄ Zig FFI on Xtensa is **as strong as Rust ⇄ C, and in one way stronger**:
the two frontends agree on every scalar ABI, *including* `u128`/`f128`/`f16` that
C can't even express on Xtensa, and **nullable pointers** (`Option<&T>` ↔ `?*T`)
interop directly (object-linked and runtime-verified). The only
caveats are (1) **by-value struct arguments** — Zig's experimental ESP ABI bug,
so pass structs by pointer — and (2) **no cross-language LTO** until Zig's LLVM
(21.1.0) matches Rust's (21.1.3); object-level FFI has no such constraint.
