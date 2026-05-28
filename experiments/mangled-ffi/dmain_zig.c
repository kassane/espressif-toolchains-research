#include <stdio.h>
extern int d_consumes_zig_ns(void);
int main(void){
    int r = d_consumes_zig_ns();   /* D's extern(C++,"ns") fn() resolves to Zig's export */
    printf("d -> Zig-defined ns::fn() via shared Itanium mangling: %d (expect 99)\n", r);
    return r != 99;
}
