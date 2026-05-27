extern int sum_sq(int);
volatile int g_r;
__attribute__((noreturn)) void _start(void) { g_r = sum_sq(10); for (;;) {} }
