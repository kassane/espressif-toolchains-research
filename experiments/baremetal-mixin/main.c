/* main.c - reset-shim "application glue" for the Rust+Zig bare-metal mixin.
 * Calls the Rust app_main() (which drives the Zig kernel), reports via
 * semihosting, and exits. Arch-neutral: pair with the xtensa or riscv harness
 * in ../qemu-run. */
#include "semihost.h"

extern int app_main(int* out); /* Rust */

static void putdec(long v) {
    static const unsigned long pw[10] = {
        1000000000UL,100000000UL,10000000UL,1000000UL,100000UL,10000UL,1000UL,100UL,10UL,1UL };
    unsigned long u = (v < 0) ? -(unsigned long)v : (unsigned long)v;
    if (v < 0) puts_("-");
    char b[12]; int i = 0, started = 0;
    for (int k = 0; k < 10; k++) {
        int d = 0; while (u >= pw[k]) { u -= pw[k]; d++; }
        if (d || started || k == 9) { b[i++] = (char)('0' + d); started = 1; }
    }
    b[i] = 0; puts_(b);
}

int xmain(void) {
    int r = 0;
    int rc = app_main(&r);
    puts_("\nRust+Zig bare-metal mixin on emulated ESP\n");
    puts_("  Rust app -> zig_scale(x2) -> zig_sum_of_squares (buffers by pointer)\n");
    puts_("  result = "); putdec((long)r);
    puts_((rc == 0 && r == 816) ? "  OK (expected 816)\n" : "  FAIL\n");
    sys_exit((rc == 0 && r == 816) ? 0 : 1);
    return 0;
}
