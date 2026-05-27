# 18 — Address-space support across frontends (Xtensa)

How `zig cc`/clang, gcc, Zig and Rust handle pointer **address spaces** on Xtensa,
and how that relates to ESP memory regions (IRAM / DRAM / flash / RTC).
Reproduce with `experiments/addrspace/run.sh`.

## The Xtensa backend has one flat address space

The target datalayout is `e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32` — only
`p:32:32` (address space 0), **no `p1:`/`p2:` entries**. So the LLVM Xtensa
backend models a single flat 32-bit address space; any `addrspace(N)` is an
**annotation that does not change codegen** (no segment/region selection like
AVR `__flash` or GPU `global`/`shared`).

## Frontend support for the address-space *syntax*

| frontend | syntax | on Xtensa |
|----------|--------|-----------|
| **clang** | `__attribute__((address_space(N)))` | **accepted** — emits `ptr addrspace(N)` IR and compiles; backend flattens it to a normal 32-bit pointer |
| **gcc** | (numbered attr is a clang ext) | **ignored** — `warning: 'address_space' attribute directive ignored`; gcc only has *named* spaces (none defined for Xtensa) |
| **Zig** | `*addrspace(.x) T` + `std.builtin.AddressSpace` | **only `.generic`** — the enum's named spaces are target-gated; `*addrspace(.flash) T` errors: *"pointers with address space 'flash' are not supported on xtensa"* (flash is AVR; global/shared are GPU; gs/fs x86) |
| **Rust** | — (no surface syntax) | **none** — all pointers are `addrspace(0)` |

So on Xtensa: clang carries the annotation through to IR (no-op codegen), Zig
*validates* address spaces against the target (rejecting non-applicable ones — the
strictest, most correct behavior), gcc silently ignores the numbered attribute,
and Rust has no concept of it. None give distinct codegen, because the backend has
no distinct spaces.

## ESP memory regions are a *linker-section* job, not address spaces

IRAM / DRAM / flash(.rodata) / RTC placement on ESP is **not** expressed with LLVM
address spaces — it's done with **named sections + the linker script**. All four
frontends support placing a symbol in, e.g., `.iram1.text`, and produce the same
section:

| frontend | attribute | result |
|----------|-----------|--------|
| clang / gcc | `__attribute__((section(".iram1.text")))` | `.iram1.text` |
| Zig | `linksection(".iram1.text")` | `.iram1.text` |
| Rust | `#[link_section = ".iram1.text"]` | `.iram1.text` |

(ESP-IDF's macros — `IRAM_ATTR`, `DRAM_ATTR`, `RTC_*_ATTR` — are exactly
`section(...)` wrappers; the linker script maps those sections to the physical
regions.)

## Verdict

Address spaces are effectively a **no-op on Xtensa** in every toolchain (the
backend is single-flat-address-space). The differences are only in the *frontend
syntax surface*: clang accepts numbered spaces (annotation), **Zig validates and
rejects non-Xtensa ones** (the most rigorous), gcc ignores the numbered form, Rust
has none. The real, fully-portable mechanism for ESP memory regions is **linker
sections** (`section`/`linksection`/`link_section`) + the linker script — and
there all four are at parity.
