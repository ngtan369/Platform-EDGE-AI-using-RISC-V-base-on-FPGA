// Tên file: window_3x3.sv
// Ch?c nãng: Nh?n 1 c?t 3 pixel t? Line Buffer và trý?t ngang t?o ra 9 pixel

module window_3x3 (
    input  wire clk,
    input  wire rst_n,
    input  wire en,
    input  wire [23:0] col_in, // C?t 24-bit nh?n t? line_buffer

    output reg signed [7:0] p00, p01, p02,
    output reg signed [7:0] p10, p11, p12,
    output reg signed [7:0] p20, p21, p22
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p00 <= '0; p01 <= '0; p02 <= '0;
            p10 <= '0; p11 <= '0; p12 <= '0;
            p20 <= '0; p21 <= '0; p22 <= '0;
        end else if (en) begin
            // Trý?t toàn b? c?a s? sang trái 1 bý?c
            p00 <= p01; p01 <= p02; 
            p10 <= p11; p11 <= p12; 
            p20 <= p21; p21 <= p22; 
            
            // N?p c?t m?i (col_in) vào l? ph?i c?a c?a s?
            // col_in ch?a {hàng_c?_nh?t, hàng_gi?a, hàng_m?i_nh?t}
            p02 <= col_in[23:16];
            p12 <= col_in[15:8];
            p22 <= col_in[7:0];
        end
    end

endmodule