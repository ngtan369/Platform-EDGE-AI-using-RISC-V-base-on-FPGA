// =============================================================================
// controller_fsm.sv — Conv_CNN v2.0 controller (REWRITE)
//
// Quản lý 6 vòng đếm cho 3×3 stride-1 valid-padded conv:
//   y_in, x_in       : input pixel position (raster scan)
//   cin_in           : channel counter within current input pixel (0..num_cin-1)
//   cnt_cout, cnt_cin: compute loop counters
//
// Stream order IFM (channel-interleaved per pixel position):
//   pixel(0,0,c=0..C-1), pixel(0,1,c=0..C-1), ..., pixel(H-1,W-1,c=0..C-1)
//
// Per output pixel (x_out=x_in-2, y_out=y_in-2, valid khi x_in>=2 && y_in>=2):
//   for cnt_cout in 0..num_cout-1:
//     mac_clear (1 cycle)
//     for cnt_cin in 0..num_cin-1: mac_enable (1 cycle each)
//     requant_in_valid pulse (last cnt_cin cycle)
//     wait FSM_DRAIN_CYCLES cycles (cover PE_MAC + weight_buf + requant pipeline)
//     m_valid (1 cycle, gated on m_ready)
//   advance input pixel position
//
// Tổng cycles per output pixel ≈ num_cout × (num_cin + FSM_DRAIN_CYCLES + 1).
// =============================================================================
`timescale 1ns/1ps

module controller_fsm
    import conv_pkg::*;
(
    input  logic                            clk,
    input  logic                            rst_n,

    // ---- Configuration (latch ngoài, hold suốt layer) ----
    input  logic                            start,
    input  logic [WIDTH_ADDR_W-1:0]         cfg_width,    // input W (pixel)
    input  logic [WIDTH_ADDR_W-1:0]         cfg_height,   // input H (pixel)
    input  logic [CIN_ADDR_W-1:0]           cfg_num_cin,
    input  logic [COUT_ADDR_W-1:0]          cfg_num_cout,

    // ---- Input AXIS handshake ----
    input  logic                            s_valid,
    output logic                            s_ready,

    // ---- Output AXIS handshake ----
    output logic                            m_valid,
    input  logic                            m_ready,

    // ---- Datapath control outputs ----
    output logic                            line_buf_shift_en,
    output logic [WIDTH_ADDR_W-1:0]         line_buf_x_pos,
    output logic [CIN_ADDR_W-1:0]           line_buf_cin_idx,
    output logic                            window_load_en,    // pulse khi cin sample cuối nhận xong
    output logic                            row_advance,       // pulse khi pixel cuối của row vừa nhận xong

    output logic                            mac_clear,         // pulse khi bắt đầu cnt_cout mới
    output logic                            mac_enable,        // active suốt S_COMPUTE
    output logic [CIN_ADDR_W-1:0]           cnt_cin_compute,   // địa chỉ window/weight trong inner loop
    output logic [COUT_ADDR_W-1:0]          cnt_cout_compute,  // chọn filter

    output logic                            requant_in_valid,  // 1-cycle pulse cuối cnt_cin

    output logic                            done
);

    // -------------------------------------------------------------------------
    // State enumeration
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE         = 3'd0,
        S_ACCEPT_CIN   = 3'd1,   // s_ready=1, gom cin samples cho 1 pixel
        S_LATCH_WIN    = 3'd2,   // 1-cycle wait cho line_buffer→window col 2 update
        S_COMPUTE      = 3'd3,   // mac_enable=1, đếm cnt_cin
        S_WAIT_REQUANT = 3'd4,   // chờ pipeline requantize
        S_EMIT         = 3'd5,   // m_valid=1
        S_DONE_S       = 3'd6
    } state_t;

    state_t state, next_state;

    // -------------------------------------------------------------------------
    // Counters
    // -------------------------------------------------------------------------
    logic [WIDTH_ADDR_W-1:0]    x_in,  y_in;
    logic [CIN_ADDR_W-1:0]      cin_in;
    logic [CIN_ADDR_W-1:0]      cnt_cin_r;
    logic [COUT_ADDR_W-1:0]     cnt_cout_r;
    logic [3:0]                 wait_cnt;       // 0..FSM_DRAIN_CYCLES-1

    // Convenience flags
    logic last_cin_in;
    logic window_valid;             // x_in>=2 && y_in>=2 (đủ điều kiện compute output)
    logic last_x_in, last_y_in;
    logic last_cnt_cin, last_cnt_cout;

    assign last_cin_in   = (cin_in    == cfg_num_cin  - 1);
    assign window_valid  = (x_in >= 2) && (y_in >= 2);
    assign last_x_in     = (x_in == cfg_width  - 1);
    assign last_y_in     = (y_in == cfg_height - 1);
    assign last_cnt_cin  = (cnt_cin_r  == cfg_num_cin  - 1);
    assign last_cnt_cout = (cnt_cout_r == cfg_num_cout - 1);

    // -------------------------------------------------------------------------
    // FSM sequential
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    // -------------------------------------------------------------------------
    // FSM combinational next_state + default outputs
    // -------------------------------------------------------------------------
    always_comb begin
        next_state         = state;
        s_ready            = 1'b0;
        m_valid            = 1'b0;
        line_buf_shift_en  = 1'b0;
        window_load_en     = 1'b0;
        mac_clear          = 1'b0;
        mac_enable         = 1'b0;
        requant_in_valid   = 1'b0;
        row_advance        = 1'b0;
        done               = 1'b0;

        unique case (state)
            // ------------- IDLE -------------
            S_IDLE: begin
                done = 1'b1;
                if (start) next_state = S_ACCEPT_CIN;
            end

            // ------------- ACCEPT_CIN -------------
            // Nhận num_cin samples cho pixel (x_in, y_in). Khi cin_in cuối:
            //   • pulse window_load_en
            //   • nếu window_valid → S_COMPUTE
            //   • else → tiếp tục S_ACCEPT_CIN (skip output cho biên)
            //   • sau cùng: advance (x_in, y_in)
            S_ACCEPT_CIN: begin
                s_ready           = 1'b1;
                line_buf_shift_en = s_valid;
                if (s_valid && last_cin_in) begin
                    window_load_en = 1'b1;
                    // row_advance: last cin của last x của row vừa nhận xong
                    if (last_x_in) row_advance = 1'b1;
                    if (window_valid)
                        next_state = S_LATCH_WIN;
                    // else: fall-through stay in S_ACCEPT_CIN (counter advance below)
                end
            end

            // ------------- LATCH_WIN -------------
            // 1-cycle wait: line_buffer's BRAM read + sample register cần thêm
            // 1 cycle để window col 2 có giá trị mới trước khi compute đọc.
            S_LATCH_WIN: begin
                next_state = S_COMPUTE;
            end

            // ------------- COMPUTE -------------
            S_COMPUTE: begin
                mac_enable = 1'b1;
                // mac_clear chỉ pulse khi vừa vào (cnt_cin == 0)
                mac_clear  = (cnt_cin_r == '0);
                if (last_cnt_cin) begin
                    requant_in_valid = 1'b1;       // kick requant pipeline
                    next_state       = S_WAIT_REQUANT;
                end
            end

            // ------------- WAIT_REQUANT -------------
            // FSM_DRAIN_CYCLES (=6) cycle bubble: PE_MAC pipe + weight_buf + requant
            S_WAIT_REQUANT: begin
                if (wait_cnt == FSM_DRAIN_CYCLES - 1)
                    next_state = S_EMIT;
            end

            // ------------- EMIT -------------
            S_EMIT: begin
                m_valid = 1'b1;
                if (m_ready) begin
                    if (last_cnt_cout) begin
                        // output pixel xong; quyết định next pixel hay done
                        if (last_x_in && last_y_in)
                            next_state = S_DONE_S;
                        else
                            next_state = S_ACCEPT_CIN;
                    end else begin
                        next_state = S_COMPUTE;
                    end
                end
            end

            // ------------- DONE_S -------------
            S_DONE_S: begin
                done = 1'b1;
                if (!start) next_state = S_IDLE;
            end

            default: next_state = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Counter sequential
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_in       <= '0;
            y_in       <= '0;
            cin_in     <= '0;
            cnt_cin_r  <= '0;
            cnt_cout_r <= '0;
            wait_cnt   <= '0;
        end else begin
            unique case (state)
                S_IDLE: if (start) begin
                    x_in       <= '0;
                    y_in       <= '0;
                    cin_in     <= '0;
                    cnt_cin_r  <= '0;
                    cnt_cout_r <= '0;
                end

                S_ACCEPT_CIN: if (s_valid) begin
                    if (last_cin_in) begin
                        cin_in <= '0;
                        // advance input pixel position
                        if (last_x_in) begin
                            x_in <= '0;
                            if (!last_y_in) y_in <= y_in + 1;
                        end else begin
                            x_in <= x_in + 1;
                        end
                        // Reset compute counters (sẽ chạy nếu window_valid)
                        cnt_cin_r  <= '0;
                        cnt_cout_r <= '0;
                    end else begin
                        cin_in <= cin_in + 1;
                    end
                end

                S_COMPUTE: begin
                    if (last_cnt_cin)
                        cnt_cin_r <= '0;
                    else
                        cnt_cin_r <= cnt_cin_r + 1;

                    // entering S_WAIT_REQUANT next cycle: reset wait counter
                    if (last_cnt_cin) wait_cnt <= '0;
                end

                S_WAIT_REQUANT: begin
                    if (wait_cnt < FSM_DRAIN_CYCLES - 1)
                        wait_cnt <= wait_cnt + 1;
                end

                S_EMIT: if (m_ready) begin
                    if (last_cnt_cout) begin
                        cnt_cout_r <= '0;     // reset cho pixel kế tiếp
                    end else begin
                        cnt_cout_r <= cnt_cout_r + 1;
                        cnt_cin_r  <= '0;     // reset inner loop
                    end
                end

                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Outputs to datapath
    // -------------------------------------------------------------------------
    assign line_buf_x_pos    = x_in;
    assign line_buf_cin_idx  = cin_in;
    assign cnt_cin_compute   = cnt_cin_r;
    assign cnt_cout_compute  = cnt_cout_r;

endmodule
