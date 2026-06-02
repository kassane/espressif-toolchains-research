/* rt_clang.c — clang-built caller for #278 in its own TU so the caller can
 * NOT inline into xmain and constant-propagate the literal args into widened
 * s32i stores. Mirrors rt_gcc.c for the gcc-built peer. */
extern unsigned fm_u32_callee(int x1, int x2, int x3, int x4, int x5, int x6,
                              unsigned char a1, unsigned short a2,
                              unsigned char a3, unsigned short a4,
                              unsigned char a5);
unsigned clang_issue278_callm(unsigned char a, unsigned short b,
                              unsigned char c, unsigned short d,
                              unsigned char e) {
    return fm_u32_callee(1, 2, 3, 4, 5, 6, a, b, c, d, e);
}
