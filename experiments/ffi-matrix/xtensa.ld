/*
 * xtensa.ld - deliberately minimal linker script for the FFI link test.
 *
 * This is NOT a real esp32 image layout (no bootloader header, no vectors, no
 * flash/IRAM split). It exists only to let a mixed C/C++/Rust/Zig object set
 * link into one fully-resolved ELF so we can disassemble it and confirm the
 * calling conventions agree. Addresses are placed in the esp32 DRAM range.
 */
ENTRY(_start)

MEMORY
{
    ram (rwx) : ORIGIN = 0x3FFB0000, LENGTH = 0x50000
}

SECTIONS
{
    .text : {
        *(.literal .text .literal.* .text.*)
    } > ram

    .rodata : {
        *(.rodata .rodata.*)
    } > ram

    .data : {
        *(.data .data.*)
    } > ram

    .bss : {
        *(.bss .bss.* COMMON)
    } > ram

    /DISCARD/ : {
        *(.comment .note .note.* .xt.lit .xt.prop .debug_*)
    }
}
