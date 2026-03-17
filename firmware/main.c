#include <stdint.h>
#include "../training/model_data.h" // Chứa mảng trọng số weights_int8[]

// ==============================================================================
// 1. BẢN ĐỒ BỘ NHỚ (MEMORY MAP)
// Các địa chỉ này phải khớp 100% với cấu hình AXI trong Vivado Block Design
// ==============================================================================
#define CAMERA_RAM_BASE   0x80000000 // Nơi lõi ARM đổ dữ liệu ảnh (128x128) vào
#define ARM_COMM_BASE     0x40000000 // Địa chỉ Base của thanh ghi giao tiếp AXI

// Các thanh ghi điều khiển (Cộng dồn offset)
#define REG_CMD_FROM_ARM  (*(volatile uint32_t*)(ARM_COMM_BASE + 0x00))
#define REG_STATUS_TO_ARM (*(volatile uint32_t*)(ARM_COMM_BASE + 0x04))
#define REG_AI_RESULT     (*(volatile int32_t*)(ARM_COMM_BASE + 0x08))

// Các cờ trạng thái (Flags)
#define CMD_START         0x01
#define STATUS_IDLE       0x00
#define STATUS_BUSY       0x01
#define STATUS_DONE       0x02

// ==============================================================================
// 2. TRIỂN KHAI CÁC HÀM CỐT LÕI
// ==============================================================================

void initialize_model() {
    // Với model tĩnh lưu trong ROM (model_data.h), thường không cần init nhiều.
    // Chủ yếu dùng để reset các thanh ghi phần cứng về trạng thái ban đầu.
    REG_STATUS_TO_ARM = STATUS_IDLE;
    REG_AI_RESULT = 0;
}

void wait_for_input_data() {
    // Cơ chế Polling (Hỏi vòng): RISC-V liên tục hỏi "ARM ơi có ảnh chưa?"
    // Nó sẽ kẹt ở vòng lặp này cho đến khi ARM ghi số 1 (CMD_START) vào thanh ghi.
    while (REG_CMD_FROM_ARM != CMD_START) {
        // Có thể chèn lệnh NOP hoặc WFI (Wait for Interrupt) ở đây để tiết kiệm điện
    }
    
    // Báo lại cho ARM biết: "Đã nhận lệnh, đang tính toán, đừng gửi ảnh mới!"
    REG_STATUS_TO_ARM = STATUS_BUSY;
}

int32_t run_inference(int8_t* image_pointer) {
    int32_t prediction_score = 0;
    
    // --- NƠI PHÉP MÀU XẢY RA ---
    // Chỗ này bạn sẽ viết các vòng lặp for lồng nhau để nhân ma trận (MAC).
    // Dữ liệu ảnh lấy từ *image_pointer, trọng số lấy từ weights_int8[]
    // Ví dụ giả lập:
    // prediction_score = convolution_layer_1(image_pointer, weights_int8);
    // ...
    
    // Giả lập trả về một con số ngẫu nhiên (sẽ thay bằng code AI thật sau)
    prediction_score = 85; // 85% khả năng là người
    
    return prediction_score;
}

void process_output(int32_t result) {
    // 1. Ghi kết quả nhận diện ra thanh ghi để ARM đọc
    REG_AI_RESULT = result;
    
    // 2. Xóa lệnh Start cũ đi
    REG_CMD_FROM_ARM = 0x00;
    
    // 3. Phất cờ báo hiệu đã tính xong
    REG_STATUS_TO_ARM = STATUS_DONE;
}

// ==============================================================================
// 3. VÒNG LẶP CHÍNH (MAIN LOOP)
// ==============================================================================
int main() {
    initialize_model();
    
    // Lấy con trỏ trỏ thẳng vào vùng RAM chứa ảnh
    int8_t* camera_buffer = (int8_t*)CAMERA_RAM_BASE;

    while (1) {
        // 1. Đợi ARM ra lệnh
        wait_for_input_data();

        // 2. Chạy mạng Neural Network với mảng byte trong RAM
        int32_t output_score = run_inference(camera_buffer);

        // 3. Báo cáo kết quả
        process_output(output_score);
    }

    return 0; // Thực tế bare-metal không bao giờ chạm tới dòng này
}