extern int rs_sq(int);            /* defined in Rust */
int sum_sq(int n) { int s = 0; for (int i = 1; i <= n; i++) s += rs_sq(i); return s; }
