`timescale 1ns / 1ps

module cpu_wrapper (
    input wire clk,
    input wire rst_n, // Reset tích cực mức thấp

    // ==========================================
    // GIAO TIẾP AXI4-LITE SLAVE (Nối với lõi ARM)
    // ==========================================
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready
    
    // (Phần AXI Master nối ra RAM sẽ thêm ở giai đoạn sau để tránh rối)
);

    // ==========================================
    // KHAI BÁO 6 THANH GHI BẢN ĐỒ BỘ NHỚ
    // ==========================================
    reg [31:0] reg_cmd_from_arm;  // Offset 0x00
    reg [31:0] reg_status_to_arm; // Offset 0x04
    reg [31:0] reg_bbox_xmin;     // Offset 0x08
    reg [31:0] reg_bbox_ymin;     // Offset 0x0C
    reg [31:0] reg_bbox_xmax;     // Offset 0x10
    reg [31:0] reg_bbox_ymax;     // Offset 0x14

    // Logic bắt tay AXI Lite (Giản lược để Vivado tự nhận diện)
    assign s_axi_awready = 1'b1;
    assign s_axi_wready  = 1'b1;
    assign s_axi_bresp   = 2'b00; // OKAY
    assign s_axi_bvalid  = s_axi_wvalid;
    assign s_axi_arready = 1'b1;
    assign s_axi_rresp   = 2'b00; // OKAY

    // ==========================================
    // NHÚNG (INSTANTIATE) LÕI RISC-V CV32E40P
    // ==========================================
    // Đây là nơi "Triệu hồi" con chip tải từ GitHub về
    cv32e40p_core #(
        .PULP_XPULP      (1), // Bật tập lệnh tính toán AI (PULP)
        .FPU             (0), // Tắt toán số thực (Vì ta dùng INT8)
        .NUM_MHPMCOUNTERS(1)
    ) riscv_core_inst (
        .clk_i           (clk),
        .rst_ni          (rst_n),
        
        // Tín hiệu điều khiển cơ bản
        .pulp_clock_en_i (1'b1),
        .scan_cg_en_i    (1'b0),
        .boot_addr_i     (32'h00000000),
        .mtimer_ext_i    (64'd0),
        .core_id_i       (4'h0),
        .cluster_id_i    (6'h0)
        
        // (Các port OBI kết nối bộ nhớ Instruction và Data tạm ẩn để test Add file trước)
    );

endmodule