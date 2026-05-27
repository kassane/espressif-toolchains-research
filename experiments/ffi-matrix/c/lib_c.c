/* lib_c.c - C implementation of the FFI contract (prefix: c_). */
#include "ffi_abi.h"

int32_t c_add_i32(int32_t a, int32_t b) { return a + b; }
int64_t c_add_i64(int64_t a, int64_t b) { return a + b; }
float   c_mul_f32(float a, float b)     { return a * b; }
double  c_mul_f64(double a, double b)   { return a * b; }

Point c_make_point(int32_t x, int32_t y) {
    Point p = { x, y };
    return p;
}

int32_t c_point_dot(Point a, Point b) {
    return a.x * b.x + a.y * b.y;
}

Blob c_make_blob(uint8_t fill) {
    Blob b;
    for (int i = 0; i < 24; ++i) b.data[i] = (uint8_t)(fill + i);
    return b;
}

uint32_t c_blob_sum(Blob b) {
    uint32_t s = 0;
    for (int i = 0; i < 24; ++i) s += b.data[i];
    return s;
}

int32_t c_apply(BinOp fn, int32_t a, int32_t b) {
    return fn(a, b);
}
