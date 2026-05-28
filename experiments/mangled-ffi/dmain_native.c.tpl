// Template for run.sh: %DSYM% is replaced with the actual `_D...` symbol
// extracted from d_lib.o via `nm`. The mangled symbol IS a valid C identifier
// (starts with `_`, only `[A-Za-z0-9_]`), so we just declare it directly.
//
// Equivalent in other languages:
//   - Zig: `extern fn @"_D5d_lib8d_secretFiZi"(x: i32) callconv(.c) i32;`
//   - D:   `extern(C) pragma(mangle, "_D...") int d_secret(int);`
//
// D's extern(D) ABI is documented but not formally stable, so reach-the-symbol
// via the C ABI only works because LDC uses the C calling convention for
// plain free functions on x86_64 — fragile across platforms / D-runtime types.
#include <stdio.h>
extern int %DSYM%(int x);
int main(void){
    int r = %DSYM%(5);   /* d_secret(5) = 5 + 100 = 105 */
    printf("c -> D extern(D)-mangled d_secret(5) via direct symbol: %d (expect 105)\n", r);
    return r != 105;
}
