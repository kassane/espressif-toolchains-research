// heap.d — D `class` in -betterC: the manual-allocator pattern.
//
// User's note: "D class in -betterC needs malloc/free or Mallocator".
//
// `-betterC` drops druntime, which means:
//   * No GC, so `new T()` (which calls _d_newclass via druntime) is unavailable.
//   * No TypeInfo bookkeeping, so the runtime can't construct vtables either —
//     but the compiler still emits the per-class vtable + ClassInfo at codegen.
//   * No `core.lifetime.emplace`, so we have to do the "allocate raw memory +
//     run the constructor" dance manually.
//
// The canonical pattern (mirrors what `std.experimental.allocator.Mallocator`
// would do under the hood, minus the runtime):
//   1. Get raw memory from `core.stdc.stdlib.malloc(__traits(classInstanceSize, C))`.
//   2. Copy `typeid(C).initializer` into it (the vtable pointer + initial field
//      values that druntime would normally write at the start of `new`).
//      In -betterC `typeid` isn't available either, so we hand-blit the
//      compiler-generated init symbol — `__ClassZ` (mangled).
//   3. Call the ctor.
//   4. Cast to the class reference and return.
//
// This experiment compares the resulting `.text` against the C++ `operator new`
// + placement-construct version and the Rust `malloc + raw write` version, to
// see whether the language-level abstraction costs anything at the machine level.
module heap;
extern (C):

// Hand-declared malloc/free — `import core.stdc.stdlib` fails on the
// xtensa-esp target because the bundled druntime headers reference `c_long`
// which isn't defined for non-standard platforms in -betterC. Declaring the
// signatures directly here is what every embedded D project does anyway
// (it's the same pattern docs/19 uses).
@nogc nothrow @system void* malloc(size_t);
@nogc nothrow @system void  free(void*);

// ---- (1) `class` in -betterC: extern(C++) lets us drop ClassInfo/TypeInfo
//          dependencies. The vtable is still emitted (per-class, in .rodata)
//          but no druntime hooks needed.
extern(C++) class Counter {
    int v = 0;
    int step;
    this(int s) @nogc @system { v = 0; step = s; }
    int tick() @nogc @system { v += step; return v; }
}

// The compiler emits a hidden `__ClassZ`-style init symbol for a normal D
// class; with extern(C++) the class is more like a C++ struct + vtable.
// `__traits(classInstanceSize, T)` is the size including the vtable ptr.
// Manual emplacement: malloc + ctor.
Counter make_counter_d(int step) @nogc @system {
    enum sz = __traits(classInstanceSize, Counter);
    auto raw = malloc(sz);
    if (raw is null) return null;
    auto c = cast(Counter) raw;
    c.__ctor(step);  // explicit ctor invocation — what `new` would do
    return c;
}

// ---- (2) Zero-allocation baseline: a D struct with the same shape. No
//          vtable, no heap, just stack-allocated. Anybody who'd reach for
//          a "Counter" object in a tight embedded loop should write this.
struct CounterStruct {
    int v = 0;
    int step;
    int tick() @nogc @system { v += step; return v; }
}

// Factory that builds and returns it by value — interesting because the
// 8-byte struct is small enough to fit in the Xtensa C-ABI register-return
// path (`[2 x i32]`), so the call site doesn't touch memory at all.
CounterStruct make_counter_struct_d(int step) @nogc @system {
    return CounterStruct(0, step);
}
