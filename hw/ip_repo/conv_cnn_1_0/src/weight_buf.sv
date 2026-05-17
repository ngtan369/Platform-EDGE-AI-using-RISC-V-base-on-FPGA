// =============================================================================
// weight_buf.sv — On-chip filter weight + bias storage cho conv_cnn v2.1.
//
// v2.1 change: Bank weights by cout[COUT_BANK_W-1:0] (low bits) to enable
// N_COUT_PE parallel reads per cycle. Same total storage, just split across
// 8 banks for parallel access.
//
// Storage:
//   • Weights: K_TAPS × N_COUT_PE = 9 × 8 = 72 RAMs ĐỘC LẬP
//              Each: (MAX_COUT/N_COUT_PE) × MAX_CIN × INT8 = 8 × 64 = 512 B
//              Total: 72 × 512 B = 36 KB (same as v2.0)
//   • Biases:  N_COUT_PE banks of (MAX_COUT/N_COUT_PE) × INT32 = 8 × 4 B each
//              (LUTRAM, distributed)
//
// Address scheme:
//   cout = {cout_high[COUT_HIGH_W-1:0], cout_low[COUT_BANK_W-1:0]}
//   For cout=N, cout_high=N>>3, cout_low=N&7.
//   Each (kk, cout_low) bank stores weight indexed by [cout_high, cin].
//
// Read port: caller provides cout_high (batch base) + cnt_cin.
// We return 9×8 = 72 weights simultaneously (one per (kk, cout_bank)).
//
// Write port: load FSM writes 1 byte/cycle.
//   To write weight at (kk, cout, cin): select bank cout[COUT_BANK_W-1:0],
//   write at addr {cout[COUT_ADDR_W-1:COUT_BANK_W], cin}.
//
// Bias same pattern: 8 banks of 8 entries (cout=64 / 8 banks).
// =============================================================================
`timescale 1ns/1ps

module weight_buf
    import conv_pkg::*;
(
    input  logic                            clk,
    input  logic                            rst_n,

    // ---- Weight write port (load FSM, 1 byte/cycle) ----
    input  logic                            we_w,
    input  logic [3:0]                      w_kk,
    input  logic [COUT_ADDR_W-1:0]          w_cout,
    input  logic [CIN_ADDR_W-1:0]           w_cin,
    input  logic signed [WEIGHT_W-1:0]      w_data,

    // ---- Bias write port ----
    input  logic                            we_b,
    input  logic [COUT_ADDR_W-1:0]          b_cout,
    input  logic signed [BIAS_W-1:0]        b_data,

    // ---- Read port (parallel 9×N_COUT_PE, 1-cycle latency) ----
    //   r_cout_high: which cout batch (0..MAX_COUT/N_COUT_PE -1)
    //   r_cin:       which input channel slice (0..num_cin-1)
    //   Output: r_weights[bank][kk] = weight at (kk, cout=r_cout_high*N+bank, cin=r_cin)
    //           r_bias[bank] = bias for cout=r_cout_high*N+bank
    input  logic [COUT_HIGH_W-1:0]          r_cout_high,
    input  logic [CIN_ADDR_W-1:0]           r_cin,
    output logic signed [WEIGHT_W-1:0]      r_weights [0:N_COUT_PE-1][0:K_TAPS-1],
    output logic signed [BIAS_W-1:0]        r_bias    [0:N_COUT_PE-1]
);

    // -------------------------------------------------------------------------
    // Bias storage: N_COUT_PE banks, distributed RAM
    //   Each bank stores MAX_COUT/N_COUT_PE = 8 biases (INT32)
    // -------------------------------------------------------------------------
    genvar gb;
    generate
        for (gb = 0; gb < N_COUT_PE; gb++) begin : g_b_bank
            (* ram_style = "distributed" *)
            logic signed [BIAS_W-1:0] b_mem [0:(1<<COUT_HIGH_W)-1];

            initial begin
                for (int co = 0; co < (1<<COUT_HIGH_W); co++) b_mem[co] = '0;
            end

            // Write: only when w_cout's low bits match this bank
            always @(posedge clk) begin
                if (we_b && (b_cout[COUT_BANK_W-1:0] == gb[COUT_BANK_W-1:0]))
                    b_mem[b_cout[COUT_ADDR_W-1:COUT_BANK_W]] <= b_data;
            end

            // Read: 1-cycle latency
            always @(posedge clk) begin
                if (!rst_n) r_bias[gb] <= '0;
                else        r_bias[gb] <= b_mem[r_cout_high];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Weight storage: K_TAPS × N_COUT_PE = 72 banks
    //   Each bank: depth = (MAX_COUT/N_COUT_PE) × MAX_CIN = 8 × 64 = 512 entries
    //   Width: 8-bit. Total per bank: 4 Kb = 1 RAMB18 (underutilized but isolated)
    //   Total: 72 RAMB18 (Vivado may pack to ~36 RAMB36) or LUT-RAM
    // -------------------------------------------------------------------------
    localparam int BANK_DEPTH = (1 << COUT_HIGH_W) * MAX_CIN;   // 8 × 64 = 512
    localparam int BANK_ADDR_W = COUT_HIGH_W + CIN_ADDR_W;       // 3 + 6 = 9

    genvar gk, gbk;
    generate
        for (gk = 0; gk < K_TAPS; gk++) begin : g_w_kk
            for (gbk = 0; gbk < N_COUT_PE; gbk++) begin : g_w_bank
                (* ram_style = "block" *)
                logic signed [WEIGHT_W-1:0] mem [0:BANK_DEPTH-1];

                wire [BANK_ADDR_W-1:0] wr_addr =
                    {w_cout[COUT_ADDR_W-1:COUT_BANK_W], w_cin};
                wire [BANK_ADDR_W-1:0] rd_addr = {r_cout_high, r_cin};

                initial begin
                    for (int i = 0; i < BANK_DEPTH; i++) mem[i] = '0;
                end

                // Write: only when (w_kk matches gk) AND (w_cout low bits match gbk)
                always @(posedge clk) begin
                    if (we_w
                        && (w_kk == gk[3:0])
                        && (w_cout[COUT_BANK_W-1:0] == gbk[COUT_BANK_W-1:0]))
                    begin
                        mem[wr_addr] <= w_data;
                    end
                end

                // Read: 1-cycle BRAM latency (matches v2.0 timing)
                always @(posedge clk) begin
                    r_weights[gbk][gk] <= mem[rd_addr];
                end
            end
        end
    endgenerate

endmodule
