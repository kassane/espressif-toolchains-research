// dispatch.d — D static dispatch via struct + template. (-betterC).
//
// Note on the dynamic-dispatch side: D's `class` form gives you virtual
// dispatch (vtable) — but `class` in -betterC requires manual allocation
// (no GC), which moves the test apparatus from "is virtual dispatch
// zero-cost" to "what's the cost of constructing the class on a manual
// allocator." That's covered in d/heap.d; here we stay on the static
// side so the comparison with C++ static CRTP / Rust impl Trait is
// apples-to-apples.
module dispatch;
extern (C):

// Static counter: template parameter `Step` is a compile-time constant,
// so `tick()` knows what it's adding at codegen time. Identical to C++
// `StaticCounter<3>::tick()` and Rust `static_loop::<CounterRs>`.
struct StaticCounterD(int Step) {
    int v = 0;
    int tick() @system { v += Step; return v; }
}

@system int use_static_d(int n) {
    auto c = StaticCounterD!3();
    int last = 0;
    for (int i = 0; i < n; i++) last = c.tick();
    return last;
}
