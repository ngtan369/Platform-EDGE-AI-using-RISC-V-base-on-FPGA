`timescale 1ns / 1ps

module top_wrapper (
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
    input  wire        s_axi_rready,
    
    // ==========================================
    // GIAO TIẾP BỘ NH�? OBI (Nối ra BRAM/DDR)
    // ==========================================
    // 1. Kênh Instruction (�?�?c lệnh)
    output wire        instr_req_o,
    input  wire        instr_gnt_i,
    input  wire        instr_rvalid_i,
    output wire [31:0] instr_addr_o,
    input  wire [31:0] instr_rdata_i,

    // 2. Kênh Data (�?�?c/Ghi dữ liệu AI)
    output wire        data_req_o,
    input  wire        data_gnt_i,
    input  wire        data_rvalid_i,
    output wire        data_we_o,
    output wire [3:0]  data_be_o,
    output wire [31:0] data_addr_o,
    output wire [31:0] data_wdata_o,
    input  wire [31:0] data_rdata_i
);

    // Logic bắt tay AXI Lite (Giản lược)
    assign s_axi_awready = 1'b1;
    assign s_axi_wready  = 1'b1;
    assign s_axi_bresp   = 2'b00; // OKAY
    assign s_axi_bvalid  = s_axi_wvalid;
    assign s_axi_arready = 1'b1;
    assign s_axi_rresp   = 2'b00; // OKAY


    // ==========================================
    // LOGIC CHỐNG GHI NHẦM BRAM
    // ==========================================
    wire        core_we;
    wire [3:0]  core_be;
    
    // Nếu Core báo Ghi (1) -> Cho phép BE đi qua
    // Nếu Core báo Đọc (0) -> Ép BE về 0000 để khóa họng BRAM lại
    assign data_be_o = core_we ? core_be : 4'b0000; 
    
    // Vẫn xuất we_o ra vỏ ngoài cho đủ bộ cổng
    assign data_we_o = core_we;

    // ==========================================
    // NH�?NG (INSTANTIATE) LÕI RISC-V CV32E40P
    // ==========================================
    cv32e40p_core #(
        .PULP_XPULP      (1), 
        .FPU             (0), 
        .NUM_MHPMCOUNTERS(1)
    ) riscv_core_inst (
        .clk_i           (clk),
        .rst_ni          (rst_n),
        
        // --- Các chân cấu hình và đi�?u khiển ---
        .pulp_clock_en_i (1'b1),
        .scan_cg_en_i    (1'b0),
        .boot_addr_i     (32'h00000000),
        .mtimer_ext_i    (64'd0),
        .core_id_i       (4'h0),
        .cluster_id_i    (6'h0),
        
        // --- C�?C CHÂN CẤU HÌNH �?�?A CHỈ BẮT BUỘC ---
        .mtvec_addr_i        (32'h00000000),
        .dm_halt_addr_i      (32'h1A110800),
        .hart_id_i           (32'h00000000),
        .dm_exception_addr_i (32'h1A110808),
        .fetch_enable_i      (1'b1), // Bắt buộc = 1 để CPU chạy
        
        // --- C�?C CHÂN NGẮT VÀ DEBUG (Tắt hết = 0) ---
        .irq_i               (32'b0),
        .debug_req_i         (1'b0),
        
        // --- C�?C CHÂN FPU (Bắt buộc khai báo dù FPU=0) ---
        .apu_gnt_i           (1'b0),
        .apu_rvalid_i        (1'b0),
        .apu_result_i        (32'b0),
        .apu_flags_i         (5'b0),

        // --- K�?NH INSTRUCTION ---
        .instr_req_o     (instr_req_o),
        .instr_gnt_i     (instr_gnt_i),
        .instr_rvalid_i  (instr_rvalid_i),
        .instr_addr_o    (instr_addr_o),
        .instr_rdata_i   (instr_rdata_i),
        .instr_err_i     (1'b0), 

        // --- K�?NH DATA ---
        .data_req_o      (data_req_o),
        .data_gnt_i      (data_gnt_i),
        .data_rvalid_i   (data_rvalid_i),

        .data_we_o       (core_we),  // <--- Đổi thành core_we
        .data_be_o       (core_be),  // <--- Đổi thành core_be
        
        .data_addr_o     (data_addr_o),
        .data_wdata_o    (data_wdata_o),
        .data_rdata_i    (data_rdata_i),
        .data_err_i      (1'b0)  
    );

endmodule