// sum.d — D zero-cost generic accumulator. -betterC compatible.
module sum;
extern (C):

// (1) Hand-rolled for-loop — lowest level
@system int sum_d_loop(const(int)* p, int n) {
    int s = 0;
    for (int i = 0; i < n; i++) s += p[i];
    return s;
}

// (2) Templated accumulator — D's `template` form. Instantiated at int.
//     The template parameter `T` is part of the symbol name in the IR; LDC
//     monomorphizes per-T and the body is identical to the loop above.
@system T sum_d_tmpl(T)(const(T)* p, int n) {
    T s = T.init;
    for (int i = 0; i < n; i++) s += p[i];
    return s;
}

@system int sum_d_tmpl_i32(const(int)* p, int n) { return sum_d_tmpl!int(p, n); }
