// apply.cpp — function-pointer apply vs templated apply.

extern "C" int doubler_cpp(int x) { return x + x; }

// (1) Raw function pointer — indirect call, can't inline.
extern "C" int apply_cpp_fnptr(int (*f)(int), int x) { return f(x); }
extern "C" int call_apply_cpp_fnptr(int x) { return apply_cpp_fnptr(doubler_cpp, x); }

// (2) Template — the callable's type is part of the function template, so
// the compiler sees the body of the lambda/functor at instantiation time and
// can inline it. The two `call_apply_cpp_tmpl` and `call_apply_cpp_lambda`
// forms should both collapse to just the doubler body (add).
template <typename F>
int apply_cpp_tmpl(F f, int x) { return f(x); }

struct DoublerFunctor { int operator()(int x) const { return x + x; } };
extern "C" int call_apply_cpp_tmpl(int x) {
    return apply_cpp_tmpl(DoublerFunctor{}, x);
}

extern "C" int call_apply_cpp_lambda(int x) {
    auto dbl = [](int y) { return y + y; };
    return apply_cpp_tmpl(dbl, x);
}
