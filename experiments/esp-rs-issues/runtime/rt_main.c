#include <stdarg.h>
#include "semihost.h"
extern int rs_vsum(int n, ...);            /* Rust C-variadic (#177) */
extern int rs_find_pos(unsigned needle, const unsigned* p, unsigned n); /* #161 */
static int c_find_pos(unsigned needle, const unsigned* p, unsigned n){ for(unsigned i=0;i<n;i++) if(p[i]==needle) return (int)i; return -1; }
int c_vsum(int n, ...) {                    /* C baseline */
    va_list ap; va_start(ap, n); int s = 0;
    for (int i = 0; i < n; i++) s += va_arg(ap, int);
    va_end(ap); return s;
}

/* ---- #278: narrow stack-arg store hazard runtime test ----
 *
 * The callee is in rt_callee.c (declared with FULL u32 params). On Xtensa it
 * reads each stack slot with l32i, so any upper bytes left undefined by a
 * narrow caller store are visible as garbage. The result `a+b+c+d+e` only
 * matches the expected value if the caller widened to s32i (the issue's
 * recommended behavior). esp-rs/rust#278 reported Rust uses narrow stores
 * and so triggers this corruption; this test reproduces it.
 *
 * For the test we use small positive values that fit in u8/u16, so the
 * "correct" sum is small and any garbage upper bytes blow it past 64K.
 *
 * Each frontend declares fm_u32_callee with NARROW types so the call-site
 * codegen sees only u8/u16; this prevents the compiler from "fixing" the
 * width through cross-TU type analysis. Mirrors the real Rust-binding
 * scenario (Rust binding declares the C library function with u8/u16
 * because the C header used u8_t/u16_t typedefs). */
extern unsigned fm_u32_callee(int x1, int x2, int x3, int x4, int x5, int x6,
                              unsigned char a1, unsigned short a2,
                              unsigned char a3, unsigned short a4,
                              unsigned char a5);
/* Per-frontend callers in their own TUs so the call sites are NOT inlined
 * into xmain (which would let the compiler constant-propagate the literal
 * args directly to s32i.n stores, sidestepping the narrow-store bug). The
 * callers all use the narrow extern decl above; each frontend's caller is
 * built by run.sh:
 *   rt_clang.c → clang_issue278_callm
 *   rt_gcc.c   → gcc_issue278_callm
 *   rt.rs      → rs_issue278_callm
 *   rt_zig.zig → zig_issue278_callm
 *   rt_d.d     → d_issue278_callm
 */
extern unsigned clang_issue278_callm(unsigned char a, unsigned short b,
                                     unsigned char c, unsigned short d,
                                     unsigned char e);
extern unsigned gcc_issue278_callm(unsigned char a, unsigned short b,
                                   unsigned char c, unsigned short d,
                                   unsigned char e);
extern unsigned rs_issue278_callm(unsigned char a, unsigned short b,
                                  unsigned char c, unsigned short d,
                                  unsigned char e);
extern unsigned zig_issue278_callm(unsigned char a, unsigned short b,
                                   unsigned char c, unsigned short d,
                                   unsigned char e);
extern unsigned d_issue278_callm(unsigned char a, unsigned short b,
                                 unsigned char c, unsigned short d,
                                 unsigned char e);
/* Legacy lanes for the same probe. */
extern unsigned zig016_issue278_callm(unsigned char a, unsigned short b,
                                      unsigned char c, unsigned short d,
                                      unsigned char e);
extern unsigned d_upstream_issue278_callm(unsigned char a, unsigned short b,
                                          unsigned char c, unsigned short d,
                                          unsigned char e);
extern unsigned zigcc_issue278_callm(unsigned char a, unsigned short b,
                                     unsigned char c, unsigned short d,
                                     unsigned char e);
static void putdec(long v){ static const unsigned long pw[10]={1000000000UL,100000000UL,10000000UL,1000000UL,100000UL,10000UL,1000UL,100UL,10UL,1UL};
  unsigned long u=v<0?-(unsigned long)v:(unsigned long)v; if(v<0)puts_("-"); char b[12]; int i=0,st=0;
  for(int k=0;k<10;k++){int d=0; while(u>=pw[k]){u-=pw[k];d++;} if(d||st||k==9){b[i++]=(char)('0'+d);st=1;}} b[i]=0; puts_(b); }
