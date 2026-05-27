#ifndef SEMIHOST_H
#define SEMIHOST_H
/* RISC-V (ARM-style) semihosting for qemu: the magic
   `slli x0,x0,0x1f; ebreak; srai x0,x0,7` sequence with a0=op, a1=arg block.
   SYS_WRITE0 (0x04) writes a NUL-terminated string at a1; SYS_EXIT (0x18). */
static inline long rv_semihost(long op, void* arg) {
    register long a0 __asm__("a0") = op;
    register void* a1 __asm__("a1") = arg;
    __asm__ volatile(".option push\n.option norvc\n"
                     "slli x0, x0, 0x1f\n ebreak\n srai x0, x0, 7\n"
                     ".option pop\n"
                     : "+r"(a0) : "r"(a1) : "memory");
    return a0;
}
static inline void puts_(const char* s) { rv_semihost(0x04, (void*)s); }
static inline void sys_exit(int code) {
    long block[2] = { 0x20026 /* ADP_Stopped_ApplicationExit */, (long)code };
    rv_semihost(0x18, block);
}
#endif
