/* rt_gcc.c — GCC-built caller for #278 (compiled by xtensa-esp-elf-gcc, not
 * clang). Same narrow extern decl, different toolchain. */
extern unsigned fm_u32_callee(int x1, int x2, int x3, int x4, int x5, int x6,
                              unsigned char a1, unsigned short a2,
                              unsigned char a3, unsigned short a4,
                              unsigned char a5);
unsigned gcc_issue278_callm(unsigned char a, unsigned short b,
                            unsigned char c, unsigned short d,
                            unsigned char e) {
    return fm_u32_callee(1, 2, 3, 4, 5, 6, a, b, c, d, e);
}
