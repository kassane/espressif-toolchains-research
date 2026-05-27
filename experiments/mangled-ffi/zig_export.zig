// Zig DEFINES C++-mangled symbols via @"..." on `export fn`. C++ code that calls
// demo::add / scale(int,int) links against these Zig implementations -- Zig
// masquerades as the C++ functions, no extern "C" needed on either side.
export fn @"_ZN4demo3addEii"(a: i32, b: i32) callconv(.c) i32 { return a +% b; }
export fn @"_Z5scaleii"(x: i32, k: i32) callconv(.c) i32 { return x *% k; }
