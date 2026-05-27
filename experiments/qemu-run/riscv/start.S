    /* RISC-V bare-metal entry for the qemu `virt` machine. No register windows
       and no trap vectors needed: set the stack pointer, call xmain, and let
       semihosting handle I/O + exit. */
    .section .text.start,"ax",@progbits
    .global _start
_start:
    la   sp, _stack_top
    call xmain
1:  j 1b
