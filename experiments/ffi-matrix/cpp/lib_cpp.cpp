// lib_cpp.cpp - C++ implementation of the FFI contract (prefix: cpp_).
// Uses C++ internally (templates, std::array) but exposes a pure C ABI via
// extern "C". Compiled with -nostdlib / -ffreestanding for the Xtensa target,
// so it must not pull in libstdc++/libc++ or the C++ runtime.
#include "ffi_abi.h"

namespace {
template <typename T>
constexpr T add(T a, T b) { return a + b; }

template <typename T>
constexpr T mul(T a, T b) { return a * b; }
} // namespace

extern "C" {

int32_t cpp_add_i32(int32_t a, int32_t b) { return add(a, b); }
int64_t cpp_add_i64(int64_t a, int64_t b) { return add(a, b); }
float   cpp_mul_f32(float a, float b)     { return mul(a, b); }
double  cpp_mul_f64(double a, double b)   { return mul(a, b); }

Point cpp_make_point(int32_t x, int32_t y) { return Point{ x, y }; }

int32_t cpp_point_dot(Point a, Point b) {
    return a.x * b.x + a.y * b.y;
}

Blob cpp_make_blob(uint8_t fill) {
    Blob b{};
    for (int i = 0; i < 24; ++i) b.data[i] = static_cast<uint8_t>(fill + i);
    return b;
}

uint32_t cpp_blob_sum(Blob b) {
    uint32_t s = 0;
    for (int i = 0; i < 24; ++i) s += b.data[i];
    return s;
}

int32_t cpp_apply(BinOp fn, int32_t a, int32_t b) { return fn(a, b); }

} // extern "C"
