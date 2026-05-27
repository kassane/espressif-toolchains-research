void ee_add(signed char* d, const signed char* a, const signed char* b){
  __asm__ volatile(
    "ee.vld.128.ip q0, %1, 0\n"
    "ee.vld.128.ip q1, %2, 0\n"
    "ee.vadds.s8   q2, q0, q1\n"
    "ee.vst.128.ip q2, %0, 0\n"
    : : "r"(d), "r"(a), "r"(b) : "memory");
}
