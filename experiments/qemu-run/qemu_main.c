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

static void putdec(long v) {
    char t[12]; int n = 0; unsigned long u = (v < 0) ? -(unsigned long)v : (unsigned long)v;
    if (v < 0) puts_("-");
    if (u == 0) { puts_("0"); return; }
    while (u) { t[n++] = (char)('0' + u % 10); u /= 10; }
    char b[12]; int i = 0; while (n) b[i++] = t[--n]; b[i] = 0; puts_(b);
}

static void check(const char* name, long got, long want) {
    puts_(name);
    if (got == want) { puts_("  ok ("); putdec(got); puts_(")\n"); }
    else { puts_("  FAIL (got="); putdec(got); puts_(" want="); putdec(want); puts_(")\n"); fails++; }
}

int xmain(void) {
    puts_("\n== FFI runtime on qemu-system-xtensa (windowed ABI) ==\n");

    puts_("- scalar add_i32(3,4)==7 [expect all ok]:\n");
    check(" c  ", c_add_i32(3, 4), 7);
    check(" cpp", cpp_add_i32(3, 4), 7);
    check(" rs ", rs_add_i32(3, 4), 7);
    check(" zig", zig_add_i32(3, 4), 7);

    puts_("- point_dot: 8B align-4 struct by value ==11 [expect all ok]:\n");
    Point pa = { 1, 2 }, pb = { 3, 4 };
    check(" c  ", c_point_dot(pa, pb), 11);
    check(" rs ", rs_point_dot(pa, pb), 11);
    check(" zig", zig_point_dot(pa, pb), 11);

    puts_("- blob_sum: 24B align-1 struct by value ==300 [zig expected to FAIL]:\n");
    Blob bl;
    for (int i = 0; i < 24; i++) bl.data[i] = (unsigned char)(i + 1); /* sum 1..24 = 300 */
    check(" c  ", (long)c_blob_sum(bl), 300);
    check(" cpp", (long)cpp_blob_sum(bl), 300);
    check(" rs ", (long)rs_blob_sum(bl), 300);
    check(" zig", (long)zig_blob_sum(bl), 300);

    puts_("total failures: "); putdec(fails); puts_("\n");
    sys_exit(fails);
    return fails;
}
