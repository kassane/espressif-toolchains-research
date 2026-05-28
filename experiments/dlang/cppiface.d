// cppiface.d - D's C and C++ FFI surface, for the LDC deep-dive (docs/19).
//
// D speaks four linkage flavours, selected by `extern(...)`:
//   extern(C)            - C ABI, C mangling (bare symbol name)
//   extern(C++)          - C++ Itanium ABI + mangling, global namespace
//   extern(C++, "ns")    - same, mangled into C++ namespace `ns`
//   extern(C++, class|struct) - pick the C++ aggregate kind for mangling
//
// A D `struct` is a value type (like a C/C++ struct); a D `class` is a
// reference type (like a C++ class, always by pointer/reference). Build with
// `ldc2 -HC` to emit a matching C++ header (see run.sh).

extern (C) int d_c_add(int a, int b)
{
    return a + b;
}

extern (C++) int cpp_add(int a, int b)
{
    return a + b;
}

extern (C++, "espffi") int ns_add(int a, int b)
{
    return a + b;
}

// extern(C++) value type. `ref const` maps to a C++ `const&`.
extern (C++) struct Vec2
{
    float x;
    float y;
}

extern (C++) float vec_dot(ref const Vec2 a, ref const Vec2 b)
{
    return a.x * b.x + a.y * b.y;
}
