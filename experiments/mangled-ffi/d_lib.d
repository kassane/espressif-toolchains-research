// d_lib.d - D produces three different mangled symbol flavours:
//   (1) extern(D)        - D's own mangling (`_D...`), the default linkage
//   (2) extern(C++)       - Itanium mangling (`_Z...`), byte-identical to clang/gcc
//   (3) extern(C++, "ns") - Itanium mangling into a C++ namespace
// All three are consumed from other frontends in run.sh.

// (1) D-native mangling. Symbol name will be `_D5d_lib8d_secretFiZi`
//     (module `d_lib`, fn `d_secret`, `F`unction taking `i`nt returning `i`nt).
int d_secret(int x) { return x + 100; }

// (2) extern(C++) - same `_Z...` Itanium scheme used by clang/gcc/LDC.
//     A C++ declaration `int cpp_add(int,int);` mangles to the SAME symbol.
extern(C++) int cpp_add(int a, int b) { return a + b; }

// (3) extern(C++, "ns") - Itanium-mangled into namespace `ns`. Pairs with
//     Zig's `export fn @"_ZN2ns2fnEv"` or C++ `namespace ns { int fn(); }`.
extern(C++, "ns") int fn() { return 99; }
