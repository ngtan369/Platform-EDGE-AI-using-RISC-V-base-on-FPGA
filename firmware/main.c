#include <stdint.h>
#include "layer_desc.h"
#include "layer_table.h"

/* ============================================================================
 * 1. MEMORY MAP — khớp Vivado Address Editor (post-fix)
 * ============================================================================ */
#define ARM_COMM_BASE     0xB0040000   /* D-BRAM Port A — shared với ARM (Port B) */
#define DMA_BASE          0xB0000000   /* axi_dma_0 S_AXI_LITE */
#define CNN_BASE_ADDR     0xB0010000   /* conv_cnn_0 S00_AXI */

/* ---- Shared D-BRAM register layout (offset từ ARM_COMM_BASE) ----
 * +0x00  CMD_FROM_ARM     ARM → RISC-V   (0x01 = START, 0 = idle)
 * +0x04  STATUS_TO_ARM    RISC-V → ARM   (IDLE / BUSY / DONE)
 * +0x08  DATASET_ID       ARM → RISC-V   (0=INRIA, 1=cats_dogs)
 * +0x0C  RESULT_CLASS     RISC-V → ARM   (argmax từ CPU-side khi enable result FIFO)
 * +0x10  RESULT_CONF      RISC-V → ARM   (Q1.7)
 * +0x18  IFM_PHYS_ADDR    ARM → RISC-V   (DDR phys addr buffer A — input lúc đầu)
 * +0x1C  OFM_PHYS_ADDR    ARM → RISC-V   (DDR phys addr buffer B — scratch / final)
 * +0x20  WEIGHT_BASE      ARM → RISC-V   (DDR phys addr của weights blob)
 * Ping-pong giữa buffer A/B mỗi layer; final layer's output ARM tự đọc DDR + argmax.
 * ---------------------------------------------------------------- */
#define REG_CMD_FROM_ARM    (*(volatile uint32_t*)(ARM_COMM_BASE + 0x00))
#define REG_STATUS_TO_ARM   (*(volatile uint32_t*)(ARM_COMM_BASE + 0x04))
#define REG_DATASET_ID      (*(volatile uint32_t*)(ARM_COMM_BASE + 0x08))
#define REG_RESULT_CLASS    (*(volatile uint32_t*)(ARM_COMM_BASE + 0x0C))
#define REG_RESULT_CONF     (*(volatile uint32_t*)(ARM_COMM_BASE + 0x10))
#define REG_IFM_PHYS_ADDR   (*(volatile uint32_t*)(ARM_COMM_BASE + 0x18))
#define REG_OFM_PHYS_ADDR   (*(volatile uint32_t*)(ARM_COMM_BASE + 0x1C))
#define REG_WEIGHT_BASE     (*(volatile uint32_t*)(ARM_COMM_BASE + 0x20))
#define REG_DBG_LAYER       (*(volatile uint32_t*)(ARM_COMM_BASE + 0x24))
#define REG_DBG_PHASE       (*(volatile uint32_t*)(ARM_COMM_BASE + 0x28))

#define CMD_START         0x01
#define STATUS_IDLE       0x00
#define STATUS_BUSY       0x01
#define STATUS_DONE       0x02

/* ============================================================================
 * 2. AXI-Lite register offsets — DMA và conv_cnn
 * ============================================================================ */
/* AXI DMA (Xilinx LogiCORE) — chế độ Direct Register, không Scatter-Gather */
#define DMA_MM2S_CR     0x00   /* control: bit0 = run */
#define DMA_MM2S_SR     0x04   /* status:  bit1 = idle */
#define DMA_MM2S_SA     0x18   /* source phys addr */
#define DMA_MM2S_LEN    0x28   /* byte count — ghi vào sẽ kick transfer */
#define DMA_S2MM_CR     0x30
#define DMA_S2MM_SR     0x34
#define DMA_S2MM_DA     0x48   /* dest phys addr */
#define DMA_S2MM_LEN    0x58
#define DMA_RUN_BIT     0x00000001
#define DMA_IDLE_BIT    0x00000002
/* "not actively transferring" = Idle (bit1, post-completion) OR Halted (bit0, pre-start) */
#define DMA_INACTIVE_MASK  (DMA_IDLE_BIT | DMA_RUN_BIT)

