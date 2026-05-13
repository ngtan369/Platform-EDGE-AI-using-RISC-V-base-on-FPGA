`timescale 1ns / 1ps

module cv32e40p_clock_gate (
    input  logic clk_i,
    input  logic en_i,
    input  logic scan_cg_en_i,
    output logic clk_o
);

    // ========================================================
    // BẢN VÁ DÀNH RIÊNG CHO FPGA XILINX (Kria KV260 / Zynq)
    // Sử dụng BUFGCE primitive để cắt xung nhịp an toàn 100%
    // ========================================================
    BUFGCE bufgce_inst (
        .I  (clk_i), 
        .CE (en_i | scan_cg_en_i), 
        .O  (clk_o)
    );

endmodule