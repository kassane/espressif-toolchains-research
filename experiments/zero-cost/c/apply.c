/* apply.c — function-pointer apply: the lowest-level higher-order form. */
typedef int (*int_fn)(int);

int apply_c(int_fn f, int x) { return f(x); }

/* Concrete user with a known callee. The compiler CAN'T inline through the fn-ptr
 * at -Os unless it does devirtualization (which clang at -Os doesn't here). */
int doubler_c(int x) { return x + x; }

int call_apply_c(int x) { return apply_c(doubler_c, x); }
