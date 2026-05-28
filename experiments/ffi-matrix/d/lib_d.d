// lib_d.d - D implementation of the FFI contract (prefix: d_), built with LDC.
//
// `extern(C):` gives every following symbol the C ABI and C mangling (no D
// name mangling). `-betterC` drops druntime/Phobos (no GC, no ModuleInfo, no
// TypeInfo), the D analogue of Rust `no_std` / Zig `freestanding`, so the
// object links into a -nostdlib image. A D `struct` is a value type with C
// layout (like a C struct); a D `class` would be a reference type, so structs
// are the right choice for the by-value contract here.
module lib_d;

extern (C):

struct Point
{
    int x;
    int y;
} // 8 bytes

struct Blob
{
    ubyte[24] data;
} // 24 bytes (>16)

alias BinOp = extern (C) int function(int, int);

int d_add_i32(int a, int b)
{
    return a + b;
}

long d_add_i64(long a, long b)
{
    return a + b;
}

float d_mul_f32(float a, float b)
{
    return a * b;
}

double d_mul_f64(double a, double b)
{
    return a * b;
}

Point d_make_point(int x, int y)
{
    return Point(x, y);
}

int d_point_dot(Point a, Point b)
{
    return a.x * b.x + a.y * b.y;
}

Blob d_make_blob(ubyte fill)
{
    Blob b;
    foreach (i; 0 .. 24)
        b.data[i] = cast(ubyte)(fill + i);
    return b;
}

uint d_blob_sum(Blob b)
{
    uint s = 0;
    foreach (v; b.data)
        s += v;
    return s;
}

int d_apply(BinOp f, int a, int b)
{
    return f(a, b);
}

// By-pointer variant: `b` is a plain pointer (scalar in a-reg a2), so this
// sidesteps the by-value aggregate ABI that diverges on Xtensa (see docs/19).
uint d_blob_sum_ptr(const(Blob)* b)
{
    uint s = 0;
    foreach (v; b.data)
        s += v;
    return s;
}
