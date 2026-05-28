// D side: same ABI probes as Rust/Zig. -betterC (no druntime/Phobos), like
// Rust no_std / Zig freestanding. Notes:
//  - `cent`/`ucent` are reserved keywords but the *types* are obsolete in
//    DMD/LDC; the language tells you so at the diagnostic site (see (a)).
//    The drop-in replacement is the library type `core.int128.Cent` — a
//    `struct { ulong lo, hi; }` operated on by free functions. It compiles
//    under -betterC but its calling convention is the struct ABI (sret/byval),
//    NOT the native `i128` Rust/Zig hand to the backend.
//  - D has no native `f16`/`f128`; `real` is 8 bytes on Xtensa (= double).
//  - Nullable pointer is the C convention: `T*` is itself nullable.
//  - `core.atomic` is header-only enough for -betterC for primitive ops.
module iface;

import core.int128;
import core.atomic;

extern (C):

// --- (1) 128-bit integer via core.int128.Cent (cent/ucent type itself is obsolete) ---
Cent d_add_u128(Cent a, Cent b) { return add(a, b); }

// --- (2) Atomics: hand-roll on core.atomic. Backend should emit s32c1i. ---
uint d_atomic_add(shared(uint)* p) { return atomicFetchAdd(*p, 1); }
uint d_atomic_cas(shared(uint)* p, uint e, uint n) {
    uint expected = e;
    cas(p, &expected, n);
    return expected;
}

// --- (3) Nullable pointer: extern(C) raw pointer = the nullable convention. ---
size_t d_opt(const(ubyte)* p) {
    return p is null ? 0 : cast(size_t)p;
}

// --- (4) u64 / i64 across the C ABI ---
ulong d_add_u64(ulong a, ulong b) { return a + b; }
long  d_add_i64(long  a, long  b) { return a + b; }
