// sum.cpp — C++ baseline hand-loop, then a template instantiation.

extern "C" int sum_cpp_loop(const int *p, int n) {
    int s = 0;
    for (int i = 0; i < n; i++) s += p[i];
    return s;
}

// Generic accumulator template — should instantiate to identical code as
// sum_cpp_loop when T=int (Stroustrup's zero-cost abstraction claim).
template <typename T>
T sum_cpp_tmpl(const T *p, int n) {
    T s = T{};
    for (int i = 0; i < n; i++) s = s + p[i];
    return s;
}

extern "C" int sum_cpp_tmpl_i32(const int *p, int n) {
    return sum_cpp_tmpl<int>(p, n);
}
