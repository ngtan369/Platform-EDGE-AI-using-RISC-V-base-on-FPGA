/* CV32E40P bare-metal linker script — split I/D BRAM layout
 *
 * Phải khớp với Vivado Address Editor:
 *   IRAM  (axi_bram_ctrl_0, I-BRAM Port A) → 0x0000_0000, 64 KB   — instr fetch
 *   DRAM  (axi_bram_ctrl_1, D-BRAM Port A) → 0xB004_0000, 256 KB  — data/stack
 *
 * Peripheral base (cho .c source, không phải linker):
 *   axi_dma_0/S_AXI_LITE  = 0xB000_0000
 *   conv_cnn_0/S00_AXI    = 0xB001_0000
 */

MEMORY
{
    IRAM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
    DRAM (rwx) : ORIGIN = 0xB0040000, LENGTH = 256K
}

ENTRY(_start)

SECTIONS
{
    .text : {
        . = ALIGN(4);
        *(.text.vectors)        /* reset/trap vectors first */
        *(.text*)
        . = ALIGN(4);
    } > IRAM

    .rodata : {
        . = ALIGN(4);
        *(.rodata*)
        . = ALIGN(4);
    } > IRAM

    .data : {
        . = ALIGN(4);
        _data_start = .;
        *(.data*)
        . = ALIGN(4);
        _data_end = .;
    } > DRAM

    .bss : {
        . = ALIGN(4);
        _bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > DRAM

    . = ALIGN(16);
    _heap_start = .;

    _stack_top = ORIGIN(DRAM) + LENGTH(DRAM);   /* 0xB008_0000 */
}
