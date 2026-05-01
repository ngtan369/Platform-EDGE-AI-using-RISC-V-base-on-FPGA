#include "xil_io.h"

// Địa chỉ lấy y chang trong bảng Address Editor của bạn
#define CNN_BASE_ADDR 0xB0010000 

int main() {
    // Ép ARM gửi lệnh Start thẳng vào CNN
    Xil_Out32(CNN_BASE_ADDR + 0x00, 1); 

    // Đọc kết quả tính toán từ CNN về
    u32 result = Xil_In32(CNN_BASE_ADDR + 0x04); 
    
    return 0;
}