import os
import time
import numpy as np
from pynq import Overlay, MMIO

# ==========================================
# CẤU HÌNH HỆ THỐNG (Vivado Address Editor)
# ==========================================
BITSTREAM_FILE = "harvard_soc.bit"      # Tên file bitstream
RISCV_FIRMWARE = "riscv_code.bin"       # File code C đã biên dịch của lõi RISC-V
MODEL_WEIGHTS  = "vgg16_cats_dogs_int8.bin" # File INT8 bạn vừa train ở bước trước

# Kích thước BRAM
BRAM_SIZE = 65536 
# Mailbox: 4 byte cuối cùng của D-BRAM
MAILBOX_OFFSET = BRAM_SIZE - 4  

# Mã trạng thái Mailbox (Giữa ARM và RISC-V)
STATUS_IDLE       = 0x00000000
STATUS_RISCV_DONE = 0x00001111
STATUS_CNN_DONE   = 0x00003333

def load_bin_to_bram(bram_ctrl, filepath, offset=0):
    """Hàm đọc file nhị phân và đẩy trực tiếp vào BRAM qua AXI"""
    if not os.path.exists(filepath):
        raise FileNotFoundError(f"[!] Không tìm thấy file: {filepath}")
    
    print(f"[*] Đang nạp {filepath} vào bộ nhớ...")
    with open(filepath, "rb") as f:
        data = f.read()
        # Ghi từng chunk 4-byte (32-bit) vào BRAM
        for i in range(0, len(data), 4):
            chunk = data[i:i+4]
            # Padding nếu file không chia hết cho 4
            if len(chunk) < 4:
                chunk += b'\x00' * (4 - len(chunk))
            
            # Convert bytes sang số nguyên 32-bit (Little Endian)
            val = int.from_bytes(chunk, byteorder='little')
            bram_ctrl.write(offset + i, val)
    print(f"    -> Đã nạp xong {len(data)} bytes.")

# ==========================================
# LUỒNG THỰC THI CHÍNH CỦA ARM (HOST PS)
# ==========================================
if __name__ == '__main__':
    print("="*50)
    print(" HỆ THỐNG EDGE AI: DUAL-CORE (ARM + RISC-V) ")
    print("="*50)

    # 1. NẠP BITSTREAM CHO FPGA (Cấu hình toàn bộ phần cứng)
    print("\n[1] Đang nạp Bitstream cấu hình kiến trúc Harvard...")
    overlay = Overlay(BITSTREAM_FILE)
    
    # 2. ÁNH XẠ BỘ NHỚ BRAM
    # Lấy ra 2 khối AXI BRAM Controller đã cấu hình ở cổng A
    # (Lưu ý: Tên biến phải khớp CỰC KỲ CHÍNH XÁC với tên khối trong Vivado Block Design)
    i_bram = overlay.axi_bram_ctrl_0  # Instruction BRAM
    d_bram = overlay.axi_bram_ctrl_1  # Data BRAM

    # 3. NẠP DỮ LIỆU VÀO "TỦ 2 CỬA"
    print("\n[2] Nạp Code Lệnh và Trọng số INT8...")
    # Xóa sạch Mailbox trước khi chạy để tránh dính rác từ lần chạy trước
    d_bram.write(MAILBOX_OFFSET, STATUS_IDLE)
    
    # Nạp code C của vi điều khiển vào I-BRAM
    load_bin_to_bram(i_bram, RISCV_FIRMWARE, offset=0x0)
    
    # Nạp dữ liệu mô hình vào D-BRAM (Giả sử quy ước nhét ở địa chỉ offset 0x0000)
    load_bin_to_bram(d_bram, MODEL_WEIGHTS, offset=0x0)
    
    # Tương tự, nếu có ảnh đầu vào (Input Image), bạn nạp vào một offset khác:
    # load_bin_to_bram(d_bram, "cat_image_224x224.bin", offset=0x8000)

    # 4. KÍCH HOẠT RISC-V (Bấm nút Start)
    print("\n[3] Gửi tín hiệu Reset để đánh thức RISC-V...")
    # Thông thường, bạn sẽ gán 1 cổng AXI GPIO vào chân `rst_ni` của RISC-V.
    # Giả sử tên khối là axi_gpio_0, kênh 1.
    if hasattr(overlay, 'axi_gpio_0'):
        rst_gpio = overlay.axi_gpio_0.channel1
        rst_gpio.write(0, 0x0) # Kéo xuống 0 (Giữ reset)
        time.sleep(0.1)
        rst_gpio.write(0, 0x1) # Kéo lên 1 (Nhả reset cho RISC-V chạy)
    else:
        print("    [!] Cảnh báo: Không tìm thấy khối GPIO điều khiển Reset RISC-V.")

    # 5. CHỜ THƯ BÁO CÁO TỪ RISC-V (Polling Mailbox)
    print("\n[4] ARM đang chuyển sang chế độ ngủ chờ (Polling)...")
    start_time = time.time()
    
    while True:
        # Liên tục nhìn vào 4 byte cuối của D-BRAM
        status = d_bram.read(MAILBOX_OFFSET)
        
        if status == STATUS_RISCV_DONE:
            print("    -> RISC-V báo cáo: Khởi động thành công!")
            # Xóa thư cũ để chờ thư mới
            d_bram.write(MAILBOX_OFFSET, STATUS_IDLE) 
            
        elif status == STATUS_CNN_DONE:
            end_time = time.time()
            print(f"    -> RISC-V báo cáo: GIA TỐC CNN CHẠY XONG! (Mất {(end_time - start_time)*1000:.2f} ms)")
            break # Thoát vòng lặp chờ
            
        time.sleep(0.001) # Nghỉ 1ms để tránh ARM bị quá tải CPU (100% load)

    # 6. ĐỌC KẾT QUẢ VÀ HẬU XỬ LÝ (Post-processing)
    print("\n[5] Đọc kết quả từ Data BRAM...")
    # Giả sử kết quả (ví dụ 2 số nguyên đại diện cho % Chó/Mèo) nằm ở Offset 0x4000
    RESULT_OFFSET = 0x4000
    class_0_score = d_bram.read(RESULT_OFFSET)
    class_1_score = d_bram.read(RESULT_OFFSET + 4)
    
    print(f"    Class 0 Score (Cat): {class_0_score}")
    print(f"    Class 1 Score (Dog): {class_1_score}")
    
    if class_0_score > class_1_score:
        print("\n=> This is cat")
    else:
        print("\n=> This is dog")
        
    print("\n Run completed 100%!")