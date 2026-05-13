// =============================================================================
// conv_pkg.sv — Parameter package cho conv_cnn v2.0
// Compile-time bounds + datatype widths chia sẻ giữa các module trong IP.
// Sửa ở đây (vd. tăng MAX_CIN) → re-package IP, không cần đổi từng module.
// =============================================================================
`ifndef CONV_PKG_SV
`define CONV_PKG_SV

package conv_pkg;

    // ---------------- Compile-time bounds ----------------
    parameter int MAX_WIDTH    = 256;   // largest IFM width hỗ trợ (line buffer size)
    parameter int MAX_CIN      = 64;    // largest input channels
    parameter int MAX_COUT     = 64;    // largest output filters
    parameter int KERNEL       = 3;     // chỉ 3×3 trong v2.0
    parameter int K_TAPS       = KERNEL * KERNEL;   // = 9 PE_MACs

    // ---------------- Datatype widths --------------------
    parameter int DATA_W       = 8;     // INT8 IFM/OFM
    parameter int WEIGHT_W     = 8;     // INT8 weights
    parameter int BIAS_W       = 32;    // INT32 biases (TFLite convention)
    parameter int ACC_W        = 32;    // 32-bit MAC accumulator
    parameter int M_Q31_W      = 31;    // requantize multiplier (Q31 unsigned)
    parameter int SHIFT_W      = 6;     // additional right-shift count (0..31 thực tế)

    // ---------------- Address widths (derived) -----------
    parameter int CIN_ADDR_W   = $clog2(MAX_CIN);
    parameter int COUT_ADDR_W  = $clog2(MAX_COUT);
    parameter int WIDTH_ADDR_W = $clog2(MAX_WIDTH);

    // ---------------- Pipeline latencies -----------------
    parameter int REQUANT_LATENCY    = 3;   // requantize internal pipe (bias→mul→shift)
    parameter int PE_MAC_LATENCY     = 2;   // pe_mac internal (mult reg + acc reg)
    parameter int WEIGHT_BUF_LATENCY = 1;   // weight_buf BRAM read

    // FSM dwell time trong S_WAIT_REQUANT (sau khi pulse requant_in_valid):
    //   FSM pulse cycle T → req_valid_pipe (3 stage) → requantize.in_valid @ T+3
    //   → requantize.out_valid @ T+3+REQUANT_LATENCY = T+6
    //   FSM cần ≥ 6 cycles trước khi emit để latch out_y (cycle T+7 emit OK).
    parameter int FSM_DRAIN_CYCLES   = 6;

endpackage : conv_pkg

`endif // CONV_PKG_SV
