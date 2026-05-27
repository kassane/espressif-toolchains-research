/* qemu-system-riscv32 `virt` machine: RAM at 0x80000000, loaded via -bios. */
ENTRY(_start)
MEMORY {
  ram (rwx) : ORIGIN = 0x80000000, LENGTH = 0x1000000
}
SECTIONS {
  .text : { *(.text.start) *(.text .text.*) } > ram
  .rodata : { *(.rodata .rodata.*) } > ram
  .data : { *(.data .data.*) } > ram
  .bss : { *(.bss .bss.* COMMON) } > ram
  _stack_top = ORIGIN(ram) + LENGTH(ram) - 16;
}
