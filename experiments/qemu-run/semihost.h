#ifndef SEMIHOST_H
#define SEMIHOST_H
/* qemu-system-xtensa semihosting via the simcall opcode:
   a2=call#, a3/a4/a5=args, result in a2. SYS_write=4 (fd,buf,len), SYS_exit=1. */
static inline long xt_simcall(long n, long a, long b, long c) {
    register long r2 __asm__("a2") = n;
    register long r3 __asm__("a3") = a;
    register long r4 __asm__("a4") = b;
    register long r5 __asm__("a5") = c;
    __asm__ volatile("simcall" : "+r"(r2), "+r"(r3) : "r"(r4), "r"(r5) : "memory");
    return r2;
}
static inline int  slen(const char* s){ int n=0; while(s[n]) n++; return n; }
static inline void puts_(const char* s){ xt_simcall(4, 1, (long)s, slen(s)); }
static inline void sys_exit(int c){ xt_simcall(1, c, 0, 0); }
#endif
