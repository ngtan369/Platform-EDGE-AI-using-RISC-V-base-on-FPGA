#ifndef LAYER_TABLE_H
#define LAYER_TABLE_H

/* ============================================================================
 * STUB layer_table.h — manual placeholder để firmware compile được.
 *
 * Bước 3 (training/train.py emitter) sẽ overwrite file này bằng output thật từ
 * TFLite graph parse. Layer ở đây là 1 conv 3×3 dummy chỉ để link không thiếu
 * symbol — KHÔNG phản ánh model thật.
 * ============================================================================ */

#include "layer_desc.h"

const uint32_t NUM_LAYERS = 1;

const layer_desc_t LAYERS[1] = {
    {
        .weight_offset = 0,
        .weight_bytes  = 9 * 3,        /* 3×3 × cin=3 × cout=1 */
        .bias_offset   = 0xFFFFFFFF,   /* sentinel: no bias */
        .bias_bytes    = 0,

        .ifm_width     = 128,
        .ifm_height    = 128,
        .cin           = 3,
        .cout          = 1,

        .kernel        = 3,
        .stride        = 1,
        .padding       = PAD_VALID,
        .pool_en       = 0,
        .activation    = ACT_RELU,
        ._reserved     = {0, 0, 0},

        .output_M      = 0x40000000,   /* M ≈ 0.5 (Q31) — dummy */
        .output_shift  = 0,
        .input_zp      = 0,
        .output_zp     = 0,
        .weight_zp     = 0,
    }
};

#endif /* LAYER_TABLE_H */
