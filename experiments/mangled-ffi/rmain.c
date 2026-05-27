#include <stdio.h>
extern int zig_calls_rust(int);
int main(void){ int r=zig_calls_rust(7); printf("zig -> v0-mangled Rust rust_triple(7): %d (expect 21)\n", r); return r!=21; }
