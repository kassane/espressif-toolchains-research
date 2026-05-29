/*
 * qemu_main.c - run the cross-language FFI checks on an emulated Xtensa core
 * (qemu-system-xtensa `sim` machine) and report via semihosting.
 *
 * This turns the static ABI analysis into a runtime result. Expectation on
 * the *canonical* lane (esp-clang 21.1.3 + rustc 21.1.3 + LDC canonical 21.1.3
 * + Zig 0.17.0-xtensa / LLVM 22.1.4):
 *   - scalars + struct returns pass for ALL five languages (c/cpp/rs/zig/d);
 *   - by-value struct ARGS pass for c/cpp/rs/zig — Zig 0.17 closed the docs/05
 *     align-1 gap by lowering aggregate args as `[N x i32]` (matches clang);
 *   - D still marks every aggregate byval/sret so D MISSES the align-4 `point_dot`
 *     AND the align-1 `blob_sum` on Xtensa (docs/19; LDC-frontend bug);
 *   - passing the same struct BY POINTER works for all (the documented fix).
 *
 * Legacy lane (`ZIG=$ZIG_016 ...`): Zig 0.16 / LLVM 21.1.0 mis-lowers the
 * align-1 `blob_sum` to a movsp stack spill, so the Zig row joins D on the
 * by-value Blob — that's the original docs/05 + docs/09 break, reproducible by
 * flipping $ZIG.
 */
#include "ffi_abi.h"
#include "semihost.h"

static int fails;

/* No / or % : the dc233c sim core lacks esp32's mul32high (`muluh`), which the
   compiler would emit for divide-by-10. Decimal via subtraction + a powers
   table keeps this runnable on the generic sim core. */
static void putdec(long v) {
    static const unsigned long pw[10] = {
        1000000000UL, 100000000UL, 10000000UL, 1000000UL, 100000UL,
        10000UL, 1000UL, 100UL, 10UL, 1UL
    };
    unsigned long u = (v < 0) ? -(unsigned long)v : (unsigned long)v;
    if (v < 0) puts_("-");
    char b[12]; int i = 0, started = 0;
    for (int k = 0; k < 10; k++) {
        int d = 0;
        while (u >= pw[k]) { u -= pw[k]; d++; }
        if (d || started || k == 9) { b[i++] = (char)('0' + d); started = 1; }
    }
    b[i] = 0; puts_(b);
}

static void check(const char* name, long got, long want) {
    puts_(name);
    if (got == want) { puts_("  ok ("); putdec(got); puts_(")\n"); }
    else { puts_("  FAIL (got="); putdec(got); puts_(" want="); putdec(want); puts_(")\n"); fails++; }
}

int xmain(void) {
    puts_("\n== FFI runtime on emulated ESP core (qemu) ==\n");

    puts_("- scalar add_i32(3,4)==7 [expect all ok]:\n");
    check(" c  ", c_add_i32(3, 4), 7);
    check(" cpp", cpp_add_i32(3, 4), 7);
    check(" rs ", rs_add_i32(3, 4), 7);
    check(" zig", zig_add_i32(3, 4), 7);
    check(" d  ", d_add_i32(3, 4), 7);

    puts_("- point_dot: 8B struct by value ==11 [xtensa: d FAIL; riscv 0.16: zig FAIL, 0.17: ok]:\n");
    Point pa = { 1, 2 }, pb = { 3, 4 };
    check(" c  ", c_point_dot(pa, pb), 11);
    check(" rs ", rs_point_dot(pa, pb), 11);
    check(" zig", zig_point_dot(pa, pb), 11);
#ifdef __XTENSA__
    /* D marks every by-value struct `byval` (indirect). On Xtensa the backend
       passes it on the stack, but clang put it in regs a2..a5 -> wrong (stale)
       data. So even the align-4 Point diverges (broader than Zig, which only
       breaks align-1). On RISC-V the same `byval` becomes a REAL pointer arg,
       so D would dereference clang's register *value* (1) as an address -> wild
       load + hang; hence d_point_dot is xtensa-only here. See docs/19. */
    check(" d  ", d_point_dot(pa, pb), 11);
#else
    puts_(" d    SKIP (byval->ptr deref faults on riscv small struct; docs/19)\n");
#endif

    puts_("- blob_sum: 24B struct by value ==300 [xtensa 0.17: d FAIL (zig ok); 0.16: zig+d FAIL]:\n");
    Blob bl;
    for (int i = 0; i < 24; i++) bl.data[i] = (unsigned char)(i + 1); /* sum 1..24 = 300 */
    check(" c  ", (long)c_blob_sum(bl), 300);
    check(" cpp", (long)cpp_blob_sum(bl), 300);
    check(" rs ", (long)rs_blob_sum(bl), 300);
    check(" zig", (long)zig_blob_sum(bl), 300);
    /* >16B: the RISC-V C ABI itself passes this by reference, so D's `byval`
       (also a pointer) MATCHES clang there -> d ok on riscv. On Xtensa clang
       packs it into a2..a7 while D reads the stack -> d FAIL. */
    check(" d  ", (long)d_blob_sum(bl), 300);

    /* Mitigation: pass the SAME struct by POINTER. D's `ref`/pointer params are
       plain scalar pointers (a2..) -> all five agree. d_blob_sum_ptr proves the
       by-value break above is purely the aggregate-passing convention. */
    puts_("- blob_sum BY POINTER ==300 [expect all ok incl. d]:\n");
    check(" c  ", (long)c_blob_sum_ptr(&bl), 300);
    check(" zig", (long)zig_blob_sum_ptr(&bl), 300);
    check(" d  ", (long)d_blob_sum_ptr(&bl), 300);

    puts_("total failures: "); putdec(fails); puts_("\n");
    sys_exit(fails);
    return fails;
}
