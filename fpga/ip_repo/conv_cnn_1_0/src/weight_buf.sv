// =============================================================================
// weight_buf.sv — On-chip filter weight + bias storage cho conv_cnn v2.0.
//
// Storage:
//   • Weights : 9 RAMs ĐỘC LẬP, mỗi RAM = MAX_COUT × MAX_CIN × INT8 = 4 KB
//               → Vivado infer được 9 RAMB18 (≈ 5 RAMB36) thay vì lan thành FF.
//               Tổng: 9 × 4 KB = 36 KB
//   • Biases  : MAX_COUT × INT32 = 64 × 4B = 256 B (LUTRAM)
//
// QUAN TRỌNG: trước đây dùng `w_mem [K_TAPS][MAX_COUT][MAX_CIN]` 3D unpacked
// nhưng Vivado synth fail BRAM inference cho 3D + 9 read ports → fallback FF
// (~295K FFs, vượt 25% capacity của KV260). Fix: tách thành 9 RAM 2D độc lập
// qua `generate` block, mỗi RAM có 1 read port + 1 write port → infer BRAM OK.
//
// Layout: kk-th RAM stores w[cout][cin] với kk = ky*KERNEL + kx.
// Khớp OHWI weight order từ TFLite: weights[cout][kh][kw][cin].
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
    // Bias storage: nhỏ (256 B), distributed RAM
    // -------------------------------------------------------------------------
    (* ram_style = "distributed" *)
    logic signed [BIAS_W-1:0]   b_mem [0:MAX_COUT-1];

    initial begin
        for (int co = 0; co < MAX_COUT; co++) b_mem[co] = '0;
        r_bias = '0;
    end

    always @(posedge clk) begin
        if (we_b) b_mem[b_cout] <= b_data;
    end

    always @(posedge clk) begin
        if (!rst_n) r_bias <= '0;
        else        r_bias <= b_mem[r_cout];
    end

    // -------------------------------------------------------------------------
    // Weight storage: 9 RAM ĐỘC LẬP (1 per kk slot)
    //   Mỗi RAM: MAX_COUT × MAX_CIN × WEIGHT_W = 64 × 64 × 8 = 4 KB = 1 RAMB18
    //   Tổng 9 RAM ≈ 4.5 RAMB36 (Vivado pack 2 RAMB18 vào 1 RAMB36)
    // -------------------------------------------------------------------------
    localparam MEM_DEPTH = MAX_COUT * MAX_CIN; // 64 * 64 = 4096

    genvar gk;
    generate
        for (gk = 0; gk < K_TAPS; gk++) begin : g_w_mem
            // Bùa chú ép kiểu Block RAM
            (* ram_style = "block" *)
            logic signed [WEIGHT_W-1:0] mem [0:MEM_DEPTH-1];

            // Ghép 2 đường địa chỉ (Ví dụ: 6-bit cout + 6-bit cin = 12-bit address)
            // LƯU Ý: Phải đảm bảo (COUT_ADDR_W + CIN_ADDR_W) = $clog2(MEM_DEPTH)
            wire [COUT_ADDR_W+CIN_ADDR_W-1:0] wr_addr = {w_cout, w_cin};
            wire [COUT_ADDR_W+CIN_ADDR_W-1:0] rd_addr = {r_cout, r_cin};

            // Khởi tạo (Chỉ dùng cho Simulation, Synthesis sẽ bỏ qua hoặc nạp từ file)
            initial begin
                for (int i = 0; i < MEM_DEPTH; i++) mem[i] = '0;
            end

            // Cổng Ghi (Write Port)
            always @(posedge clk) begin
                if (we_w && (w_kk == gk[3:0])) begin
                    mem[wr_addr] <= w_data;
                end
            end

            // Cổng Đọc (Read Port) - LOẠI BỎ HOÀN TOÀN TÍN HIỆU RESET
            always @(posedge clk) begin
                r_weights[gk] <= mem[rd_addr]; 
            end
        end
    endgenerate

endmodule
