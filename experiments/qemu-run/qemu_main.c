/*
 * qemu_main.c - run the cross-language FFI checks on an emulated Xtensa core
 * (qemu-system-xtensa `sim` machine) and report via semihosting.
 *
 * This turns the static ABI analysis into a runtime result. Expectation:
 *   - scalar + align-4 struct calls pass for ALL languages;
 *   - the align-1 (byte-array) `blob_sum` by-value call FAILS for Zig only,
 *     because Zig's experimental Xtensa target diverges from the C ABI for
 *     under-aligned by-value struct arguments (see docs/05).
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

    puts_("- point_dot: 8B struct by value ==11 [xtensa: d FAIL; riscv: zig FAIL]:\n");
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

    puts_("- blob_sum: 24B struct by value ==300 [xtensa: zig+d FAIL; riscv: ok]:\n");
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
