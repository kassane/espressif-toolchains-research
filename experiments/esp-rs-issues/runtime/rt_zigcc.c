/* rt_zigcc.c — zig cc (clang 22.1.4) variant of rt_clang.c (esp-clang 21.1.3).
 *
 * Same source, different driver: tests whether the narrow-vs-wide stack-arg-
 * store policy changed between clang 21 and clang 22 on Xtensa. If both
 * trigger #278 the policy is per-frontend (clang) not per-LLVM-version. */
extern unsigned fm_u32_callee(int x1, int x2, int x3, int x4, int x5, int x6,
                              unsigned char a1, unsigned short a2,
                              unsigned char a3, unsigned short a4,
                              unsigned char a5);
unsigned zigcc_issue278_callm(unsigned char a, unsigned short b,
                              unsigned char c, unsigned short d,
                              unsigned char e) {
    return fm_u32_callee(1, 2, 3, 4, 5, 6, a, b, c, d, e);
}