/* conv_cnn v2.0 S00_AXI register map */
#define CNN_REG_GEOMETRY  0x00   /* width[15:0], height[31:16] */
#define CNN_REG_CTRL      0x04   /* bit0=start, bit1=pool_en, bit2=mode_load, bit3=has_relu */
#define CNN_REG_STATUS    0x08   /* bit0=done (RO) */
#define CNN_REG_CHANNELS  0x0C   /* num_cin[15:0], num_cout[31:16] */
#define CNN_REG_M_Q31     0x10   /* M_q31[30:0] */
#define CNN_REG_SHIFT_ZP  0x14   /* shift[5:0], output_zp[15:8] (signed int8) */

#define CNN_CTRL_START      0x01
#define CNN_CTRL_POOL_EN    0x02
#define CNN_CTRL_MODE_LOAD  0x04
#define CNN_CTRL_HAS_RELU   0x08

/* ============================================================================
 * 3. LOW-LEVEL HELPERS
 * ============================================================================ */
static inline void  iowrite32(uint32_t addr, uint32_t v) { *(volatile uint32_t*)addr = v; }
static inline uint32_t ioread32(uint32_t addr)           { return *(volatile uint32_t*)addr; }

static void dma_kick_mm2s(uint32_t src_phys, uint32_t bytes)
{
    iowrite32(DMA_BASE + DMA_MM2S_CR, DMA_RUN_BIT);
    iowrite32(DMA_BASE + DMA_MM2S_SA, src_phys);
    iowrite32(DMA_BASE + DMA_MM2S_LEN, bytes);   /* writing LEN starts transfer */
}

static void dma_kick_s2mm(uint32_t dst_phys, uint32_t bytes)
{
    iowrite32(DMA_BASE + DMA_S2MM_CR, DMA_RUN_BIT);
    iowrite32(DMA_BASE + DMA_S2MM_DA, dst_phys);
    iowrite32(DMA_BASE + DMA_S2MM_LEN, bytes);
}

static void dma_wait_idle(void)
{
    /* A channel after reset has Halted=1, Idle=0 (never started). Accept either
     * state as "not busy" so we don't spin forever waiting for an idle bit on a
     * channel that has not yet been kicked. */
    while ((ioread32(DMA_BASE + DMA_MM2S_SR) & DMA_INACTIVE_MASK) == 0) { }
    while ((ioread32(DMA_BASE + DMA_S2MM_SR) & DMA_INACTIVE_MASK) == 0) { }
}

/* ============================================================================
 * 4. LAYER DRIVER
 * ============================================================================ */
static uint32_t ofm_geometry_bytes(const layer_desc_t* L)
{
    uint32_t ow = (L->padding == PAD_SAME) ? L->ifm_width
                                           : (L->ifm_width  - L->kernel + 1);
    uint32_t oh = (L->padding == PAD_SAME) ? L->ifm_height
                                           : (L->ifm_height - L->kernel + 1);
    if (L->pool_en) { ow >>= 1; oh >>= 1; }
    return ow * oh * (uint32_t)L->cout;
}

static void cnn_poll_done(void)
{
    while ((ioread32(CNN_BASE_ADDR + CNN_REG_STATUS) & 0x01) == 0) { }
}

