// =============================================================================
// tb_conv_core.sv — Integrated testbench cho conv_cnn v2.0 alpha.
//
// Test case (đơn giản, 1 layer):
//   IFM:    4×4×1, INT8 values 0..15 (raster order)
//   Weights: 3×3×1×1, all = 1
//   Bias:   0
//   M_q31:  0x40000000 (M = 0.5)
//   shift:  0
//   output_zp: 0
//   has_relu: 0
//
// Expected OFM (valid padding 3×3 stride 1 → 2×2):
//   sum positions: (0,0)=45, (0,1)=54, (1,0)=81, (1,1)=90
//   y = round(sum * 0.5) (round-half-up):
//     45 * 0.5 = 22.5 → 23
//     54 * 0.5 = 27   → 27
//     81 * 0.5 = 40.5 → 41
//     90 * 0.5 = 45   → 45
//
// Run với Vivado xsim hoặc iverilog (`-g2012`).
// =============================================================================
`timescale 1ns/1ps

module tb_conv_core;
    import conv_pkg::*;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic                       clk;
    logic                       rst_n;

    logic                       cfg_start;
    logic                       cfg_mode_load;
    logic [WIDTH_ADDR_W-1:0]    cfg_width;
    logic [WIDTH_ADDR_W-1:0]    cfg_height;
    logic [CIN_ADDR_W-1:0]      cfg_num_cin;
    logic [COUT_ADDR_W-1:0]     cfg_num_cout;
    logic                       cfg_pool_en;
    logic [M_Q31_W-1:0]         cfg_M_q31;
    logic [SHIFT_W-1:0]         cfg_shift;
    logic signed [DATA_W-1:0]   cfg_output_zp;
    logic                       cfg_has_relu;

    logic [DATA_W-1:0]          s_data;
    logic                       s_valid;
    logic                       s_ready;

    logic [DATA_W-1:0]          m_data;
    logic                       m_valid;
    logic                       m_ready;

    logic                       done;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    conv_core dut (.*);

    // -------------------------------------------------------------------------
    // 100 MHz clock
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Test stimulus
    // -------------------------------------------------------------------------
    // Stream 1 byte qua AXIS — polling pattern (iverilog compatible).
    // Wait for s_ready=1 (combinational), then commit at next clock edge.
    task automatic axis_send_byte(input logic [7:0] data);
        s_data  = data;
        s_valid = 1'b1;
        while (!s_ready) @(posedge clk);     // poll
        @(posedge clk);                       // commit handshake
        s_valid = 1'b0;
        s_data  = '0;
    endtask

    // Capture 1 byte từ M00_AXIS.
    task automatic axis_recv_byte(output logic [7:0] data);
        m_ready = 1'b1;
        while (!m_valid) @(posedge clk);
        data = m_data;
        @(posedge clk);     // commit
        m_ready = 1'b0;
    endtask

    // Expected OFM (4 outputs) — populated trong initial block
    logic signed [7:0] expected [0:3];

    int n_errors;

    initial begin
        // Expected golden values (45, 54, 81, 90 inputs sums × 0.5 with round-half-up)
        expected[0] = 8'sd23;    // 45 * 0.5 = 22.5 → 23
        expected[1] = 8'sd27;    // 54 * 0.5 = 27
        expected[2] = 8'sd41;    // 81 * 0.5 = 40.5 → 41
        expected[3] = 8'sd45;    // 90 * 0.5 = 45

        // Init
        rst_n         = 1'b0;
        cfg_start     = 1'b0;
        cfg_mode_load = 1'b0;
        cfg_width     = '0;
        cfg_height    = '0;
        cfg_num_cin   = '0;
        cfg_num_cout  = '0;
        cfg_pool_en   = 1'b0;
        cfg_M_q31     = '0;
        cfg_shift     = '0;
        cfg_output_zp = '0;
        cfg_has_relu  = 1'b0;
        s_data        = '0;
        s_valid       = 1'b0;
        m_ready       = 1'b0;
        n_errors      = 0;

        // Reset
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // -------------------------------------------------------------------
        // PHASE 1: LOAD weights + bias
        // -------------------------------------------------------------------
        $display("[%0t] === PHASE 1: LOAD weights + bias ===", $time);
        cfg_width     = 8'd4;
        cfg_height    = 8'd4;
        cfg_num_cin   = 6'd1;
        cfg_num_cout  = 6'd1;
        cfg_M_q31     = 31'h40000000;   // M = 0.5
        cfg_shift     = 6'd0;
        cfg_output_zp = 8'sd0;
        cfg_has_relu  = 1'b0;

        cfg_mode_load = 1'b1;
        cfg_start     = 1'b1;
        @(posedge clk);

        // 9 weight bytes (kk = 0..8, all = 1) cho cout=0, cin=0
        for (int i = 0; i < 9; i++) axis_send_byte(8'd1);

        // 4 bias bytes (INT32 = 0, little-endian)
        for (int i = 0; i < 4; i++) axis_send_byte(8'd0);

        // Wait for L_DONE
        do @(posedge clk); while (!done);
        $display("[%0t] LOAD done ✓", $time);

        cfg_start = 1'b0;
        @(posedge clk);
        @(posedge clk);

        // -------------------------------------------------------------------
        // PHASE 2: INFER
        // -------------------------------------------------------------------
        $display("[%0t] === PHASE 2: INFER ===", $time);
        cfg_mode_load = 1'b0;
        cfg_start     = 1'b1;

        // Spawn parallel: stream IFM + capture OFM
        fork
            // Stream 4×4×1 = 16 IFM bytes (raster: pixel(y,x)=y*4+x, cin=0 only)
            begin
                for (int y = 0; y < 4; y++) begin
                    for (int x = 0; x < 4; x++) begin
                        axis_send_byte(8'(y*4 + x));
                    end
                end
                $display("[%0t] IFM stream done", $time);
            end

            // Capture 4 OFM bytes
            begin
                for (int oi = 0; oi < 4; oi++) begin
                    logic [7:0] got;
                    axis_recv_byte(got);
                    if ($signed(got) === expected[oi]) begin
                        $display("[%0t] OFM[%0d] = %0d ✓", $time, oi, $signed(got));
                    end else begin
                        $display("[%0t] OFM[%0d] = %0d ✗ (expected %0d)",
                                 $time, oi, $signed(got), expected[oi]);
                        n_errors++;
                    end
                end
            end
        join

        cfg_start = 1'b0;
        m_ready   = 1'b0;

        repeat (10) @(posedge clk);

        if (n_errors == 0)
            $display("\n[%0t] ✓✓✓ TEST PASSED ✓✓✓\n", $time);
        else
            $display("\n[%0t] ✗ TEST FAILED — %0d errors\n", $time, n_errors);

        $finish;
    end

    // Watchdog
    initial begin
        #1_000_000;
        $display("[%0t] WATCHDOG TIMEOUT — FSM stuck?", $time);
        $finish;
    end

endmodule
