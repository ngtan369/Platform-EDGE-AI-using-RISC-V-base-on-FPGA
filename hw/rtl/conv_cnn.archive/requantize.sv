// =============================================================================
// requantize.sv — TFLite INT8 post-conv requantize block.
//
// Operation (mỗi sample):
//   sum33   = acc(int32) + bias(int32)                 // 33-bit signed
//   prod65  = sum33 * M_q31                            // 65-bit signed
//   total_shift = 31 + cfg_shift                       // 31..62
//   round   = prod65 + (1 << (total_shift - 1))        // round-to-nearest
//   shifted = round >>> total_shift                    // arithmetic shift
//   y_signed = shifted + output_zp                     // int8 zero-point
//   y       = saturate(y_signed, [-128, 127])
//   if has_relu: y = max(y, output_zp)                 // ReLU clamps real ≥ 0
//
// Pipeline 3 stages: bias-add → multiply → shift/sat/zp/relu (all registered).
// Throughput: 1 sample/cycle. Latency: REQUANT_LATENCY = 3.
// =============================================================================
`timescale 1ns/1ps

module requantize
    import conv_pkg::*;
(
    input  logic                            clk,
    input  logic                            rst_n,

    // ---- Configuration (latch ở start của layer, hold suốt layer) ----
    input  logic        [M_Q31_W-1:0]       cfg_M_q31,       // unsigned, > 0
    input  logic        [SHIFT_W-1:0]       cfg_shift,       // 0..31
    input  logic signed [DATA_W-1:0]        cfg_output_zp,
    input  logic                            cfg_has_relu,

    // ---- Input (1 sample/cycle, no back-pressure) ----
    input  logic                            in_valid,
    input  logic signed [ACC_W-1:0]         in_acc,
    input  logic signed [BIAS_W-1:0]        in_bias,

    // ---- Output (REQUANT_LATENCY = 3 cycles latency) ----
    output logic                            out_valid,
    output logic signed [DATA_W-1:0]        out_y
);

    // -------------------------------------------------------------------------
    // Stage 1 — bias add (33-bit signed, no overflow)
    // -------------------------------------------------------------------------
    logic signed [BIAS_W:0]              s1_sum;
    logic                                s1_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_sum   <= '0;
        end else begin
            s1_sum   <= $signed(in_acc) + $signed(in_bias);
            s1_valid <= in_valid;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2 — multiply by M_q31 (signed 33b × unsigned 31b → 64b signed)
    //   Synth infers DSP48E2 cascade for này.
    // -------------------------------------------------------------------------
    localparam int PROD_W = (BIAS_W + 1) + M_Q31_W;     // 33 + 31 = 64 bits
    logic signed [PROD_W-1:0]            s2_prod;
    logic                                s2_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
            s2_prod  <= '0;
        end else begin
            s2_prod  <= s1_sum * $signed({1'b0, cfg_M_q31});
            s2_valid <= s1_valid;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 3 — round, arshift (31 + cfg_shift), add zp, saturate, ReLU
    //   total_shift ∈ [31, 62] → infers 64-bit barrel shifter
    // -------------------------------------------------------------------------
    logic        [SHIFT_W:0]             total_shift;       // 7-bit, 0..62
    logic signed [PROD_W-1:0]            round_adder;
    logic signed [PROD_W-1:0]            rounded_prod;
    logic signed [ACC_W:0]               shifted_int33;
    logic signed [ACC_W:0]               with_zp;
    logic signed [DATA_W-1:0]            sat_y;
    logic signed [DATA_W-1:0]            relu_y;

    always_comb begin
        total_shift   = 7'd31 + {1'b0, cfg_shift};
        round_adder   = (PROD_W'(64'sd1)) <<< (total_shift - 7'd1);
        rounded_prod  = s2_prod + round_adder;
        shifted_int33 = rounded_prod >>> total_shift;

        // sign-extend 8-bit zp to 33-bit, then add
        with_zp = shifted_int33
                + {{(ACC_W+1-DATA_W){cfg_output_zp[DATA_W-1]}}, cfg_output_zp};

        // Saturate to int8
        if      (with_zp >  $signed(33'sd127))  sat_y =  8'sd127;
        else if (with_zp < -$signed(33'sd128))  sat_y = -8'sd128;
        else                                    sat_y =  with_zp[DATA_W-1:0];

        // ReLU: real ≥ 0 ⇔ q ≥ output_zp
        relu_y = (cfg_has_relu && (sat_y < cfg_output_zp)) ? cfg_output_zp : sat_y;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_y     <= '0;
        end else begin
            out_valid <= s2_valid;
            out_y     <= relu_y;
        end
    end

endmodule
