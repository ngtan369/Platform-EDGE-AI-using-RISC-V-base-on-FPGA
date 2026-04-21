/* Định nghĩa vùng nhớ BRAM */
MEMORY
{
    ram (rwx) : ORIGIN = 0x00000000, LENGTH = 64K /* Tùy chỉnh theo size BRAM của bạn */
}

SECTIONS
{
    /* Lớp code thực thi */
    .text : {
        . = ALIGN(4);
        *(.text.vectors) /* Vector bảng ngắt nằm đầu tiên */
        *(.text*)
        . = ALIGN(4);
    } > ram

    /* Dữ liệu hằng số (Trọng số AI nằm ở đây) */
    .rodata : {
        . = ALIGN(4);
        *(.rodata*)
        . = ALIGN(4);
    } > ram

    /* Dữ liệu có giá trị khởi tạo */
    .data : {
        . = ALIGN(4);
        *(.data*)
        . = ALIGN(4);
    } > ram

    /* Dữ liệu không khởi tạo (Biến tạm) */
    .bss : {
        . = ALIGN(4);
        *(.bss*)
        . = ALIGN(4);
    } > ram

    _stack_top = ORIGIN(ram) + LENGTH(ram);
}