// Tên file: max_pool.sv (ho?c max_pool_2x2.sv tùy b?n ðang ð?t)
// Ch?c nãng: T?m Max ô 2x2, Stride = 2 (Ð? t?i ýu cú pháp cho Vivado)

module max_pool_2x2 #(
    parameter MAX_WIDTH = 256
)(
    input  wire clk,
    input  wire rst_n,
    input  wire en,
    input  wire [9:0] active_width,
    input  wire [7:0] pixel_in,
    
    output reg  [7:0] pixel_out,
    output reg  out_valid
);

    reg [7:0] max_row_buf [0:(MAX_WIDTH/2)-1];
    reg [9:0] x_cnt;
    reg       y_bit;
    reg [7:0] p_even;

    // Chuy?n logic so sánh ra ngoài (Combinational Wire) ð? Vivado d? tiêu hóa
    wire [7:0] max_x = (p_even > pixel_in) ? p_even : pixel_in;
    wire [8:0] buf_idx = x_cnt[9:1]; // x_cnt d?ch ph?i 1 bit (týõng ðýõng chia 2)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt     <= '0;
            y_bit     <= 1'b0;
            out_valid <= 1'b0;
            pixel_out <= '0;
            p_even    <= '0;
        end else begin
            out_valid <= 1'b0; 
            
            if (en) begin
                if (x_cnt[0] == 1'b0) begin 
                    // C?t ch?n: Lýu t?m pixel
                    p_even <= pixel_in;
                end else begin
                    // C?t l?: Tính toán
                    if (y_bit == 1'b0) begin
                        // Hàng ch?n: Ghi vào BRAM
                        max_row_buf[buf_idx] <= max_x;
                    end else begin
                        // Hàng l?: So sánh v?i BRAM và xu?t k?t qu?
                        pixel_out <= (max_x > max_row_buf[buf_idx]) ? max_x : max_row_buf[buf_idx];
                        out_valid <= 1'b1; 
                    end
                end
                
                // C?p nh?t b? ð?m t?a ð?
                if (x_cnt == active_width - 1) begin
                    x_cnt <= '0;
                    y_bit <= ~y_bit;
                end else begin
                    x_cnt <= x_cnt + 1'b1;
                end
            end
        end
    end

endmodule