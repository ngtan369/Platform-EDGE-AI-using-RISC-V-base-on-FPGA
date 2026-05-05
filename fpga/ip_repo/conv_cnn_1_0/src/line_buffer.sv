// =============================================================================
// line_buffer.sv — 2-row sliding window line buffer cho conv_cnn v2.0
//
// Chức năng:
//   • Lưu 2 hàng cuối cùng × MAX_WIDTH × MAX_CIN samples (INT8) trong 2 BRAM bank.
//   • Per pixel sample arrival (x_pos, cin_idx, pixel_in):
//       - Đọc song song 2 BRAM tại addr (x_pos, cin_idx) → cho ra
//         {sample_top (R-2), sample_mid (R-1)} cho row hiện tại R.
//       - Ghi pixel_in vào BRAM "top" tại cùng addr (read-before-write)
//         → BRAM đó sau cùng chứa row R, sẵn sàng làm "mid" cho row R+1.
//   • Khi `row_advance` pulse: toggle parity → đổi vai trò 2 BRAM cho row kế.
//
// Output sample_top/mid/bot align với pixel_in trễ 1 cycle (BRAM read latency).
// =============================================================================
`timescale 1ns/1ps

module line_buffer
    import conv_pkg::*;
(
    input  logic                            clk,
    input  logic                            rst_n,

    // Per-sample input (1 sample/cycle khi shift_en=1)
    input  logic                            shift_en,
    input  logic [WIDTH_ADDR_W-1:0]         x_pos,
    input  logic [CIN_ADDR_W-1:0]           cin_idx,
    input  logic [DATA_W-1:0]               pixel_in,

    // Per-row signal (pulse 1 cycle khi pixel cuối của row vừa được consume)
    input  logic                            row_advance,

    // Output column tại (x_pos, cin_idx) — register 1 cycle so với input
    output logic                            sample_valid,    // = shift_en delayed 1 cycle
    output logic [CIN_ADDR_W-1:0]           sample_cin_idx,
    output logic [DATA_W-1:0]               sample_top,
    output logic [DATA_W-1:0]               sample_mid,
    output logic [DATA_W-1:0]               sample_bot
);

    // -------------------------------------------------------------------------
    // BRAM banks — 2 bank × MAX_WIDTH × MAX_CIN samples
    //   Address = x_pos * MAX_CIN + cin_idx (compile-time MAX_CIN)
    //   Vivado infer RAMB36 / URAM tuỳ tổng size.
    // -------------------------------------------------------------------------
    localparam int BANK_DEPTH  = MAX_WIDTH * MAX_CIN;
    localparam int BANK_ADDR_W = $clog2(BANK_DEPTH);

    // Hai bank độc lập — đọc song song
    (* ram_style = "block" *) logic [DATA_W-1:0] bank_x [0:BANK_DEPTH-1];
    (* ram_style = "block" *) logic [DATA_W-1:0] bank_y [0:BANK_DEPTH-1];

    // Sim-only init (Vivado synth bỏ qua initial blocks lên BRAM ở mức bit-default-0).
    // Đảm bảo không X-propagation khi bank_x/bank_y chưa được ghi.
    initial begin
        for (int i = 0; i < BANK_DEPTH; i++) begin
            bank_x[i] = '0;
            bank_y[i] = '0;
        end
    end

    logic [BANK_ADDR_W-1:0] addr;
    assign addr = (x_pos << CIN_ADDR_W) | cin_idx;

    // -------------------------------------------------------------------------
    // Row parity — toggle khi row_advance pulse
    //   parity = 0: bank_x = top role (R-2 stored), bank_y = mid role (R-1 stored)
    //              → write incoming pixel_in (row R) to bank_x (overwrite R-2)
    //   parity = 1: roles swapped — write to bank_y
    // -------------------------------------------------------------------------
    logic row_parity;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)            row_parity <= 1'b0;
        else if (row_advance)  row_parity <= ~row_parity;
    end

    // -------------------------------------------------------------------------
    // BRAM read-before-write
    //   Đọc 2 bank (cho top/mid của column hiện tại), rồi ghi pixel_in vào
    //   bank đóng vai trò "top" để overwrite row 2-rows-ago.
    //   Read-Before-Write mode: read xuất giá trị CŨ trước khi ghi đè.
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] x_rd, y_rd;
    logic [DATA_W-1:0] pixel_in_q;
    logic              shift_en_q;
    logic [CIN_ADDR_W-1:0] cin_idx_q;
    logic              row_parity_q;

    always_ff @(posedge clk) begin
        if (shift_en) begin
            // Read both banks (1-cycle BRAM read latency)
            x_rd <= bank_x[addr];
            y_rd <= bank_y[addr];

            // Write pixel_in to "top role" bank
            if (row_parity == 1'b0)
                bank_x[addr] <= pixel_in;
            else
                bank_y[addr] <= pixel_in;
        end
    end

    // Pipeline shadow registers cho output align
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_en_q   <= 1'b0;
            pixel_in_q   <= '0;
            cin_idx_q    <= '0;
            row_parity_q <= 1'b0;
        end else begin
            shift_en_q   <= shift_en;
            pixel_in_q   <= pixel_in;
            cin_idx_q    <= cin_idx;
            row_parity_q <= row_parity;
        end
    end

    // -------------------------------------------------------------------------
    // Outputs
    // -------------------------------------------------------------------------
    assign sample_valid   = shift_en_q;
    assign sample_cin_idx = cin_idx_q;
    assign sample_bot     = pixel_in_q;     // current row R sample
    // Top/mid theo parity (parity=0: bank_x=top, bank_y=mid)
    assign sample_top = (row_parity_q == 1'b0) ? x_rd : y_rd;
    assign sample_mid = (row_parity_q == 1'b0) ? y_rd : x_rd;

endmodule
