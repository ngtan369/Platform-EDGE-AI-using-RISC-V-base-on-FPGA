#include <stdint.h>
#include "../training/model_data.h"

// ==============================================================================
// 1. BẢN ĐỒ BỘ NHỚ (MEMORY MAP) - khớp Vivado Address Editor (post-fix)
// ==============================================================================
// D-BRAM Port A (256 KB) — shared với ARM qua Port B ở cùng offset 0xB004_0000.
// ARM ghi vào Port B: dataset id, physical addr của IFM/W/OFM buffers trong DDR,
// kết quả classification. RISC-V đọc/ghi qua Port A.
#define ARM_COMM_BASE     0xB0040000

// AXI peripherals (cùng offset trong PS view và RISC-V view)
#define DMA_BASE          0xB0000000   // axi_dma_0/S_AXI_LITE — DMA descriptors
#define CNN_BASE_ADDR     0xB0010000   // conv_cnn_0/S00_AXI

// Mailbox tuỳ chọn — đặt cuối D-BRAM shared
#define MAILBOX_ADDR      (ARM_COMM_BASE + 0x3FFFC)   // 0xB007_FFFC

// Pipeline (xem CLAUDE.md "Data Flow"):
//   ARM đọc ảnh từ SD card → resize 128×128 → quantize INT8 (theo input_scale,
//   input_zero_point từ TFLite metadata) → ghi vào DDR ifm_buf (pynq.allocate).
//   ARM ghi ifm_phys + dataset_id vào D-BRAM, set CMD_START.
//   RISC-V program DMA (DMA_BASE) → conv_cnn (CNN_BASE_ADDR) loop từng layer →
//   argmax → ghi REG_RESULT_CLASS + REG_RESULT_CONFIDENCE → STATUS_DONE.

// ----- Shared D-BRAM register layout (offsets từ ARM_COMM_BASE) -----
//  +0x00  CMD_FROM_ARM   uint32   (CMD_START / 0)
//  +0x04  STATUS_TO_ARM  uint32   (IDLE / BUSY / DONE)
//  +0x08  DATASET_ID     uint32   (0=INRIA person, 1=cats_dogs)
//  +0x0C  RESULT_CLASS   uint32   (0 hoặc 1)
//  +0x10  RESULT_CONF    uint32   (Q1.7 confidence sau softmax/argmax, 0..127)
//  +0x18  IFM_PHYS_ADDR  uint32   (DDR physical addr cho DMA)
//  +0x1C  OFM_PHYS_ADDR  uint32   (tuỳ chọn — buffer DDR cho output cuối)
// ---------------------------------------------------------------------

#define REG_CMD_FROM_ARM    (*(volatile uint32_t*)(ARM_COMM_BASE + 0x00))
#define REG_STATUS_TO_ARM   (*(volatile uint32_t*)(ARM_COMM_BASE + 0x04))
#define REG_DATASET_ID      (*(volatile uint32_t*)(ARM_COMM_BASE + 0x08))
#define REG_RESULT_CLASS    (*(volatile uint32_t*)(ARM_COMM_BASE + 0x0C))
#define REG_RESULT_CONF     (*(volatile uint32_t*)(ARM_COMM_BASE + 0x10))
#define REG_IFM_PHYS_ADDR   (*(volatile uint32_t*)(ARM_COMM_BASE + 0x18))
#define REG_OFM_PHYS_ADDR   (*(volatile uint32_t*)(ARM_COMM_BASE + 0x1C))

// Cờ trạng thái
#define CMD_START         0x01
#define STATUS_IDLE       0x00
#define STATUS_BUSY       0x01
#define STATUS_DONE       0x02

// Dataset / class label mapping (ARM dùng cùng enum)
#define DATASET_INRIA     0   // class 0 = no_person, 1 = person
#define DATASET_CATS_DOGS 1   // class 0 = cat,        1 = dog

// ==============================================================================
// 2. TRIỂN KHAI CÁC HÀM CỐT LÕI
// ==============================================================================

void run_cnn_layer(int width, int cin, int use_pool) {
    *(volatile uint32_t*)(CNN_BASE_ADDR + 0) = width;
    *(volatile uint32_t*)(CNN_BASE_ADDR + 12) = cin;

    uint32_t control = 0x01 | (use_pool << 1);
    *(volatile uint32_t*)(CNN_BASE_ADDR + 4) = control;

    while ((*(volatile uint32_t*)(CNN_BASE_ADDR + 8) & 0x01) == 0);
}

void initialize_model() {
    REG_STATUS_TO_ARM = STATUS_IDLE;
    REG_RESULT_CLASS  = 0;
    REG_RESULT_CONF   = 0;
}

void wait_for_input_data() {
    while (REG_CMD_FROM_ARM != CMD_START) {
        // Spin: chờ ARM ghi xong IFM vào DDR và set CMD_START
    }
    REG_STATUS_TO_ARM = STATUS_BUSY;
}

// Chạy toàn bộ inference. ifm_phys = DDR address để DMA stream.
// Trả về: class_id [0..1], confidence [0..127] (Q1.7).
void run_inference(uint32_t ifm_phys, uint32_t* out_class, uint32_t* out_conf) {
    // --- TODO: layer-by-layer driver ---
    //   for each layer in model_data:
    //     program DMA MM2S: src=ifm_phys (or intermediate OFM), len=...
    //     program DMA S2MM: dst=ofm_phys, len=...
    //     run_cnn_layer(width, cin, use_pool)
    //     swap ifm_phys ↔ ofm_phys
    //   final layer: argmax 2 logits → class_id, confidence
    (void)ifm_phys;

    // Giả lập kết quả tạm
    *out_class = 1;     // ví dụ: phát hiện "person" / "dog"
    *out_conf  = 96;    // ~0.75 ở thang Q1.7
}

void report_classification(uint32_t class_id, uint32_t confidence) {
    REG_RESULT_CLASS  = class_id;
    REG_RESULT_CONF   = confidence;

    REG_CMD_FROM_ARM  = 0x00;
    REG_STATUS_TO_ARM = STATUS_DONE;
}

// ==============================================================================
// 3. VÒNG LẶP CHÍNH (MAIN LOOP)
// ==============================================================================
int main() {
    initialize_model();

    while (1) {
        wait_for_input_data();

        uint32_t ifm_phys = REG_IFM_PHYS_ADDR;
        uint32_t class_id = 0, confidence = 0;

        run_inference(ifm_phys, &class_id, &confidence);
        report_classification(class_id, confidence);
    }
    return 0;
}
