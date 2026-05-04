// =============================================================================
// weight_buf.sv — On-chip filter weight + bias storage cho conv_cnn v2.0.
//
// Storage:
//   • Weights : K_TAPS × MAX_COUT × MAX_CIN × INT8 = 9 × 64 × 64 × 8b = 36 KB
//               Map sang 9 BRAMs (1 per kk slot) → 9 RAMB18 ≈ 5 RAMB36
//               Mỗi BRAM size MAX_COUT × MAX_CIN × 8 = 32 Kb
//   • Biases  : MAX_COUT × INT32 = 64 × 4B = 256 B (LUTRAM)
//
// Interface:
//   • Write port: caller (conv_core load FSM) drive {addr, data, we} mỗi cycle
//                 trong load phase. 1 weight/cycle hoặc 1 bias/cycle.
//   • Read port:  caller drive {r_cout, r_cin}; data out với 1-cycle latency.
//                 9 weights cho cùng (cout, cin) emerge song song.
//
// Layout: w_mem[kk][cout][cin] với kk = ky*KERNEL + kx. Khớp OHWI weight order
// từ TFLite: weights[cout][kh][kw][cin] → flatten kh*kw vào kk axis.
// =============================================================================
`timescale 1ns/1ps

module weight_buf
    import conv_pkg::*;
(
    input  logic                            clk,
    input  logic                            rst_n,

    // ---- Weight write port ----
    input  logic                            we_w,
    input  logic [3:0]                      w_kk,         // 0..K_TAPS-1
    input  logic [COUT_ADDR_W-1:0]          w_cout,
    input  logic [CIN_ADDR_W-1:0]           w_cin,
    input  logic signed [WEIGHT_W-1:0]      w_data,

    // ---- Bias write port ----
    input  logic                            we_b,
    input  logic [COUT_ADDR_W-1:0]          b_cout,
    input  logic signed [BIAS_W-1:0]        b_data,

    // ---- Read port (1-cycle latency for r_weights / r_bias) ----
    input  logic [COUT_ADDR_W-1:0]          r_cout,
    input  logic [CIN_ADDR_W-1:0]           r_cin,
    output logic signed [WEIGHT_W-1:0]      r_weights [0:K_TAPS-1],
    output logic signed [BIAS_W-1:0]        r_bias
);

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------
    (* ram_style = "block" *)
    logic signed [WEIGHT_W-1:0] w_mem [0:K_TAPS-1][0:MAX_COUT-1][0:MAX_CIN-1];

    (* ram_style = "distributed" *)
    logic signed [BIAS_W-1:0]   b_mem [0:MAX_COUT-1];

    // -------------------------------------------------------------------------
    // Write — synchronous, one weight/bias per cycle
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (we_w) w_mem[w_kk][w_cout][w_cin] <= w_data;
        if (we_b) b_mem[b_cout]              <= b_data;
    end

    // -------------------------------------------------------------------------
    // Read — registered output (BRAM inference)
    //   9 BRAMs đọc song song cho cùng (r_cout, r_cin) → 9 weights/cycle.
    //   Caller phải apply r_cout/r_cin 1 cycle trước khi cần data
    //   (e.g., FSM driver giữ cnt_cin steady, register output ở downstream).
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        for (int k = 0; k < K_TAPS; k++)
            r_weights[k] <= w_mem[k][r_cout][r_cin];
        r_bias <= b_mem[r_cout];
    end

endmodule
