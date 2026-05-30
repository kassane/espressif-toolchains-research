// apply.d — D higher-order: function pointer vs templated callable.
module apply;
extern (C):

int doubler_d(int x) { return x + x; }

// (1) Raw function pointer — indirect call
alias int_fn = int function(int);

@system int apply_d_fnptr(int_fn f, int x) { return f(x); }
@system int call_apply_d_fnptr(int x) { return apply_d_fnptr(&doubler_d, x); }

// (2) Templated apply — F is part of the symbol so the body of the callable
//     is visible at the instantiation site → inlined like C++/Rust.
@system int apply_d_tmpl(F)(F f, int x) { return f(x); }

// Need a non-extern(C) callable wrapper because extern(C) lambdas can't
// type-check here; use a static-method struct (D's idiomatic functor form).
struct DoublerD { static int call(int x) { return x + x; } }

@system int call_apply_d_tmpl(int x) {
    return apply_d_tmpl!(typeof(&DoublerD.call))(&DoublerD.call, x);
}
