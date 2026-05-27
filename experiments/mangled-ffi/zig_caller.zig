// Call NON-extern-"C" C++ functions directly by their Itanium-mangled symbol
// names, using Zig's @"..." identifier syntax. Free-function C++ ABI == C ABI,
// so callconv(.c) is correct. This avoids needing extern "C" wrappers on the C++.
extern fn @"_ZN4demo3addEii"(a: i32, b: i32) callconv(.c) i32; // demo::add(int,int)
extern fn @"_Z5scaleii"(x: i32, k: i32) callconv(.c) i32;       // scale(int,int) overload

export fn zig_calls_cpp(a: i32, b: i32) i32 {
    return @"_ZN4demo3addEii"(a, b) +% @"_Z5scaleii"(a, b); // (a+b) + (a*b)
}
