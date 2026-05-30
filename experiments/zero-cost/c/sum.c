/* sum.c — C baseline: hand-written for-loop accumulator. */
int sum_c(const int *p, int n) {
    int s = 0;
    for (int i = 0; i < n; i++) s += p[i];
    return s;
}