int xmain(void){
    int c = c_vsum(4, 10, 20, 30, 40);     /* baseline: 100 */
    int r = rs_vsum(4, 10, 20, 30, 40);    /* #177: 100 if correct, garbage if buggy */
    puts_("\n#177 C variadics on Xtensa:\n  c_vsum(10,20,30,40)  = "); putdec(c); puts_(c==100?"  ok\n":"  FAIL\n");
    puts_("  rs_vsum(10,20,30,40) = "); putdec(r); puts_(r==100?"  ok\n":"  FAIL (#177 reproduces)\n");
    unsigned arr[3]={0xFFFF00u,0x0000FFu,0x00FF00u};
    int ci=c_find_pos(0x0000FFu,arr,3), ri=rs_find_pos(0x0000FFu,arr,3); /* blue -> 1 */
    puts_("#161 Iterator::position (opt=s):\n  c_find_pos  = "); putdec(ci); puts_(ci==1?"  ok\n":"  FAIL\n");
    puts_("  rs_find_pos = "); putdec(ri); puts_(ri==1?"  ok\n":"  FAIL (#161 reproduces)\n");

    /* #278: narrow stack-arg vs widened-read mismatch. Call each frontend's
     * callm(10, 20, 30, 40, 50) where args are u8/u16. The C-side fm_u32_callee
     * reads them as u32 and returns the sum. Expected: 10+20+30+40+50 = 150.
     * If the caller widened (s32i), sum is exactly 150. If the caller narrowed
     * (s8i/s16i) and the upper bytes happen to be nonzero on this stack frame,
     * sum is huge garbage (>> 150). */
    puts_("\n#278 narrow stack-arg vs u32-callee read (expected 150 = 10+20+30+40+50):\n");
    unsigned cs = clang_issue278_callm(10, 20, 30, 40, 50);
    puts_("  clang_issue278_callm = "); putdec(cs); puts_(cs==150?"  ok\n":"  FAIL (#278 reproduces)\n");
    unsigned gs = gcc_issue278_callm(10, 20, 30, 40, 50);
    puts_("  gcc_issue278_callm   = "); putdec(gs); puts_(gs==150?"  ok\n":"  FAIL (#278 reproduces)\n");
    unsigned rs = rs_issue278_callm(10, 20, 30, 40, 50);
    puts_("  rs_issue278_callm    = "); putdec(rs); puts_(rs==150?"  ok\n":"  FAIL (#278 reproduces)\n");
    unsigned zs = zig_issue278_callm(10, 20, 30, 40, 50);
    puts_("  zig_issue278_callm   = "); putdec(zs); puts_(zs==150?"  ok\n":"  FAIL (#278 reproduces)\n");
    unsigned ds = d_issue278_callm(10, 20, 30, 40, 50);
    puts_("  d_issue278_callm     = "); putdec(ds); puts_(ds==150?"  ok\n":"  FAIL (#278 reproduces)\n");
    /* Legacy lanes (Zig 0.16 / LLVM 21.1.0; LDC 1.42-git upstream / LLVM 22.1.2). */
    unsigned z16 = zig016_issue278_callm(10, 20, 30, 40, 50);
    puts_("  zig016_issue278_callm = "); putdec(z16); puts_(z16==150?"  ok\n":"  FAIL (#278 reproduces)\n");
    unsigned dup = d_upstream_issue278_callm(10, 20, 30, 40, 50);
    puts_("  d_upstream_callm      = "); putdec(dup); puts_(dup==150?"  ok\n":"  FAIL (#278 reproduces)\n");
    unsigned zcc = zigcc_issue278_callm(10, 20, 30, 40, 50);
    puts_("  zigcc_issue278_callm  = "); putdec(zcc); puts_(zcc==150?"  ok\n":"  FAIL (#278 reproduces)\n");

    sys_exit((c==100 && r==100 && ci==1 && ri==1)?0:1); return 0;
}
