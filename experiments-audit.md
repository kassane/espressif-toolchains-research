# experiments-audit — load-bearing green per experiment

For each experiment, name the claim, the verification mechanism, the
strongest assertion in the source, and whether there is a known negative
control that flips that assertion back to FAIL when the canonical lane is
replaced by the legacy lane ($ZIG_016 / $LDC2_UPSTREAM) or by an explicit
mutation.

Reproduce with the per-experiment `run.sh` plus the new
`experiments/qemu-run/negative-controls.sh {canonical|zig016|ldc_upstream|all}
[xtensa|riscv]` wrapper.

**Hard rule applied throughout**: no assertion was relaxed to make a weak
experiment pass. Where the verification is non-load-bearing (e.g. "symbol
exists" with no expected value), the row is flagged — fixing it is a
separate engineering step.

## Strong (qemu PASS/FAIL counter + documented negative control)

| experiment | claim | verification | xtensa NC | riscv NC | load-bearing? |
|---|---|---|---|---|---|
| **ffi-matrix** | 5-frontend cross-language calls return expected values | `qemu_main.c` counts `g_fail`, exits with the count | `$ZIG_016 ./run-qemu.sh` → `zig blob_sum FAIL` reproduces (docs/05) | `$ZIG_016 ./run-qemu.sh riscv` → `zig point_dot FAIL` reproduces (docs/09) | **YES** (canonical passes; $ZIG_016 fails the exact documented case) |
| **esp-rs-issues runtime** | #161/#177/#278 cross-frontend runtime behavior | `rt_main.c` `xmain()` prints PASS/FAIL per call + `sys_exit(non-zero on FAIL)` | clang/rust both FAIL #278 narrow-store probe (3,159,446 ≠ 150 expected) — load-bearing because gcc/Zig/D PASS on the same harness | n/a (xtensa-only #278 today) | **YES** (#278 PASS/FAIL is a per-frontend ABI assertion) |
| **baremetal-mixin** | Rust + Zig + Zig→Rust callback co-linked, runs on qemu | hardcoded `result = 816` PASS/FAIL on both arches | Mutate `zig_sum_of_squares` return → expect harness FAIL (manual; no automatic mutation in tree) | same | **YES** for the 816 sum; **WEAK** for the structure of the test (single number) |
| **ldc-fork-comparison** | espressif-fork LDC vs upstream LDC produce different IR for same source | IR-grep + side-by-side disasm | `$LDC2_UPSTREAM` IR carries byval/sret; `$LDC2` does NOT (docs/23 §"What used to not flip") | n/a | **YES** when LDC_UPSTREAM=1; **n/a** without the opt-in artifact |

## Medium (disasm-grep with specific expected mnemonics)

| experiment | claim | verification | NC available? | load-bearing? |
|---|---|---|---|---|
| **abi-structs/sweep.sh** | clang/zig/D ABI for align-N struct args = REGISTERS vs STACK | grep for `s8i/s16i/s32i/l32i/movsp` per frontend per align | $ZIG_016 column flips align-1 byte arrays from REGISTERS to STACK (docs/05) | **YES** (the sweep IS the negative control — legacy column documents the fail mode) |
| **simd §3+§5+§7** | Inline asm `EE.*` (xtensa) / `esp.*` (riscv) byte-identical across 4 frontends | encoding-hex compare via md5 + side-by-side print | xtensa esp32 (no SIMD unit) rejects the asm — §4 + §7.5 ARE the canonical negative controls | **YES** |
| **tmp-parity** | 12 TMP capabilities × 3 languages → presence/absence + folded constants | `nm`-based symbol presence + disasm of folded constants (`li a0, 0x78` etc.) | none — pure compile-time evidence; no runtime exec | **MEDIUM** (compile-time-only; harder to negative-control short of mutating sources) |
| **zero-cost** | 4 abstraction scenarios → instruction count + byte width per language | `text_bytes()`/`count_insn()` arithmetic | C baseline serves as the bound; deviations show in the report but aren't asserted | **WEAK** (numbers are reported but not `[ N -le BOUND ]` asserted — risk of drift going unnoticed) |
| **call0-abi** | windowed vs CALL0 ABI produce different prologues | grep for `entry/retw.n` vs `addi a1, a1, -N / s32i a0` | swapping `-mcpu=<core>-windowed` flips the prologue (canonical control) | **YES** |
| **atomics-orders** | 4 frontends × N orderings → `s32c1i` + `memw` + libcall counts | grep counts | n/a — count differences are reported, not asserted | **WEAK** (no `[ count -eq N ]` check) |
| **addrspace** | clang/zig/gcc/rust/D address-space syntax + section placement | grep IR for `addrspace(N)` + ELF section names | n/a — surface inventory, not behavioural | **MEDIUM** (correctness of `linksection` is asserted; addrspace acceptance is reported) |
| **dwarf-parity** | DWARF section presence + add_i32 disasm size byte-count | per-tool extract + numeric compare | reference values pinned in tree (e.g. "clang/gcc: 14 B; LDC: 17 B byte-identical to clang") | **MEDIUM** (numbers are pinned but human-readable, not gated by `exit 1` on mismatch) |
| **rust-zig** | scalar/u128/atomics/nullable-ptr/packed-struct/LTO interop | qemu return + grep IR + link-test | qemu §a returns `300` / `11`; mismatch = fail | **YES** for §a (qemu); MEDIUM for the IR/link surfaces |
| **mangled-ffi** | Zig calling C++/Rust mangled symbols → expected return value | host-process `run` returns specific integer; mismatch = process exit nonzero | host-only (no qemu), but bash `set -e` propagates | **YES** on host; not exercised on target |
| **compiler-parity** | `zig cc`/esp-clang/esp-gcc emit interchangeable Xtensa C/C++ ABI | per-tool object compile + link probe | none specific; assumes link success = parity | **WEAK** (link success ≠ ABI equivalence; need a runtime cross-call probe) |
| **llvm-ir-mix** | LTO inlining + llvm-link module merge across frontends | grep linked IR for inlined function | clang↔zig LTO fails with `Invalid record` across the LLVM-21/22 cluster boundary — this IS the documented negative control | **YES** (the failure case is itself the demonstration) |
| **dlang §safety + §tmpffi + §ldc-attrs** | -betterC + @safe matrix + LDC __asm + import("file") | compile-only + grep + side-by-side | none beyond "compiles?"; the experiments are demonstrative | **MEDIUM** for safety (D rejects unsafe ops at compile time); **WEAK** for tmpffi (link-only) |
| **tinygo** | TinyGo `.o` size + ABI shape on esp32 | inspect emitted ELF | TinyGo on esp32s2 doesn't compile (no target) — implicit negative control | **MEDIUM** (out-of-FFI-matrix on purpose, docs/24) |

## Weak / observational (no exit code; report only)

| experiment | claim | what would make it load-bearing |
|---|---|---|
| **atomics-orders** | "5 fences per release-store on $ARCH" | wrap each count in `[ $count -eq $expected ] \|\| exit 1` |
| **zero-cost** | "sum_rs_loop = 10 insn / 23 B" | turn `report()` printf into per-row asserts with `BOUND` constants in tree |
| **compiler-parity** | "zig cc ≡ esp-clang at codegen" | add a `same_md5` assertion across `.text` of clang + zig cc object |
| **dlang tmpffi** | "5-frontend single ELF, 0 undef" | `[ "$undef" = "0" ] \|\| exit 1` (it already prints; just gate the exit) |

These weak rows are **not in scope** of the current GAP-2 commit (the HARD
constraint forbids relaxing assertions to pass; the symmetric move — gating
existing prints with `exit 1` — is the reverse fix and should land as
deliberate per-experiment commits after reviewer approval.)

## Reproducer

```
# canonical lane (default): both archs must report 0 failures
experiments/qemu-run/negative-controls.sh canonical xtensa
experiments/qemu-run/negative-controls.sh canonical riscv

# legacy $ZIG_016 lane: each arch must reproduce its documented FAIL
experiments/qemu-run/negative-controls.sh zig016 xtensa
experiments/qemu-run/negative-controls.sh zig016 riscv

# legacy $LDC2_UPSTREAM lane (opt-in, requires LDC_UPSTREAM=1):
experiments/qemu-run/negative-controls.sh ldc_upstream xtensa

# all of the above:
experiments/qemu-run/negative-controls.sh all
```

If the legacy lane stops failing, the canonical green has lost its
negative control — investigate before silently accepting.

## Discipline

- A green is **load-bearing** only when a mechanically-runnable mutation
  flips it red. The legacy `$ZIG_016` / `$LDC2_UPSTREAM` lanes are the
  primary mutation source: they isolate one frontend's pre-fix bytes
  against the canonical lane and re-run the same harness.
- For experiments without a runtime check (most disasm-grep + link-only
  rows), the negative control is the documented historical state in
  docs/05 / docs/09 / docs/19 / docs/23 — the IR diff between
  `$LDC2` and `$LDC2_UPSTREAM`, the byte-stride diff between `$ZIG_016`
  and `$ZIG`. These are reproducible from `experiments/ldc-fork-comparison`
  and `experiments/abi-structs/sweep.sh` respectively.
- Weak rows in the table above are deliberate WIP, not silent passes. The
  audit lists them so the reader knows where the green is decorative
  vs. mechanical. Fix-up commits should turn each weak row into a strong
  one without changing the experiment's intent.
