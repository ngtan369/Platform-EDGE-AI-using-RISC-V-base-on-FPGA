# Startup code cho RISC-V CV32E40P (PULPino/PULP architecture)

.section .vectors, "ax"
.option norvc
.org 0x0
.global _start

# 1. Bảng Vector ngắt (Interrupt Vector Table)
# Địa chỉ 0x0 luôn là lệnh nhảy đến trình xử lý Reset
_start:
    j reset_handler          # Reset Handler
    .rept 31
    j default_handler        # Các ngắt khác (tạm thời bỏ qua)
    .endr

.section .text
reset_handler:
    # 2. Thiết lập con trỏ Stack (Stack Pointer - sp)
    # Lấy giá trị _stack_top từ Linker Script (thường là cuối BRAM)
    la sp, _stack_top

    # 3. Thiết lập con trỏ toàn cục (Global Pointer - gp)
    # Giúp truy cập các biến toàn cục nhanh hơn (tùy chọn nhưng nên có)
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    # 4. Xóa phân vùng BSS (Zeroing BSS)
    # Đưa các biến toàn cục chưa khởi tạo về giá trị 0
    la a0, _bss_start
    la a1, _bss_end
    bge a0, a1, end_init_bss
loop_init_bss:
    sw zero, 0(a0)
    addi a0, a0, 4
    blt a0, a1, loop_init_bss
end_init_bss:

    # 5. Nhảy vào hàm main của C
    # Sau khi chuẩn bị xong xuôi, "trao quyền" cho main.c
    jal ra, main

    # 6. Vòng lặp vô tận nếu main thoát ra
    # Ngăn CPU chạy lung tung vào vùng nhớ lạ
1:  j 1b

default_handler:
    j default_handler