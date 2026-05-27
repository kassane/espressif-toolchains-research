extern int zigsq(int);            /* defined in Zig */
int sum_sq(int n) { int s = 0; for (int i = 1; i <= n; i++) s += zigsq(i); return s; }
