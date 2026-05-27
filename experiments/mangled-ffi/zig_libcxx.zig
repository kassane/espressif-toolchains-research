// Calling the C++ standard library from Zig.
//
//   extern "c++"  names libc++ as the dependency. Zig still REQUIRES the
//                 dependency to be confirmed on the build command with -lc++
//                 (otherwise: "dependency on libc++ must be explicitly
//                 specified"). So you need BOTH `extern "c++"` and `-lc++`.
//   @"_Znwm" ...  references the mangled libc++ symbols directly.
//
// (Host context: bare-metal ESP code avoids libc++ entirely — see docs/11.)
extern "c++" fn @"_Znwm"(n: usize) callconv(.c) ?*anyopaque; // operator new(size_t)
extern "c++" fn @"_ZdlPv"(p: ?*anyopaque) callconv(.c) void; // operator delete(void*)

export fn zig_libcxx_roundtrip(n: usize) i32 {
    const p = @"_Znwm"(n) orelse return -1;
    @"_ZdlPv"(p);
    return 42;
}
