#include <stdint.h>
#include "../training/model_data.h"

// ==============================================================================
// 1. BẢN ĐỒ BỘ NHỚ (MEMORY MAP) - ĐÃ NÂNG CẤP CHO BÀI TOÁN TỌA ĐỘ
// ==============================================================================
#define CAMERA_RAM_BASE   0x80000000 
#define ARM_COMM_BASE     0x40000000 

// Các thanh ghi điều khiển hệ thống
#define REG_CMD_FROM_ARM  (*(volatile uint32_t*)(ARM_COMM_BASE + 0x00))
#define REG_STATUS_TO_ARM (*(volatile uint32_t*)(ARM_COMM_BASE + 0x04))

// 4 THANH GHI MỚI CHỨA TỌA ĐỘ BẬC (BOUNDING BOX)
// Lõi ARM sẽ đọc 4 thanh ghi này để vẽ khung bằng thư viện OpenCV
#define REG_BBOX_XMIN     (*(volatile int32_t*)(ARM_COMM_BASE + 0x08))
#define REG_BBOX_YMIN     (*(volatile int32_t*)(ARM_COMM_BASE + 0x0C))
#define REG_BBOX_XMAX     (*(volatile int32_t*)(ARM_COMM_BASE + 0x10))
#define REG_BBOX_YMAX     (*(volatile int32_t*)(ARM_COMM_BASE + 0x14))

// Các cờ trạng thái (Flags)
#define CMD_START         0x01
#define STATUS_IDLE       0x00
#define STATUS_BUSY       0x01
#define STATUS_DONE       0x02

// ==============================================================================
// 2. TRIỂN KHAI CÁC HÀM CỐT LÕI
// ==============================================================================

void initialize_model() {
    REG_STATUS_TO_ARM = STATUS_IDLE;
    REG_BBOX_XMIN = 0;
    REG_BBOX_YMIN = 0;
    REG_BBOX_XMAX = 0;
    REG_BBOX_YMAX = 0;
}

void wait_for_input_data() {
    while (REG_CMD_FROM_ARM != CMD_START) {
        // Chờ ARM ném ảnh vào RAM và ra lệnh Start
    }
    REG_STATUS_TO_ARM = STATUS_BUSY;
}

void run_inference(int8_t* image_pointer, int8_t* output_box) {
    // --- NƠI RISC-V CÀY MA TRẬN ---
    // Thuật toán mạng Neural Network tính toán ở đây
    // ...
    
    // Giả lập AI đã tính xong và nhả ra 4 tọa độ INT8.
    // (Vì sigmoid xuất ra dải 0 -> 1, khi lượng tử hóa sang INT8 nó sẽ nằm ở dải -128 đến 127)
    // Ví dụ giả lập cái khung nằm ở giữa ảnh:
    output_box[0] = -64;  // xmin (~0.25)
    output_box[1] = -64;  // ymin (~0.25)
    output_box[2] = 64;   // xmax (~0.75)
    output_box[3] = 64;   // ymax (~0.75)
}

void process_output(int8_t* predicted_box) {
    // 1. Đẩy 4 tọa độ INT8 ra 4 thanh ghi AXI (ép kiểu lên 32-bit cho ARM dễ đọc)
    REG_BBOX_XMIN = (int32_t)predicted_box[0];
    REG_BBOX_YMIN = (int32_t)predicted_box[1];
    REG_BBOX_XMAX = (int32_t)predicted_box[2];
    REG_BBOX_YMAX = (int32_t)predicted_box[3];
    
    // 2. Xóa lệnh Start và phất cờ Done
    REG_CMD_FROM_ARM = 0x00;
    REG_STATUS_TO_ARM = STATUS_DONE;
}

// ==============================================================================
// 3. VÒNG LẶP CHÍNH (MAIN LOOP)
// ==============================================================================
int main() {
    initialize_model();
    int8_t* camera_buffer = (int8_t*)CAMERA_RAM_BASE;
    int8_t bounding_box[4]; // Mảng chứa 4 kết quả từ AI

    while (1) {
        wait_for_input_data();
        
        // Gọi AI bắt tọa độ
        run_inference(camera_buffer, bounding_box);
        
        // Gửi tọa độ lên cho "sếp" ARM vẽ khung
        process_output(bounding_box);
    }

    return 0;
}