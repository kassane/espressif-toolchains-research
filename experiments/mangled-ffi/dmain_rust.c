#include <stdio.h>
extern int d_calls_rust(int);
int main(void){
    int r = d_calls_rust(7);   /* d -> rust_triple(7) via pragma(mangle, "_R...") = 21 */
    printf("d -> v0-mangled Rust rust_triple(7) via pragma(mangle): %d (expect 21)\n", r);
    return r != 21;
}
