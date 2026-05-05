// =============================================================================
// window_3x3.sv — 3×3×cin window register array cho conv_cnn v2.0
//
// Lưu cửa sổ 3 spatial cols × 3 spatial rows × MAX_CIN channel slices.
// Mỗi cnt_cin step trong S_COMPUTE đọc ra 9 samples (3×3) cho 1 channel slice.
//
// Hoạt động:
//   • Mỗi sample_valid pulse: ghi samples vào col=2 (rightmost), at slot cin_idx.
//       window[0,2,cin_idx] <= sample_top
//       window[1,2,cin_idx] <= sample_mid
//       window[2,2,cin_idx] <= sample_bot
//   • shift_cols pulse (= window_load_en, end of pixel position): trượt cột
//       col[r][0] <= col[r][1]
//       col[r][1] <= col[r][2]
//       (col[r][2] giữ giá trị, chuẩn bị bị overwrite ở pixel kế)
//   • Read combinational theo cnt_cin: pixel[r*3+c] = window[r][c][cnt_cin]
// =============================================================================
`timescale 1ns/1ps

module window_3x3
    import conv_pkg::*;
(
    input  logic                            clk,
    input  logic                            rst_n,

    // Input từ line_buffer (1 sample/cycle khi sample_valid)
    input  logic                            sample_valid,
    input  logic [CIN_ADDR_W-1:0]           sample_cin_idx,
    input  logic [DATA_W-1:0]               sample_top,
    input  logic [DATA_W-1:0]               sample_mid,
    input  logic [DATA_W-1:0]               sample_bot,

    // Pulse khi pixel position xong (FSM: window_load_en)
    input  logic                            shift_cols,

    // Compute datapath: chọn cin slice và đọc 9 samples
    input  logic [CIN_ADDR_W-1:0]           cnt_cin,
    output logic [DATA_W-1:0]               win_pixel [0:K_TAPS-1]
);

    // -------------------------------------------------------------------------
    // Storage: 3×3 spatial × MAX_CIN slices
    //   Index: window[row][col][channel]
    //   Vivado: nếu MAX_CIN nhỏ (≤16) thì distributed RAM/LUT, lớn hơn dễ map BRAM
    // -------------------------------------------------------------------------
    logic [DATA_W-1:0] window [0:KERNEL-1][0:KERNEL-1][0:MAX_CIN-1];

    // Sim-only init to avoid X (Vivado synth treats as default-0 BRAM init)
    initial begin
        for (int rr = 0; rr < KERNEL; rr++)
            for (int cc = 0; cc < KERNEL; cc++)
                for (int kk = 0; kk < MAX_CIN; kk++)
                    window[rr][cc][kk] = '0;
    end

    // -------------------------------------------------------------------------
    // Write/shift logic
    //   Lưu ý: nếu cùng cycle có sample_valid VÀ shift_cols → ghi vào col=2 của
    //   cửa sổ MỚI (sau shift). FSM hiện tại không generate cùng lúc cả hai
    //   nhưng để defensive: ưu tiên shift trước, write sau (write to new col=2).
    // -------------------------------------------------------------------------
    integer r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int rr = 0; rr < KERNEL; rr++)
                for (int cc = 0; cc < KERNEL; cc++)
                    for (int kk = 0; kk < MAX_CIN; kk++)
                        window[rr][cc][kk] <= '0;
        end else begin
            // 1. Shift columns left khi pixel position xong
            //    Unroll thủ công vì 1 số simulator (iverilog) không hỗ trợ
            //    assign cả 1 array slice (cả MAX_CIN slots) trong 1 statement.
            if (shift_cols) begin
                for (int rr = 0; rr < KERNEL; rr++)
                    for (int kk = 0; kk < MAX_CIN; kk++) begin
                        window[rr][0][kk] <= window[rr][1][kk];
                        window[rr][1][kk] <= window[rr][2][kk];
                        // window[rr][2][kk] giữ — chờ pixel mới ghi đè
                    end
            end

            // 2. Ghi sample mới vào col=2 (rightmost) tại slot sample_cin_idx
            //    (Sau shift nếu cùng cycle)
            if (sample_valid) begin
                window[0][2][sample_cin_idx] <= sample_top;
                window[1][2][sample_cin_idx] <= sample_mid;
                window[2][2][sample_cin_idx] <= sample_bot;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Combinational read: 9 pixels for current cnt_cin slice
    //   Layout: win_pixel[r*3 + c] = window[r][c][cnt_cin]
    //   Đối ứng với weight ordering OHWI: w[cout, kh, kw, cin]
    // -------------------------------------------------------------------------
    always_comb begin
        for (int rr = 0; rr < KERNEL; rr++)
            for (int cc = 0; cc < KERNEL; cc++)
                win_pixel[rr*KERNEL + cc] = window[rr][cc][cnt_cin];
    end

endmodule
