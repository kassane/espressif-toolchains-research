# 00 — Espressif support matrix: Rust × Zig × D × esp-clang × GCC × TinyGo

At-a-glance comparison for **Espressif Xtensa (ESP32 / S2 / S3)** and the
RISC-V outlier **ESP32-C3**, distilled from the experiments in this repo.
Legend: ✓ works / correct · ✗ broken · — n/a.

> **LDC mirror RESTORED (2026-05-30) with a different tarball — see docs/23
> banner**: the maintainer republished the canonical D toolchain on LLVM
> 22.1.4 (was 21.1.3). The universal D byval/sret aggregate ABI bug
> documented below is **closed** on the new canonical; the LDC mirror outage
> note below is the *previous* state and is retained for the record.
>
> **(Previous note, 2026-05-28 → 2026-05-30):** the canonical D toolchain's
> upstream (`kassane/esp-idf-dlang`) isn't fetchable. `scripts/setup.sh`
> auto-falls back to the upstream LDC (LLVM 22.1.2) — re-enabling docs/23's
> workarounds for fresh installs. See HANDOFF.md §"Known outages". The matrix
> below describes the canonical-fork state; runtime reality may match the
> fallback.

## Identity & availability

| | **Rust** (esp-rs) | **Zig** (esp bootstrap) | **D** (LDC) | **esp-clang** | **GCC** (crosstool-NG) | **TinyGo** (docs/24) |
|---|---|---|---|---|---|---|
| version | 1.95.0-nightly | **0.17.0-xtensa** | **LDC 1.42.0** | 21.1.3 | 15.2.0 | v0.41.1 |
| backend | LLVM **21.1.3** | LLVM **22.1.4** (bundled) | LLVM **22.1.4** (espressif fork; was 21.1.3 before the 2026-05-30 maintainer re-upload) | LLVM **21.1.3** | GCC (own) | LLVM **20.1.1** (TinyGo-bundled) |
| Xtensa via | **`esp-rs/rust` fork** | **`kassane/zig-espressif-bootstrap` fork** (0.16 legacy is `$ZIG_016`) | **`kassane/esp-idf-dlang` fork** (LDC + `espressif/llvm-project`; docs/23) | **`espressif/llvm-project` fork** | `espressif/crosstool-NG` | **`tinygo-org/llvm-project` fork** (bundled in the tarball; see docs/24) |
| works on **upstream**? | ✗ — esp-rs is a *fork*; upstream rustc has only Tier-3 *target specs*, no working Xtensa codegen | partial — upstream Zig 0.17.0 adds `esp32` only (no s2/s3); **fork** has all three. The struct-by-value bug (#5467) is fixed in 0.17 | partial — `$LDC2_UPSTREAM` (LLVM 22.1.2) works for `esp32` only (no s2/s3; ldc #4919) and needs the `-output-s` re-assembly workaround; docs/23 | ✗ — **espressif/llvm ≠ upstream LLVM**; upstream's Xtensa backend is experimental/partial (esp32/esp8266 only) | ~ — Xtensa is in upstream GCC, but the esp32/s2/s3 cores come from espressif | n/a — TinyGo bundles its own LLVM and runtime |
| esp32 / s2 / s3 | ✓ / ✓ / ✓ | ✓ / ✓ / ✓ | ✓ / ✓ / ✓ (via `-mcpu`) | ✓ / ✓ / ✓ | ✓ / ✓ / ✓ | ✓ / **✗** / ✓ (no esp32-s2 target) |
| `core`/libc model | no prebuilt core → `-Zbuild-std=core` + rust-src | freestanding (no std) | `-betterC` (no druntime/Phobos) | freestanding | newlib + libgcc | Go runtime + picolibc (bundled) |
| co-linkable `.o` for FFI matrix? | ✓ | ✓ | ✓ | ✓ | ✓ | **✗** — whole-program (firmware-only output; docs/24 §d) |

> **Every LLVM frontend here rides a custom LLVM fork** for Xtensa support
> — four against `espressif/llvm-project` and TinyGo against its own
> `tinygo-org/llvm-project` (LLVM 20.1.1, bundled inside the TinyGo tarball;
> docs/24). Stock upstream LLVM's Xtensa is still experimental (esp32/8266 only). `esp-rs/rust` is a fork of rustc (built against
> espressif's LLVM) — *upstream* `rustc` cannot build for Xtensa even though it
> carries Tier-3 target specs. Likewise **`espressif/llvm-project` ≠ upstream
> LLVM**: the espressif fork has the complete esp32/s2/s3 backend; upstream
> LLVM's Xtensa target is still experimental (only esp32/esp8266). Zig needs
> the espressif bootstrap fork too: upstream Zig 0.17.0 (the canonical version
> here, exposed as `$ZIG`) adds `esp32` via upstream LLVM, but still lacks
> esp32-s2/s3 — **only the fork has all three, exactly like the Rust fork.**
> (The legacy `$ZIG_016` lane reproduces the pre-0.17 struct-by-value gap
> against the same fork.) Only GCC's Xtensa core is upstream — and even then the ESP
> core configs ship via `espressif/crosstool-NG`. **D/LDC used to be the
> exception** (riding upstream LLVM-22 directly, with a literal-pool re-assembly
> workaround) — but the canonical 5th frontend is now
> [`kassane/esp-idf-dlang`'s LDC](https://github.com/kassane/esp-idf-dlang/releases/tag/xtensa-toolchain)
> on the espressif fork (LLVM 21.1.3, same family as clang/rust/zig). The old
> upstream-22 LDC stays as `$LDC2_UPSTREAM` for the comparison in docs/23.

## How to target an esp32 core

| | command |
|---|---|
| Rust | `cargo build -Z build-std=core --target xtensa-esp32-none-elf` |
| Zig | `zig build-obj -target xtensa-freestanding-none -mcpu=esp32` |
| D (LDC) | `ldc2 -mtriple=xtensa-esp-elf -mcpu=esp32 -betterC -c` *(direct -c on the espressif-fork LDC; the upstream-22 LDC needs `-output-s` re-assembly — docs/23)* |
| esp-clang | `clang --target=xtensa-esp-elf -mcpu=esp32` |
| GCC | `XTENSA_GNU_CONFIG=…/xtensa_esp32.so xtensa-esp-elf-gcc` *(mandatory: default core is big-endian)* |
| TinyGo | `tinygo build -target=esp32-coreboard-v2 -o app.bin app.go` *(default = ESP32 flash image; `-o app.o` does produce a relocatable Xtensa ELF with ~196 KB of Go runtime — docs/24 §d)* |

## ABI & FFI correctness (the core result — docs 03/05)

| | **Rust** | **Zig** | **D** | **esp-clang** | **GCC** | **TinyGo** |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| windowed ABI (`entry`/`retw.n`, args `a2..a7`, `callx8`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| int / i64 / f32 / f64 / pointer / callback C-ABI | ✓ | ✓ | ✓ | ✓ | ✓ | ✓¹ |
| small struct `{i32,i32}` by value | ✓ | ✓³ | ✓⁵ | ✓ | ✓ | ✓ (flattens to scalars) |
| **under-aligned (`align(1)`) struct by-value *arg*** | ✓ | ✓⁴ | ✓⁵ | ✓ | ✓ | **✗** (byte-per-register, docs/24 §e) |
| **C-style bitfield struct by value** (16/32/64-bit packed) | — (no syntax) | ✓ via `packed struct(uN)` (explicit backing) | ✓⁵ | ✓ flattens to scalar `i32`/`[1×i64]` | ✓ flattens | — (no syntax) |
| small struct return (8-byte, in regs) | ✓ | ✓ | ✓⁵ | ✓ | ✓ | ✓ |
| large struct return (`sret`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| links under `ld.lld` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓² |
| links under GNU `ld` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓² |

> ¹ TinyGo scalar ABI matches clang per disasm (docs/22 §g; docs/24 §e).
> ² TinyGo `.o` links per-symbol but the consumer must supply the Go runtime
> undefs (`_heap_start`/`_heap_end`, `tinygo_swapTask`, `tinygo_startTask`,
> `tinygo_scanCurrentStack`) or accept the full runtime — docs/24 §d.
> ³ The legacy `$ZIG_016` lane mis-lowers RISC-V `{i32,i32}` to `[2 x i64]`
> (`zig_point_dot FAIL got=-2130706553` on riscv qemu); xtensa was already
> fine on 0.16. Zig 0.17 (`$ZIG` canonical) closes the riscv gap —
> docs/05/09/17.
> ⁴ Zig 0.17 (`$ZIG` canonical) flattens align-1 aggregates to `[N x i32]`
> like clang and passes the by-value blob_sum (`xtensa zig_blob_sum ok 300`).
> The legacy `$ZIG_016` lane reproduces the original docs/05 break:
> stack-spill via `movsp` for the align-1 aggregate, `zig_blob_sum FAIL
> got=409 want=300` at qemu. Swap with `ZIG=$ZIG_016 ./scripts/build-ffi.sh
> esp32`.
> ⁵ LDC 1.42.0 (the 2026-05-30 maintainer re-upload on LLVM 22.1.4) closes
> the universal D `byval`/`sret` aggregate ABI bug that LDC 1.42-git on LLVM
> 21.1.3 carried. The frontend now lowers aggregates to `[N x i32]` like
> clang, so `d_point_dot`/`d_blob_sum` pass byte-identically to clang's
> register-passing convention; `d_make_point` returns in registers via the
> windowed ABI's small-struct-return slot. Disasm: `d_point_dot` reads from
> `a2/a3/a4/a5` (matches clang `c_point_dot`); `d_make_point` is just
> `entry/retw.n`. qemu xtensa drops to **0 failures**; qemu riscv stays at
> 0. Docs/05 §"LDC 1.42 status", docs/19, docs/23. The old `$LDC2_UPSTREAM`
> arm of the fork-vs-upstream comparison (the pre-fix LDC on upstream-LLVM
> 22.1.2) still reproduces the broken IR; that's the regression-tracker
> baseline now, not the canonical.
>
> One outlier on the canonical lane. **TinyGo** still owns the byte-array
> hole: a `struct{[24]uint8}` lowers as `[24 x i8]` byte-per-register, not
> clang's `[6 x i32]` (docs/24 §e). Rust, clang, GCC, Zig 0.17, **and now
> LDC 1.42.0** all agree on every other row. The historical D bug was
> **frontend-side** — confirmed by `$LDC2_UPSTREAM` (LDC on upstream LLVM
> 22.1.2, pre-fix) producing the same broken IR the old fork did; the new
> 1.42 fork drops the byval/sret universal lowering even though it's still
> using a 22.1.4 backend (docs/23 §(h)). **Use by-pointer structs across
> any TinyGo boundary if the field is a byte array** (the only case
> runtime-verified to corrupt today). On the canonical Zig + canonical
> LDC the by-pointer workaround is no longer required for the cases
> documented in docs/05/19; the legacy `$ZIG_016` lane and the upstream
> `$LDC2_UPSTREAM` arm are the reproducers for the historical breaks.

## Codegen, tooling & misc

| | **Rust** | **Zig** | **D** | **esp-clang** | **GCC** | **TinyGo** |
|---|---|---|---|---|---|---|
| 9-fn lib `.text`, esp32 `-Os` | **171 B** | **375 B** (zig 0.17 canonical; `$ZIG_016` legacy is 715 B) | 489 B | 219 B (C) / 204 B (C++) | **201 B** | n/a (whole-firmware; single `add_i32` is 7 B, docs/22 §g) |
| symbol mangling (internal) | v0 `_R…` / legacy `_ZN…` | module-qualified + export alias | D `_D…` / Itanium `_Z…` for `extern(C++)` | Itanium `_Z…` | Itanium `_Z…` | `<package>.<func>` (e.g. `main.go_add_i32`); `//export name` re-emits as bare `name` |
| FFI export | `#[no_mangle] extern "C"` | `export fn` | `extern(C)` / `extern(C++[,"ns"])` | `extern "C"` | (C) | `//export name` |
| call / emit `@"mangled"` symbols | — | ✓ (docs/12) | ✓ native `extern(C++)` + `-HC` header (docs/19) | — | — | — |
| cross-language **LTO** peer | esp-clang (both 21.1.3) ✓ | ✗ skew (22.1.4 vs 21.1.3); **LDC-upstream ✓** via $LDC_LLVM_DIR's LLVM-22 binutils | **esp-clang ✓** (same 21.1.3; docs/19) | Rust ✓ | — (not LLVM) | ✗ skew (LLVM 20.1.1, docs/24) |
| call0 ABI | LLVM `-windowed` feat. | LLVM `-windowed` feat. | LLVM `-windowed` feat. | LLVM `-windowed` feat. | `-mabi=call0` | LLVM `-windowed` feat. (not exposed via TinyGo CLI) |
| f32: esp32 / esp32-s3 | HW FPU | HW FPU | HW FPU | HW FPU | HW FPU | HW FPU |
| f32: esp32-**s2** (no FPU) | soft `__mulsf3` | soft | soft | soft | soft | n/a (no s2 target, docs/24 §a) |
| soft-float/builtins | `compiler_builtins` | `compiler_rt` | `compiler-rt` | `compiler-rt` | `libgcc` | bundled `compiler-rt` + Go runtime |
| runtime-run on qemu | ✓ (docs/08/09) | ✓ | ✓ (docs/19) | ✓ | ✓ (objs) | standalone via `tinygo flash` (docs/24) |

## Safety-feature parity on Espressif targets

| feature | **Rust** | **Zig** | **D** (LDC) | **esp-clang** | **GCC** | **TinyGo** |
|---|---|---|---|---|---|---|
| safe-by-default ("opt-in `unsafe`") | ✓ unsafe keyword | partial — runtime UB checks in Debug only (overflow/bounds/null deref) | opt-in `@safe`; default `@system`. `-preview=safer` enables stricter `@safe` (docs/20) | ✓ GC + bounds-checks; no raw pointer arithmetic | ✗ | ✗ |
| compile-time array bounds | ✓ in safe Rust | ✓ in Debug | ✓ in `@safe` | ✓ always | ✗ (UB on overrun) | ✗ |
| ownership / borrow checker | ✓ builtin | partial (single-ownership via `*const`/`*` distinction) | `@live` + `-preview=dip1021` (docs/20 §8 — catches LEAK Rust's checker doesn't) | n/a (GC) | n/a | n/a |
| `-fsanitize=address` | n/a on Xtensa | n/a on Xtensa | **accepted but no runtime** (`libclang_rt.asan-xtensa.a` not shipped → link fails) | n/a on Xtensa | n/a on Xtensa | n/a |
| `-fsanitize=undefined` (UBSan) | `-Zsanitize=…` (nightly) | `-fsanitize=undefined` | **rejected** by LDC (`Unrecognized -fsanitize value 'undefined'`) | n/a on Xtensa | n/a on Xtensa | n/a |
| `-fstack-protector` on freestanding xtensa | depends on target spec | **errors**: `enabling stack protection requires libc` | accepts (linker pulls `__stack_chk_*` from runtime if available) | accepts — emits `*UND*` `__stack_chk_fail`/`_guard`, linkable | accepts | (Go runtime checks) |
| `-fxray-instrument` (LLVM call tracing) | n/a | n/a | **silent no-op on Xtensa** (no `xray_*` sections emitted) | n/a on Xtensa | n/a | n/a |
| `must-use` (`#[must_use]` / `@mustuse` / `[[nodiscard]]`) | ✓ fn + type, warn | partial via `_ = expr` discard requirement | ✓ DIP1038 TYPE-only; fn marker "reserved" (docs/20 §7) | ✓ `[[nodiscard]]` C++17+ | ✓ same | ✗ (no warning) |
| explicit-discard (`_ = expr`) required | partial | ✓ | ✓ via `cast(void)` | n/a | n/a | implicit |
| static borrow-leak detection | ✗ (`mem::forget` is safe) | ✗ | ✓ `@live` (docs/20 §8) | ✗ | ✗ | ✗ (GC handles) |
| concurrency: data-race protection | ✓ `Send`/`Sync` | partial via `atomic` ordering | partial via `shared T*` (docs/atomics-orders) + `@safe` rules | ✓ Go scheduler + races detector (host only) | ✗ | ✗ |
| TLS / `threadlocal` on baremetal Xtensa | not exposed | silently emits `R_XTENSA_TLS_TPOFF` + `rur threadptr` (no userland sets the SR) | `__thread` rejected on baremetal | n/a (GC + scheduler manages goroutine-locals) | not in scope | not in scope |
| atomics — native `s32c1i` (esp32 LX6) | ✓ | ✓ | ✓ via `ldc.intrinsics.llvm_atomic_*` (`shared T*` required, docs/atomics-orders) | ✓ (compiler-rt fallback when not native) | ✓ inline | ✓ |
| atomics — `compare_exchange` on **esp32-s2** | **✗** (target spec sets `atomic-cas=false`) | n/a | n/a | **✗** (lowers to `__atomic_compare_exchange_4` libcall → link fails) | n/a | n/a |
| `f16` half-precision | accepted; libcalls (`__extendhfsf2`/`__truncsfhf2`) **missing** in xtensa `compiler_builtins` → link fails | f16 not exposed | not exposed | not exposed | `__fp16` accepted; needs compiler-rt | accepted | n/a |
| u128 / `__int128` | ✓ native | ✓ native | **✗** `cent`/`ucent` formally obsoleted ("use core.int128.Cent", needs druntime) | ✗ rejected on xtensa | ✗ rejected on xtensa | ✗ no native |
| `-fno-omit-frame-pointer` on register-heavy fn | rustc + `compiler_builtins` ICE (esp-rs #270) — Rust-specific | ✓ | ✓ no ICE (`-fp=all`) | ✓ no ICE | ✓ | ✓ |

## One-line verdict

The shared LLVM backend gives a **shared, interoperable ABI** across the six
toolchains on Espressif Xtensa for everything except **by-value aggregate
lowering** in three frontends: **Zig** (align-1 only), **D** (universal —
every aggregate including bitfields, docs/05/19), and **TinyGo**
(byte-array fields only, docs/24). Use **by-pointer** structs across those
boundaries. Rust matches clang/GCC bit-for-bit. On the canonical 0.17 lane:
Rust the smallest (171 B), then GCC (201 B), clang (204/219 B), zig 0.17
(375 B), D the largest (489 B from byval/sret marshalling). Legacy
`$ZIG_016` reproduces the old 715 B zig figure. TinyGo is whole-firmware.
Object files link across all six with `ld.lld` and GNU `ld` (D direct `-c`
since docs/23; TinyGo `.o` needs runtime undefs satisfied per docs/24 §d).
Cross-language LTO needs compatible LLVM bitcode — clang↔rust↔D (all 21.1.3,
the canonical "LLVM-21 cluster") work; zig 0.17 (LLVM 22.1.4) and TinyGo
(LLVM 20.1.1) are version-skew outliers. The optional `$LDC2_UPSTREAM` +
`$LDC_LLVM_DIR` pairing (both LLVM-22.x) opens a second LTO cluster with zig
0.17. D has the
richest C/C++ FFI surface (native Itanium mangling, `-HC` headers). Details:
docs 01–24; `Research.md`.
