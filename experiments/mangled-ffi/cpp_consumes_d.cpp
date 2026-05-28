// cpp_consumes_d.cpp - declarations of D-implemented functions. Because D's
// extern(C++) mangling is byte-identical to clang/gcc Itanium mangling, these
// ordinary C++ prototypes resolve to the symbols emitted by d_lib.d.
#include <cstdio>
int cpp_add(int, int);             // -> _Z7cpp_addii (defined in D)
namespace ns { int fn(); }         // -> _ZN2ns2fnEv  (defined in D)
int main(void){
    int r = cpp_add(20, 22) + ns::fn() - 99;  // 42 + 99 - 99 = 42
    std::printf("c++ -> D extern(C++) cpp_add(20,22) + ns::fn() match: %d (expect 42)\n", r);
    return r != 42;
}