static void process_one_layer(const layer_desc_t* L,
                              uint32_t weight_base,
                              uint32_t ifm_phys,
                              uint32_t ofm_phys)
{
    /* ---- 1. Static layer config (geometry + quant) ---- */
    REG_DBG_PHASE = 1;  // entering config
    uint32_t geometry = (uint32_t)L->ifm_width | ((uint32_t)L->ifm_height << 16);
    uint32_t channels = (uint32_t)L->cin       | ((uint32_t)L->cout       << 16);
    uint32_t shift_zp = ((uint32_t)L->output_shift & 0x3F)
                      | (((uint32_t)(uint8_t)L->output_zp & 0xFF) << 8);
    iowrite32(CNN_BASE_ADDR + CNN_REG_GEOMETRY, geometry);
    iowrite32(CNN_BASE_ADDR + CNN_REG_CHANNELS, channels);
    iowrite32(CNN_BASE_ADDR + CNN_REG_M_Q31,    (uint32_t)L->output_M);
    iowrite32(CNN_BASE_ADDR + CNN_REG_SHIFT_ZP, shift_zp);

    /* ---- 2. Load mode: stream weights+biases via DMA MM2S → conv_cnn S00_AXIS ---- */
    REG_DBG_PHASE = 2;  // about to kick LOAD
    iowrite32(CNN_BASE_ADDR + CNN_REG_CTRL, CNN_CTRL_MODE_LOAD | CNN_CTRL_START);
    uint32_t w_bytes = L->weight_bytes + (L->bias_offset == 0xFFFFFFFFu ? 0 : L->bias_bytes);
    dma_kick_mm2s(weight_base + L->weight_offset, w_bytes);
    REG_DBG_PHASE = 3;  // polling LOAD done
    cnn_poll_done();
    REG_DBG_PHASE = 4;  // LOAD done, clearing CTRL
    iowrite32(CNN_BASE_ADDR + CNN_REG_CTRL, 0);
    dma_wait_idle();

    /* ---- 3. Infer mode: program S2MM first (ready to receive), then start core ---- */
    REG_DBG_PHASE = 5;  // about to kick INFER
    uint32_t ifm_bytes = (uint32_t)L->ifm_width * L->ifm_height * L->cin;
    uint32_t ofm_bytes = ofm_geometry_bytes(L);
    dma_kick_s2mm(ofm_phys, ofm_bytes);

    uint32_t ctrl = CNN_CTRL_START
                  | (L->pool_en              ? CNN_CTRL_POOL_EN  : 0)
                  | (L->activation==ACT_RELU ? CNN_CTRL_HAS_RELU : 0);
    iowrite32(CNN_BASE_ADDR + CNN_REG_CTRL, ctrl);

    /* ---- 4. Stream IFM via DMA MM2S → S00_AXIS ---- */
    dma_kick_mm2s(ifm_phys, ifm_bytes);
    REG_DBG_PHASE = 6;  // polling INFER done

    /* ---- 5. Wait for conv done + DMA flush ---- */
    cnn_poll_done();
    REG_DBG_PHASE = 7;  // INFER done, draining
    dma_wait_idle();
    iowrite32(CNN_BASE_ADDR + CNN_REG_CTRL, 0);
    REG_DBG_PHASE = 8;  // layer complete
}

/* ============================================================================
 * 5. APPLICATION LAYER
 * ============================================================================ */
static void initialize_model(void)
{
    REG_STATUS_TO_ARM = STATUS_IDLE;
    REG_RESULT_CLASS  = 0;
    REG_RESULT_CONF   = 0;
}

static void wait_for_input_data(void)
{
    while (REG_CMD_FROM_ARM != CMD_START) { }   /* spin */
    REG_STATUS_TO_ARM = STATUS_BUSY;
}

static void run_inference(void)
{
    uint32_t weight_base = REG_WEIGHT_BASE;
    uint32_t buf_a       = REG_IFM_PHYS_ADDR;   /* input ảnh */
    uint32_t buf_b       = REG_OFM_PHYS_ADDR;   /* scratch */

    /* Ping-pong: layer 0: A→B, layer 1: B→A, layer 2: A→B, ... */
    for (uint32_t i = 0; i < NUM_LAYERS; i++) {
        REG_DBG_LAYER = i;
        uint32_t in_phys  = (i & 1) ? buf_b : buf_a;
        uint32_t out_phys = (i & 1) ? buf_a : buf_b;
        process_one_layer(&LAYERS[i], weight_base, in_phys, out_phys);
    }
}

static void report_done(void)
{
    /* Output layer cuối nằm trong DDR (buf_a hoặc buf_b tuỳ NUM_LAYERS chẵn/lẻ).
     * RISC-V không route được tới DDR → ARM tự đọc + argmax (xem firmware/arm/main.py).
     * Khi RTL thêm result FIFO trong conv_cnn S00_AXI (P3 tương lai), đoạn này
     * sẽ ghi RESULT_CLASS/RESULT_CONF trực tiếp. */
    REG_RESULT_CLASS  = 0;
    REG_RESULT_CONF   = 0;
    REG_CMD_FROM_ARM  = 0x00;
    REG_STATUS_TO_ARM = STATUS_DONE;
}

/* ============================================================================
 * 6. MAIN LOOP
 * ============================================================================ */
int main(void)
{
    initialize_model();

    while (1) {
        wait_for_input_data();
        run_inference();
        report_done();
    }
    return 0;
}
