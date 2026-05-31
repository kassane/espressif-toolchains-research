// esp.c — ESP32-P4 (RISC-V rv32imafc) vendor PIE/ESPV vector ops via inline
// asm. Targets `-mcpu=esp32p4eco4` because the broadly-documented mnemonics
// belong to ESPV 2.1; plain esp32p4 (ESPV 2.2) has different opcodes whose
// spellings aren't yet public. See docs/27 for the toolchain notes.
//
// Vector regs q0..q? + accumulators qacc/xacc, 128-bit wide — same q-reg
// model as the xtensa s3 EE.* PIE, just with `esp.*` mnemonics.
void esp_add(signed char* d, const signed char* a, const signed char* b){
  __asm__ volatile(
    "esp.vld.128.ip q0, %1, 0\n"
    "esp.vld.128.ip q1, %2, 0\n"
    "esp.vadd.s8    q2, q0, q1\n"
    "esp.vst.128.ip q2, %0, 0\n"
    : : "r"(d), "r"(a), "r"(b) : "memory");
}
