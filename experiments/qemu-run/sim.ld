ENTRY(_reset)
MEMORY {
  rom (rwx) : ORIGIN = 0xFE000000, LENGTH = 0x100000
  ram (rw)  : ORIGIN = 0x00000000, LENGTH = 0x08000000
}
SECTIONS {
  .text 0xFE000000 : {
    KEEP(*(.reset))
    . = ALIGN(1024);
    KEEP(*(.vectors))
    *(.literal.start .literal .literal.*)
    *(.text.start .text .text.*)
  } > rom
  .rodata : { *(.rodata .rodata.*) } > ram
  .data   : { *(.data .data.*) } > ram
  .bss    : { *(.bss .bss.* COMMON) } > ram
  _stack_top = 0x04000000;
}
