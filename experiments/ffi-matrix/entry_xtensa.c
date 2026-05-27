/*
 * entry_xtensa.c - minimal freestanding entry for the bare-metal Xtensa link.
 *
 * We do not execute this image (no esp32 in the loop); we link it fully so the
 * cross-language symbols resolve, then disassemble. _start simply references
 * run_ffi_tests so the linker pulls in every backend object, and stores the
 * result where a symbol table / debugger can see it.
 */
#include <stdint.h>

extern int run_ffi_tests(void);

volatile int g_ffi_result;

__attribute__((noreturn, used)) void _start(void) {
    g_ffi_result = run_ffi_tests();
    for (;;) {
        /* spin */
    }
}
