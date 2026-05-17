// =============================================================================
// controller_fsm.sv — Conv_CNN v2.1 controller (parallel cout)
//
// v2.1 change: process N_COUT_PE cout banks in parallel during S_COMPUTE.
// FSM counter `cout_batch_r` ∈ [0, ceil(num_cout/N_COUT_PE) - 1] indexes
// which batch (8 cout's at a time). Last batch may be partial (e.g., layer 4
// with cout=2 → 1 batch with emit_count=2).
//
// Per pixel cycles (with cin=32, cout=64, N_COUT_PE=8):
//   S_ACCEPT_CIN  : 32                       (one cin sample per cycle)
//   S_LATCH_WIN   : 1
//   For each of (num_cout/N) = 8 batches:
//     S_COMPUTE   : 32                       (one cnt_cin per cycle)
//     S_WAIT_REQ  : FSM_DRAIN_CYCLES = 6
//     S_EMIT      : N_COUT_PE = 8            (serial emit through packer)
//   Total: 32 + 1 + 8 × (32+6+8) = 401 cycles/pixel
//   vs v2.0: 2529 cycles/pixel → speedup 6.3×
// =============================================================================
`timescale 1ns/1ps

module controller_fsm
    import conv_pkg::*;
(
    input  logic                            clk,
    input  logic                            rst_n,

    // ---- Configuration (latch ngoài, hold suốt layer) ----
    input  logic                            start,
    input  logic [WIDTH_ADDR_W-1:0]         cfg_width,
    input  logic [WIDTH_ADDR_W-1:0]         cfg_height,
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
    output logic                            window_load_en,
    output logic                            row_advance,

    output logic                            mac_clear,
    output logic                            mac_enable,
    output logic [CIN_ADDR_W-1:0]           cnt_cin_compute,
    output logic [COUT_HIGH_W-1:0]          cout_high_compute,  // batch idx → weight_buf
    output logic [COUT_BANK_W-1:0]          emit_bank_sel,      // 0..N_COUT_PE-1 in S_EMIT

    output logic                            requant_in_valid,

    output logic                            done
);

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE         = 3'd0,
        S_ACCEPT_CIN   = 3'd1,
        S_LATCH_WIN    = 3'd2,
        S_COMPUTE      = 3'd3,
        S_WAIT_REQUANT = 3'd4,
        S_EMIT         = 3'd5,
        S_DONE_S       = 3'd6
    } state_t;

    state_t state, next_state;
    initial state = S_IDLE;

    // -------------------------------------------------------------------------
    // Counters
    // -------------------------------------------------------------------------
    logic [WIDTH_ADDR_W-1:0]    x_in,  y_in;
    logic [CIN_ADDR_W-1:0]      cin_in;
    logic [CIN_ADDR_W-1:0]      cnt_cin_r;
    logic [COUT_BATCH_W-1:0]    cout_batch_r;          // batch index (0..MAX/N-1)
    logic [COUT_BANK_W-1:0]     emit_idx_r;            // emit pointer within batch
    logic [3:0]                 wait_cnt;
    logic                       is_last_pixel;

    initial begin
        x_in = '0; y_in = '0; cin_in = '0;
        cnt_cin_r = '0; cout_batch_r = '0; emit_idx_r = '0;
        wait_cnt = '0; is_last_pixel = 1'b0;
    end

    // -------------------------------------------------------------------------
    // Derived "last index" signals (field-width truncation to handle MAX overflow)
    // -------------------------------------------------------------------------
    logic [CIN_ADDR_W-1:0]   cin_last_idx;
    logic [WIDTH_ADDR_W-1:0] x_last_idx, y_last_idx;
    logic [COUT_ADDR_W-1:0]  num_cout_m1;
    logic [COUT_BATCH_W-1:0] cout_batch_last_idx;
    logic [COUT_BANK_W-1:0]  emit_last_idx_curr;       // for the CURRENT batch

    localparam logic [COUT_BANK_W-1:0] FULL_BATCH_LAST = N_COUT_PE - 1;

    assign cin_last_idx        = cfg_num_cin  - 1'b1;
    assign x_last_idx          = cfg_width    - 1'b1;
    assign y_last_idx          = cfg_height   - 1'b1;
    assign num_cout_m1         = cfg_num_cout - 1'b1;
    // Batch index of the last (possibly partial) batch:
    assign cout_batch_last_idx = num_cout_m1[COUT_ADDR_W-1:COUT_BANK_W];
    // For the current batch, the highest emit_idx that is still a valid cout:
    assign emit_last_idx_curr  = (cout_batch_r == cout_batch_last_idx)
                                 ? num_cout_m1[COUT_BANK_W-1:0]   // partial last batch
                                 : FULL_BATCH_LAST;                // full batch = N-1

    // Convenience flags
    logic last_cin_in;
    logic window_valid;
    logic last_x_in, last_y_in;
    logic last_cnt_cin, last_cout_batch, last_emit_idx;

    assign last_cin_in     = (cin_in       == cin_last_idx);
    assign window_valid    = (x_in >= 2) && (y_in >= 2);
    assign last_x_in       = (x_in == x_last_idx);
    assign last_y_in       = (y_in == y_last_idx);
    assign last_cnt_cin    = (cnt_cin_r    == cin_last_idx);
    assign last_cout_batch = (cout_batch_r == cout_batch_last_idx);
    assign last_emit_idx   = (emit_idx_r   == emit_last_idx_curr);

    // -------------------------------------------------------------------------
    // FSM sequential
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    // -------------------------------------------------------------------------
    // FSM combinational
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
            S_IDLE: begin
                done = 1'b1;
                if (start) next_state = S_ACCEPT_CIN;
            end

            S_ACCEPT_CIN: begin
                s_ready           = 1'b1;
                line_buf_shift_en = s_valid;
                if (s_valid && last_cin_in) begin
                    window_load_en = 1'b1;
                    if (last_x_in) row_advance = 1'b1;
                    if (window_valid)
                        next_state = S_LATCH_WIN;
                    // else: stay in S_ACCEPT_CIN (border pixel)
                end
            end

            S_LATCH_WIN: next_state = S_COMPUTE;

            S_COMPUTE: begin
                mac_enable = 1'b1;
                mac_clear  = (cnt_cin_r == '0);
                if (last_cnt_cin) begin
                    requant_in_valid = 1'b1;
                    next_state       = S_WAIT_REQUANT;
                end
            end

            S_WAIT_REQUANT: begin
                if (wait_cnt == FSM_DRAIN_CYCLES - 1)
                    next_state = S_EMIT;
            end

            S_EMIT: begin
                m_valid = 1'b1;
                if (m_ready) begin
                    if (last_emit_idx) begin
                        // batch's last valid output emitted
                        if (last_cout_batch) begin
                            // last batch's last output → pixel complete
                            if (is_last_pixel)
                                next_state = S_DONE_S;
                            else
                                next_state = S_ACCEPT_CIN;
                        end else begin
                            // more batches for this pixel → recompute (different cout_high)
                            next_state = S_COMPUTE;
                        end
                    end
                end
            end

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
            x_in          <= '0;
            y_in          <= '0;
            cin_in        <= '0;
            cnt_cin_r     <= '0;
            cout_batch_r  <= '0;
            emit_idx_r    <= '0;
            wait_cnt      <= '0;
            is_last_pixel <= 1'b0;
        end else begin
            unique case (state)
                S_IDLE: if (start) begin
                    x_in          <= '0;
                    y_in          <= '0;
                    cin_in        <= '0;
                    cnt_cin_r     <= '0;
                    cout_batch_r  <= '0;
                    emit_idx_r    <= '0;
                    is_last_pixel <= 1'b0;
                end

                S_ACCEPT_CIN: if (s_valid) begin
                    if (last_cin_in) begin
                        if (last_x_in && last_y_in) is_last_pixel <= 1'b1;
                        cin_in <= '0;
                        if (last_x_in) begin
                            x_in <= '0;
                            if (!last_y_in) y_in <= y_in + 1;
                        end else begin
                            x_in <= x_in + 1;
                        end
                        cnt_cin_r    <= '0;
                        cout_batch_r <= '0;
                        emit_idx_r   <= '0;
                    end else begin
                        cin_in <= cin_in + 1;
                    end
                end

                S_COMPUTE: begin
                    if (last_cnt_cin) cnt_cin_r <= '0;
                    else              cnt_cin_r <= cnt_cin_r + 1;

                    if (last_cnt_cin) wait_cnt <= '0;
                end

                S_WAIT_REQUANT: begin
                    if (wait_cnt < FSM_DRAIN_CYCLES - 1)
                        wait_cnt <= wait_cnt + 1;
                end

                S_EMIT: if (m_ready) begin
                    if (last_emit_idx) begin
                        emit_idx_r <= '0;
                        if (last_cout_batch) begin
                            // pixel done; reset for next pixel
                            cout_batch_r <= '0;
                            cnt_cin_r    <= '0;
                        end else begin
                            cout_batch_r <= cout_batch_r + 1;
                            cnt_cin_r    <= '0;   // reset inner loop for next batch
                        end
                    end else begin
                        emit_idx_r <= emit_idx_r + 1;
                    end
                end

                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Output assigns
    // -------------------------------------------------------------------------
    assign line_buf_x_pos    = x_in;
    assign line_buf_cin_idx  = cin_in;
    assign cnt_cin_compute   = cnt_cin_r;
    assign cout_high_compute = cout_batch_r;
    assign emit_bank_sel     = emit_idx_r;

endmodule
