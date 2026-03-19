import cv2
import numpy as np
import os
import mmap
import time

# ==============================================================================
# 1. CẤU HÌNH BẢN ĐỒ BỘ NHỚ (Phải khớp với Vivado & C Firmware)
# ==============================================================================
# Địa chỉ Base của thanh ghi giao tiếp AXI Lite (Khối điều khiển)
# (Ví dụ: Vivado gán khối cpu_wrapper ở địa chỉ này)
AXI_REGS_BASE = 0x40000000 
AXI_REGS_SIZE = 0x1000       # Cấp 4KB cho các thanh ghi

# Các Offset thanh ghi (Khớp 100% với main.c của RISC-V)
OFF_CMD_ARM    = 0x00        # ARM ghi 1 để Start
OFF_STATUS_RV  = 0x04        # RISC-V ghi 2 khi Done
OFF_BBOX_XMIN  = 0x08
OFF_BBOX_YMIN  = 0x0C
OFF_BBOX_XMAX  = 0x10
OFF_BBOX_YMAX  = 0x14

# Địa chỉ Base của vùng RAM dùng chung chứa ảnh (Khối BRAM hoặc DDR)
SHARED_RAM_BASE = 0x80000000
IMG_WIDTH, IMG_HEIGHT = 128, 128 # Kích thước ảnh input của AI
SHARED_RAM_SIZE = IMG_WIDTH * IMG_HEIGHT * 3 # 3 kênh màu RGB

# Các cờ trạng thái (Flags)
CMD_START   = 1
STATUS_DONE = 2

# ==============================================================================
# 2. KHỞI TẠO KẾT NỐI VẬT LÝ (Dùng /dev/mem của Linux)
# ==============================================================================
print("Đang mở kết nối vật lý tới FPGA...")
f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)

# "Cắm vòi rồng" vào vùng thanh ghi điều khiển
mem_regs = mmap.mmap(f, AXI_REGS_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=AXI_REGS_BASE)

# "Cắm vòi rồng" vào vùng RAM chứa ảnh
mem_ram = mmap.mmap(f, SHARED_RAM_SIZE, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=SHARED_RAM_BASE)

# ==========================================
# 3. VÒNG LẶP CHÍNH (MAIN LOOP) - ĐẠO DIỄN LÊN SÀN
# ==========================================
# Mở Camera (MIPI trên Kria thường là device 0 hoặc 1)
cap = cv2.VideoCapture(0)

# Cấu hình độ phân giải camera bự để xem cho sướng (ví dụ 720p)
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)

print("Hệ thống đã sẵn sàng. Nhấn 'q' để thoát.")

while True:
    # BƯỚC 1: Đọc 1 khung hình từ Camera
    ret, frame_raw = cap.read()
    if not ret: break

    # BƯỚC 2: Tiền xử lý ảnh (Pre-processing)
    # Resize ảnh bự về kích thước 128x128 mà AI cần
    frame_resized = cv2.resize(frame_raw, (IMG_WIDTH, IMG_HEIGHT))
    # Chuyển sang RGB (OpenCV mặc định là BGR)
    frame_rgb = cv2.cvtColor(frame_resized, cv2.COLOR_BGR2RGB)
    # Chuyển sang dạng mảng byte INT8 (Lượng tử hóa ảnh input)
    frame_int8 = (frame_rgb.astype(np.float32) / 127.5 - 1.0) * 127
    frame_int8 = frame_int8.astype(np.int8)

    # BƯỚC 3: Đổ ảnh vào RAM dùng chung cho RISC-V đọc
    # Copy dữ liệu từ mảng Python vào vùng nhớ mmap
    mem_ram.seek(0)
    mem_ram.write(frame_int8.tobytes())

    # BƯỚC 4: Ra lệnh cho RISC-V "CÀY" MA TRẬN
    # Ghi số 1 (CMD_START) vào thanh ghi Offset 0x00
    mem_regs.seek(OFF_CMD_ARM)
    mem_regs.write(int(CMD_START).to_bytes(4, byteorder='little'))

    # BƯỚC 5: Chờ RISC-V tính xong (Polling)
    while True:
        mem_regs.seek(OFF_STATUS_RV)
        # Đọc 4 byte trạng thái
        status = int.from_ascii(mem_regs.read(4), byteorder='little')
        if status == STATUS_DONE:
            break # Đã xong!
        # Tạm nghỉ 1 chút để không làm quá tải CPU ARM
        time.sleep(0.001) 

    # BƯỚC 6: Đọc kết quả tọa độ từ FPGA
    mem_regs.seek(OFF_BBOX_XMIN)
    raw_xmin = int.from_bytes(mem_regs.read(4), byteorder='little', signed=True)
    mem_regs.seek(OFF_BBOX_YMIN)
    raw_ymin = int.from_bytes(mem_regs.read(4), byteorder='little', signed=True)
    mem_regs.seek(OFF_BBOX_XMAX)
    raw_xmax = int.from_bytes(mem_regs.read(4), byteorder='little', signed=True)
    mem_regs.seek(OFF_BBOX_YMAX)
    raw_ymax = int.from_bytes(mem_regs.read(4), byteorder='little', signed=True)

    # BƯỚC 7: Hậu xử lý (Post-processing) và Vẽ khung
    # Giải lượng tử hóa tọa độ (Chuyển INT8 về dải 0.0 -> 1.0)
    # (Công thức đảo ngược của việc train AI ban nãy)
    norm_xmin = (raw_xmin / 127.0 + 1.0) / 2.0
    norm_ymin = (raw_ymin / 127.0 + 1.0) / 2.0
    norm_xmax = (raw_xmax / 127.0 + 1.0) / 2.0
    norm_ymax = (raw_ymax / 127.0 + 1.0) / 2.0

    # Nhân ngược lại với kích thước ảnh thực tế (1280x720) để ra pixel
    scr_h, scr_w, _ = frame_raw.shape
    p1 = (int(norm_xmin * scr_w), int(norm_ymin * scr_h))
    p2 = (int(norm_xmax * scr_w), int(norm_ymax * scr_h))

    # Vẽ khung hình chữ nhật màu đỏ lên ảnh gốc
    cv2.rectangle(frame_raw, p1, p2, (0, 0, 255), 3)
    cv2.putText(frame_raw, 'Human Detected', (p1[0], p1[1]-10), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0,0,255), 2)

    # BƯỚC 8: Hiển thị ra màn hình
    cv2.imshow("Kria AI Human Localization", frame_raw)

    # Nhấn 'q' để thoát vòng lặp
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break

# Dọn dẹp tài nguyên
cap.release()
cv2.destroyAllWindows()
mem_regs.close()
mem_ram.close()
os.close(f)