/*
 * ffi_abi.h - shared C-ABI contract for the cross-language FFI matrix.
 *
 * Every backend language (C, C++, Rust, Zig) implements the SAME set of
 * functions, distinguished only by a language prefix:
 *
 *     c_*    implemented in C        (lib_c.c)
 *     cpp_*  implemented in C++      (lib_cpp.cpp, extern "C")
 *     rs_*   implemented in Rust     (lib_rs.rs, #[no_mangle] extern "C")
 *     zig_*  implemented in Zig      (lib_zig.zig, export fn)
 *     d_*    implemented in D        (d/lib_d.d, extern(C), LDC -betterC)
 *
 * Because they all expose the platform C ABI, any language's driver can call
 * any other language's implementation. The function set is chosen to exercise
 * the ABI corners that matter on Xtensa:
 *
 *   - integer args/returns in a-registers (a2..a7)
 *   - 64-bit values in even/odd register pairs
 *   - float/double: Xtensa passes FP in *integer* a-registers (no FP arg regs)
 *   - small struct (<=16 bytes) returned in registers
 *   - large struct (>16 bytes) returned via hidden sret pointer
 *   - struct passed by value
 *   - indirect call through a function pointer (windowed CALL8 vs CALL0)
 */
#ifndef FFI_ABI_H
#define FFI_ABI_H

#include <stdint.h>

typedef struct Point {
    int32_t x;
    int32_t y;
} Point; /* 8 bytes: returned in regs, passed in regs */

typedef struct Blob {
    uint8_t data[24];
} Blob; /* 24 bytes (>16): returned via sret, passed by reference/stack */

typedef int32_t (*BinOp)(int32_t, int32_t);

#define FFI_DECLARE(prefix)                                                    \
    int32_t  prefix##_add_i32(int32_t a, int32_t b);                           \
    int64_t  prefix##_add_i64(int64_t a, int64_t b);                           \
    float    prefix##_mul_f32(float a, float b);                               \
    double   prefix##_mul_f64(double a, double b);                             \
    Point    prefix##_make_point(int32_t x, int32_t y);                        \
    int32_t  prefix##_point_dot(Point a, Point b);                             \
    Blob     prefix##_make_blob(uint8_t fill);                                 \
    uint32_t prefix##_blob_sum(Blob b);                                        \
    int32_t  prefix##_apply(BinOp fn, int32_t a, int32_t b);

#ifdef __cplusplus
extern "C" {
#endif

FFI_DECLARE(c)
FFI_DECLARE(cpp)
FFI_DECLARE(rs)
FFI_DECLARE(zig)
FFI_DECLARE(d)

/* By-POINTER variant of blob_sum. A pointer is a plain scalar (a-reg a2), so it
 * sidesteps the by-value aggregate-passing ABI entirely. Used by the qemu
 * harness to show that the struct-by-value break (Zig align-1, D all structs;
 * docs/19) is fixed by passing structs by pointer — there all languages agree. */
uint32_t c_blob_sum_ptr(const Blob *b);
uint32_t zig_blob_sum_ptr(const Blob *b);
uint32_t d_blob_sum_ptr(const Blob *b);

#ifdef __cplusplus
}
#endif

#endif /* FFI_ABI_H */
