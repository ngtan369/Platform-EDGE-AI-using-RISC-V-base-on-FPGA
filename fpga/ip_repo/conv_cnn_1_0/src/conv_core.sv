// =============================================================================
// conv_core.sv — Conv_CNN v2.0 top-level integration.
//
// Hai chế độ:
//   • LOAD  (cfg_mode_load=1): nạp weights+biases từ S00_AXIS vào weight_buf.
//                              Stream order: weights OHWI (cout outer, kk middle,
//                              cin inner), tiếp theo biases (4 byte mỗi cout).
//                              Total bytes/layer = num_cout × (K_TAPS×num_cin + 4)
//   • INFER (cfg_mode_load=0): controller_fsm điều phối streaming IFM →
//                              line_buffer → window_3x3 → 9× pe_mac → adder
//                              tree → requantize → M00_AXIS.
//
// Pipeline timing (INFER):
//   T:    FSM cnt_cin = C → addr weight_buf, addr window (combinational read)
//   T+1:  weight_buf output ready, win_pixel_q latched. mac_en_q=1.
//         pe_mac stage 1 (mult).
//   T+2:  pe_mac stage 2 (acc).
//   T+3:  pe_mac.acc_out final cho cnt_cin=C. (= req_valid_pipe[2] timing)
// Khi C = num_cin-1 (last_cnt_cin) ở cycle T:
//   T+3:  requantize.in_valid pulse, in_acc = adder tree sum (final).
//   T+6:  requantize.out_valid, out_y available → latch.
//   T+7:  FSM in S_EMIT (FSM_DRAIN_CYCLES=6 wait).
// =============================================================================
`timescale 1ns/1ps

module conv_core
    import conv_pkg::*;
(
    input  logic                       clk,
    input  logic                       rst_n,

    // ---- Configuration from S00_AXI ----
    input  logic                       cfg_start,
    input  logic                       cfg_mode_load,    // 1=load weights, 0=infer
    input  logic [WIDTH_ADDR_W-1:0]    cfg_width,
    input  logic [WIDTH_ADDR_W-1:0]    cfg_height,
    input  logic [CIN_ADDR_W-1:0]      cfg_num_cin,
    input  logic [COUT_ADDR_W-1:0]     cfg_num_cout,
    input  logic                       cfg_pool_en,      // unused in v2.0 alpha (TODO 4i)
    input  logic [M_Q31_W-1:0]         cfg_M_q31,
    input  logic [SHIFT_W-1:0]         cfg_shift,
    input  logic signed [DATA_W-1:0]   cfg_output_zp,
    input  logic                       cfg_has_relu,

    // ---- AXIS input (1 byte/sample) ----
    input  logic [DATA_W-1:0]          s_data,
    input  logic                       s_valid,
    output logic                       s_ready,

    // ---- AXIS output (1 byte/sample) ----
    output logic [DATA_W-1:0]          m_data,
    output logic                       m_valid,
    input  logic                       m_ready,

    // ---- Status ----
    output logic                       done
);

    // (silence unused warning until 4i maxpool integration)
    /* verilator lint_off UNUSED */
    logic _unused_pool_en = cfg_pool_en;
    /* verilator lint_on UNUSED */

    // =========================================================================
    // 1. LOAD-PHASE FSM
    // =========================================================================
    typedef enum logic [1:0] {
        L_IDLE     = 2'd0,
        L_WEIGHTS  = 2'd1,
        L_BIAS     = 2'd2,
        L_DONE     = 2'd3
    } load_state_t;

    load_state_t l_state;

    logic [CIN_ADDR_W-1:0]      load_cin;
    logic [3:0]                 load_kk;
    logic [COUT_ADDR_W-1:0]     load_cout;
    logic [1:0]                 load_byte_idx;
    logic [BIAS_W-1:0]          load_bias_assemble;

    // Weight_buf write port driven by load FSM
    logic                       wb_we_w, wb_we_b;
    logic [3:0]                 wb_w_kk;
    logic [COUT_ADDR_W-1:0]     wb_w_cout, wb_b_cout;
    logic [CIN_ADDR_W-1:0]      wb_w_cin;
    logic signed [WEIGHT_W-1:0] wb_w_data;
    logic signed [BIAS_W-1:0]   wb_b_data;

    logic load_s_ready, load_done;

    assign load_s_ready = (l_state == L_WEIGHTS) || (l_state == L_BIAS);
    assign load_done    = (l_state == L_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l_state            <= L_IDLE;
            load_cin           <= '0;
            load_kk            <= '0;
            load_cout          <= '0;
            load_byte_idx      <= '0;
            load_bias_assemble <= '0;
            wb_we_w            <= 1'b0;
            wb_we_b            <= 1'b0;
            wb_w_kk            <= '0;
            wb_w_cout          <= '0;
            wb_w_cin           <= '0;
            wb_w_data          <= '0;
            wb_b_cout          <= '0;
            wb_b_data          <= '0;
        end else begin
            wb_we_w <= 1'b0;        // default no-write
            wb_we_b <= 1'b0;

            unique case (l_state)
                L_IDLE: if (cfg_start && cfg_mode_load) begin
                    l_state       <= L_WEIGHTS;
                    load_cin      <= '0;
                    load_kk       <= '0;
                    load_cout     <= '0;
                    load_byte_idx <= '0;
                end

                L_WEIGHTS: if (s_valid) begin
                    // Write 1 weight byte
                    wb_we_w   <= 1'b1;
                    wb_w_kk   <= load_kk;
                    wb_w_cout <= load_cout;
                    wb_w_cin  <= load_cin;
                    wb_w_data <= $signed(s_data);

                    // Increment counters cin → kk → cout
                    if (load_cin == cfg_num_cin - 1) begin
                        load_cin <= '0;
                        if (load_kk == K_TAPS - 1) begin
                            load_kk <= '0;
                            if (load_cout == cfg_num_cout - 1) begin
                                load_cout     <= '0;
                                load_byte_idx <= '0;
                                l_state       <= L_BIAS;
                            end else begin
                                load_cout <= load_cout + 1;
                            end
                        end else begin
                            load_kk <= load_kk + 1;
                        end
                    end else begin
                        load_cin <= load_cin + 1;
                    end
                end

                L_BIAS: if (s_valid) begin
                    // Assemble little-endian INT32: byte0=LSB ... byte3=MSB
                    case (load_byte_idx)
                        2'd0: load_bias_assemble[7:0]   <= s_data;
                        2'd1: load_bias_assemble[15:8]  <= s_data;
                        2'd2: load_bias_assemble[23:16] <= s_data;
                        2'd3: load_bias_assemble[31:24] <= s_data;
                        default: ;
                    endcase

                    if (load_byte_idx == 2'd3) begin
                        // High byte just arrived → write full INT32 to weight_buf
                        wb_we_b   <= 1'b1;
                        wb_b_cout <= load_cout;
                        wb_b_data <= {s_data, load_bias_assemble[23:0]};
                        load_byte_idx <= '0;

                        if (load_cout == cfg_num_cout - 1) begin
                            l_state <= L_DONE;
                        end else begin
                            load_cout <= load_cout + 1;
                        end
                    end else begin
                        load_byte_idx <= load_byte_idx + 1;
                    end
                end

                L_DONE: if (!cfg_start) l_state <= L_IDLE;

                default: l_state <= L_IDLE;
            endcase
        end
    end

    // =========================================================================
    // 2. INFER-PHASE controller_fsm
    // =========================================================================
    logic                       infer_s_ready;
    logic                       infer_m_valid;
    logic                       infer_done;
    logic                       lbuf_shift_en;
    logic [WIDTH_ADDR_W-1:0]    lbuf_x_pos;
    logic [CIN_ADDR_W-1:0]      lbuf_cin_idx;
    logic                       win_load_en;
    logic                       row_adv;
    logic                       mac_clr;
    logic                       mac_en;
    logic [CIN_ADDR_W-1:0]      cnt_cin;
    logic [COUT_ADDR_W-1:0]     cnt_cout;
    logic                       requant_in_valid_fsm;

    controller_fsm u_ctrl (
        .clk              (clk),
        .rst_n            (rst_n),
        .start            (cfg_start && !cfg_mode_load),
        .cfg_width        (cfg_width),
        .cfg_height       (cfg_height),
        .cfg_num_cin      (cfg_num_cin),
        .cfg_num_cout     (cfg_num_cout),
        .s_valid          (s_valid),
        .s_ready          (infer_s_ready),
        .m_valid          (infer_m_valid),
        .m_ready          (m_ready),
        .line_buf_shift_en(lbuf_shift_en),
        .line_buf_x_pos   (lbuf_x_pos),
        .line_buf_cin_idx (lbuf_cin_idx),
        .window_load_en   (win_load_en),
        .row_advance      (row_adv),
        .mac_clear        (mac_clr),
        .mac_enable       (mac_en),
        .cnt_cin_compute  (cnt_cin),
        .cnt_cout_compute (cnt_cout),
        .requant_in_valid (requant_in_valid_fsm),
        .done             (infer_done)
    );

    // =========================================================================
    // 3. AXIS demux: ready/done switch theo mode
    // =========================================================================
    assign s_ready = cfg_mode_load ? load_s_ready : infer_s_ready;
    assign done    = cfg_mode_load ? load_done    : infer_done;

    // =========================================================================
    // 4. LINE BUFFER + WINDOW (active in INFER mode)
    // =========================================================================
    logic                  sample_valid;
    logic [CIN_ADDR_W-1:0] sample_cin_idx;
    logic [DATA_W-1:0]     sample_top, sample_mid, sample_bot;

    line_buffer u_lbuf (
        .clk           (clk),
        .rst_n         (rst_n),
        .shift_en      (lbuf_shift_en),
        .x_pos         (lbuf_x_pos),
        .cin_idx       (lbuf_cin_idx),
        .pixel_in      (s_data),
        .row_advance   (row_adv),
        .sample_valid  (sample_valid),
        .sample_cin_idx(sample_cin_idx),
        .sample_top    (sample_top),
        .sample_mid    (sample_mid),
        .sample_bot    (sample_bot)
    );

    logic [DATA_W-1:0] win_pixel [0:K_TAPS-1];

    window_3x3 u_window (
        .clk           (clk),
        .rst_n         (rst_n),
        .sample_valid  (sample_valid),
        .sample_cin_idx(sample_cin_idx),
        .sample_top    (sample_top),
        .sample_mid    (sample_mid),
        .sample_bot    (sample_bot),
        .shift_cols    (win_load_en),
        .cnt_cin       (cnt_cin),
        .win_pixel     (win_pixel)
    );

    // =========================================================================
    // 5. WEIGHT BUFFER
    // =========================================================================
    logic signed [WEIGHT_W-1:0] r_weights [0:K_TAPS-1];
    logic signed [BIAS_W-1:0]   r_bias;

    weight_buf u_wb (
        .clk      (clk),
        .rst_n    (rst_n),
        .we_w     (wb_we_w),
        .w_kk     (wb_w_kk),
        .w_cout   (wb_w_cout),
        .w_cin    (wb_w_cin),
        .w_data   (wb_w_data),
        .we_b     (wb_we_b),
        .b_cout   (wb_b_cout),
        .b_data   (wb_b_data),
        .r_cout   (cnt_cout),
        .r_cin    (cnt_cin),
        .r_weights(r_weights),
        .r_bias   (r_bias)
    );

    // =========================================================================
    // 6. PIPELINE ALIGN: register window output + control 1 cycle để khớp
    //    weight_buf BRAM read latency.
    // =========================================================================
    logic [DATA_W-1:0] win_pixel_q [0:K_TAPS-1];
    logic              mac_clr_q, mac_en_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_clr_q <= 1'b0;
            mac_en_q  <= 1'b0;
            for (int i = 0; i < K_TAPS; i++) win_pixel_q[i] <= '0;
        end else begin
            mac_clr_q <= mac_clr;
            mac_en_q  <= mac_en;
            for (int i = 0; i < K_TAPS; i++) win_pixel_q[i] <= win_pixel[i];
        end
    end

    // =========================================================================
    // 7. PE_MAC × 9 + ADDER TREE
    // =========================================================================
    logic signed [ACC_W-1:0] mac_out [0:K_TAPS-1];

    genvar gi;
    generate
        for (gi = 0; gi < K_TAPS; gi++) begin : g_mac
            pe_mac u_pe (
                .clk    (clk),
                .rst_n  (rst_n),
                .clr    (mac_clr_q),
                .en     (mac_en_q),
                .a      (win_pixel_q[gi]),
                .b      (r_weights[gi]),
                .acc_out(mac_out[gi])
            );
        end
    endgenerate

    // Adder tree (combinational): 9 × INT32 → INT32
    logic signed [ACC_W-1:0] tree_sum;
    always_comb begin
        tree_sum = mac_out[0] + mac_out[1] + mac_out[2]
                 + mac_out[3] + mac_out[4] + mac_out[5]
                 + mac_out[6] + mac_out[7] + mac_out[8];
    end

    // =========================================================================
    // 8. REQUANTIZE
    //    Delay requant_in_valid 3 cycles để khớp với pe_mac.acc_out final.
    // =========================================================================
    logic [2:0] req_valid_pipe;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) req_valid_pipe <= '0;
        else        req_valid_pipe <= {req_valid_pipe[1:0], requant_in_valid_fsm};
    end

    logic                     req_out_valid;
    logic signed [DATA_W-1:0] req_out_y;

    requantize u_req (
        .clk           (clk),
        .rst_n         (rst_n),
        .cfg_M_q31     (cfg_M_q31),
        .cfg_shift     (cfg_shift),
        .cfg_output_zp (cfg_output_zp),
        .cfg_has_relu  (cfg_has_relu),
        .in_valid      (req_valid_pipe[2]),
        .in_acc        (tree_sum),
        .in_bias       (r_bias),
        .out_valid     (req_out_valid),
        .out_y         (req_out_y)
    );

    // =========================================================================
    // 9. AXIS OUTPUT
    //    Latch req_out_y khi out_valid; FSM's infer_m_valid controls handshake.
    //    NOTE: chưa support back-pressure đúng (m_ready=0 sẽ làm rớt sample).
    //    TODO 4i: add small FIFO output cho proper back-pressure.
    // =========================================================================
    logic [DATA_W-1:0] req_out_latched;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)            req_out_latched <= '0;
        else if (req_out_valid) req_out_latched <= req_out_y;
    end

    assign m_data  = req_out_latched;
    assign m_valid = infer_m_valid;

endmodule
