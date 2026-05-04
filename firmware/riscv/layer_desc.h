#ifndef LAYER_DESC_H
#define LAYER_DESC_H

#include <stdint.h>

/* ============================================================================
 * layer_desc_t — contract giữa training compiler (Python) và RISC-V firmware.
 *
 * Pipeline:
 *   1. training/main.py parse TFLite graph → emit:
 *        - layer_table.h  : `const layer_desc_t LAYERS[]`
 *        - weights.bin    : INT8 weights + biases packed
 *   2. ARM load weights.bin vào DDR (pynq.allocate) → ghi DDR base phys addr
 *      vào shared D-BRAM (REG_WEIGHT_BASE).
 *   3. RISC-V duyệt LAYERS[]; cho mỗi layer:
 *        weight_phys = REG_WEIGHT_BASE + LAYERS[i].weight_offset
 *        program DMA, kick conv_cnn, poll done.
 *
 * Lưu ý: LAYERS[] và NUM_LAYERS được link vào RISC-V firmware (read-only,
 * vào .rodata trên I-BRAM) — đổi model = re-compile firmware. Weights thì
 * load runtime nên không cần re-compile.
 * ============================================================================ */

typedef enum : uint8_t {
    ACT_NONE  = 0,
    ACT_RELU  = 1,
    ACT_RELU6 = 2,
    /* future: leaky-relu, hard-swish, sigmoid */
} activation_t;

typedef enum : uint8_t {
    PAD_VALID = 0,   /* output = (W − k + 1) */
    PAD_SAME  = 1,   /* zero-pad để giữ W */
} padding_t;

typedef struct __attribute__((packed)) {
    /* ---- DDR offsets (ARM cộng DDR base → physical addr) ---- */
    uint32_t weight_offset;    /* byte offset trong weights.bin */
    uint32_t weight_bytes;     /* tổng size INT8 weights của layer này */
    uint32_t bias_offset;      /* offset bias INT32; UINT32_MAX nếu no bias */
    uint32_t bias_bytes;

    /* ---- Input geometry ---- */
    uint16_t ifm_width;
    uint16_t ifm_height;
    uint16_t cin;
    uint16_t cout;

    /* ---- Operation config ---- */
    uint8_t  kernel;           /* 1 = pointwise, 3 = 3×3 standard */
    uint8_t  stride;           /* 1 (current) hoặc 2 (future) */
    padding_t padding;
    uint8_t  pool_en;          /* 1 = followed by 2×2 maxpool */
    activation_t activation;
    uint8_t  _reserved[3];     /* pad → 4-byte align */

    /* ---- Per-tensor INT8 requantize (TFLite convention) ----
     * y_q = saturate(((sum_int32 + bias) * output_M) >> output_shift) + output_zp
     * output_M: Q31 multiplier (positive); output_shift: right-shift count.
     * input_zp / weight_zp / output_zp: zero_point từng tensor. */
    int32_t  output_M;
    int8_t   output_shift;
    int8_t   input_zp;
    int8_t   output_zp;
    int8_t   weight_zp;
} layer_desc_t;

/* Defined in auto-generated layer_table.h */
extern const uint32_t     NUM_LAYERS;
extern const layer_desc_t LAYERS[];

#endif /* LAYER_DESC_H */
