    /* Reset stub at the sim core reset vector (0xFE000000): plain `j`, no literals. */
    .section .reset,"ax",@progbits
    .global _reset
    .align 4
_reset:
    j _start

    /* Window overflow/underflow handlers at VECBASE-relative offsets.
       Canonical Xtensa sequences (ISA RM). Required or deep windowed-ABI call
       nesting traps with no handler. Only window vectors are needed: qemu
       handles `simcall` semihosting directly (not via an exception vector). */
    .section .vectors,"ax",@progbits
    .balign 1024
    .global _vectors
_vectors:
    .org 0x000          /* WindowOverflow4 */
    s32e a0, a5, -16
    s32e a1, a5, -12
    s32e a2, a5, -8
    s32e a3, a5, -4
    rfwo
    .org 0x040          /* WindowUnderflow4 */
    l32e a0, a5, -16
    l32e a1, a5, -12
    l32e a2, a5, -8
    l32e a3, a5, -4
    rfwu
    .org 0x080          /* WindowOverflow8 */
    s32e a0, a9, -16
    l32e a0, a1, -12
    s32e a1, a9, -12
    s32e a2, a9, -8
    s32e a3, a9, -4
    s32e a4, a0, -32
    s32e a5, a0, -28
    s32e a6, a0, -24
    s32e a7, a0, -20
    rfwo
    .org 0x0C0          /* WindowUnderflow8 */
    l32e a0, a9, -16
    l32e a1, a9, -12
    l32e a2, a9, -8
    l32e a7, a1, -12
    l32e a3, a9, -4
    l32e a4, a7, -32
    l32e a5, a7, -28
    l32e a6, a7, -24
    l32e a7, a7, -20
    rfwu
    .org 0x100          /* WindowOverflow12 */
    s32e a0, a13, -16
    l32e a0, a1, -12
    s32e a1, a13, -12
    s32e a2, a13, -8
    s32e a3, a13, -4
    s32e a4, a0, -48
    s32e a5, a0, -44
    s32e a6, a0, -40
    s32e a7, a0, -36
    s32e a8, a0, -32
    s32e a9, a0, -28
    s32e a10, a0, -24
    s32e a11, a0, -20
    rfwo
    .org 0x140          /* WindowUnderflow12 */
    l32e a0, a13, -16
    l32e a1, a13, -12
    l32e a2, a13, -8
    l32e a11, a1, -12
    l32e a3, a13, -4
    l32e a4, a11, -48
    l32e a5, a11, -44
    l32e a6, a11, -40
    l32e a7, a11, -36
    l32e a8, a11, -32
    l32e a9, a11, -28
    l32e a10, a11, -24
    l32e a11, a11, -20
    rfwu

    .section .text,"ax",@progbits
    .global _start
    .align 4
_start:
    movi a0, _vectors
    wsr  a0, vecbase
    rsync
    movi a0, 0
    wsr  a0, windowbase
    rsync
    movi a0, 1
    wsr  a0, windowstart
    rsync
    movi a0, 0x40000          /* PS.WOE = 1 */
    wsr  a0, ps
    rsync
    movi a1, _stack_top
    movi a8, xmain
    callx8 a8
1:  j 1b
