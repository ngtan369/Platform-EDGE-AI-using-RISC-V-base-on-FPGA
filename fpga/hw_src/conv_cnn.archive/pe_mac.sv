// Tên file: pe_mac.sv
// Chức năng: Processing Element (MAC) có Pipeline, tối ưu cho DSP48E2 của Xilinx

module pe_mac (
    input  wire clk,
    input  wire rst_n,      // Đổi thành rst_n (Active-low) cho đồng bộ với FSM và AXI
    
    // Tín hiệu điều khiển từ FSM
    input  wire clr,        // Lệnh xóa Accumulator (từ INIT_PIXEL)
    input  wire en,         // Lệnh cho phép tính (từ CALC_CIN)
    
    // Dữ liệu đầu vào
    input  wire signed [7:0] a, // Pixel
    input  wire signed [7:0] b, // Weight
    
    output reg  signed [31:0] acc_out 
);

    // ==========================================
    // TẦNG PIPELINE 1: Mạch Nhân (Multiplier)
    // ==========================================
    // Khai báo các thanh ghi đệm (Tương ứng với thanh ghi MREG trong khối DSP48)
    reg signed [15:0] mult_reg;
    reg               clr_q;
    reg               en_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mult_reg <= '0;
            clr_q    <= 1'b0;
            en_q     <= 1'b0;
        end else begin
            // Thực hiện nhân và CHỐT kết quả vào thanh ghi đệm
            mult_reg <= a * b; 
            
            // QUAN TRỌNG: Tín hiệu điều khiển cũng phải bị trễ đi 1 nhịp
            // để đi song song cùng với dữ liệu (Data synchronization)
            clr_q    <= clr;
            en_q     <= en;
        end
    end

    // ==========================================
    // TẦNG PIPELINE 2: Mạch Cộng dồn (Accumulator)
    // ==========================================
    // Tương ứng với thanh ghi PREG trong khối DSP48
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= 32'd0;
        end
        else if (en_q) begin // Sử dụng cờ 'en_q' (đã bị trễ 1 nhịp)
            if (clr_q) begin
                // Bắt đầu chuỗi mới: Nạp kết quả nhân (kèm Sign Extension) vào Accumulator
                acc_out <= {{16{mult_reg[15]}}, mult_reg};
            end 
            else begin
                // Đang trong vòng lặp Cin: Cộng dồn tiếp
                acc_out <= acc_out + {{16{mult_reg[15]}}, mult_reg};
            end
        end
    end

endmodule