/*
 * driver.c - cross-language FFI driver. Always compiled as C.
 *
 * Calls every function from every backend language (c_/cpp_/rs_/zig_) with
 * known inputs and checks the results. This single translation unit therefore
 * links against object files produced by four different compilers, proving the
 * C ABI is the shared contract.
 *
 * Two build modes (selected by the FFI_HOSTED macro):
 *   - hosted:       printf a PASS/FAIL matrix and return the failure count.
 *                   Used for the x86_64 build we actually execute.
 *   - freestanding: no libc; results accumulate into observable globals.
 *                   Used for the bare-metal Xtensa link/disassembly build.
 */
#include "ffi_abi.h"

#ifdef FFI_HOSTED
#include <stdio.h>
#define LOG(...) printf(__VA_ARGS__)
#else
#define LOG(...) ((void)0)
#endif

/* Observable from a debugger / symbol table even in the freestanding build,
 * and prevents the optimizer from discarding the cross-language calls. */
volatile int      g_fail;
volatile uint32_t g_checksum;

static int feq32(float a, float b)  { float  d = a - b; return (d < 0 ? -d : d) < 1e-3f; }
static int feq64(double a, double b){ double d = a - b; return (d < 0 ? -d : d) < 1e-9;  }

/* A C callback handed to every language's *_apply. Multiplies (distinct from
 * add) so a wrong dispatch is caught. Exercises calling *back* into C. */
static int32_t c_callback(int32_t a, int32_t b) { return a * b; }

#define CHECK(cond, name)                                                      \
    do {                                                                       \
        if (!(cond)) { g_fail++; LOG("  FAIL %s\n", (name)); }                 \
        else         {           LOG("  ok   %s\n", (name)); }                 \
    } while (0)

/* Run the full contract against language with prefix P. */
#define TEST_LANG(P)                                                           \
    do {                                                                       \
        LOG("== %-4s ==\n", #P);                                               \
        CHECK(P##_add_i32(3, 4) == 7,                       #P "_add_i32");     \
        CHECK(P##_add_i64(0x100000000LL, 5) == 0x100000005LL, #P "_add_i64");  \
        CHECK(feq32(P##_mul_f32(1.5f, 2.0f), 3.0f),         #P "_mul_f32");     \
        CHECK(feq64(P##_mul_f64(1.5, 2.0), 3.0),            #P "_mul_f64");     \
        Point _pt = P##_make_point(3, 4);                                      \
        CHECK(_pt.x == 3 && _pt.y == 4,                     #P "_make_point");  \
        Point _a = { 1, 2 }, _b = { 3, 4 };                                    \
        CHECK(P##_point_dot(_a, _b) == 11,                  #P "_point_dot");   \
        Blob _bl = P##_make_blob(1);                                           \
        CHECK(_bl.data[0] == 1 && _bl.data[23] == 24,       #P "_make_blob");   \
        CHECK(P##_blob_sum(_bl) == 300u,                    #P "_blob_sum");    \
        CHECK(P##_apply(c_callback, 6, 7) == 42,            #P "_apply");       \
        g_checksum += (uint32_t)P##_add_i32(1, 1);                             \
    } while (0)

int run_ffi_tests(void) {
    g_fail = 0;
    TEST_LANG(c);
    TEST_LANG(cpp);
    TEST_LANG(rs);
    TEST_LANG(zig);
    LOG("total failures: %d\n", g_fail);
    return g_fail;
}

#ifdef FFI_HOSTED
int main(void) {
    int f = run_ffi_tests();
    LOG(f ? "\nRESULT: FAIL (%d failures)\n" : "\nRESULT: PASS (all 4 languages interop)\n", f);
    return f;
}
#endif
