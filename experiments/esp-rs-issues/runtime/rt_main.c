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
    sys_exit((c==100 && r==100 && ci==1 && ri==1)?0:1); return 0;
}
