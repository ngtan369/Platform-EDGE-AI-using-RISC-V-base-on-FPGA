module pe_mac (
    input  wire clk,
    input  wire rst,
    
    // Tín hiệu điều khiển từ FSM
    input  wire clr,  // Lệnh xóa: Xóa bộ nhớ dồn để bắt đầu tính 1 pixel hoàn toàn mới
    input  wire en,   // Lệnh cho phép: Cho phép bộ MAC nhân và cộng dồn
    
    // Dữ liệu đầu vào
    input  wire signed [7:0] a, // Dữ liệu ảnh (Pixel)
    input  wire signed [7:0] b, // Trọng số (Weight)
    
    output reg  signed [31:0] acc_out 
);

    wire signed [15:0] mult_res;
    assign mult_res = a * b; 

    always @(posedge clk) begin
        if (rst) begin
            acc_out <= 32'd0;
        end
        else if (en) begin
            if (clr) begin
                acc_out <= {{16{mult_res[15]}}, mult_res};
            end 
            else begin
                acc_out <= acc_out + mult_res;
            end
        end
    end

endmodule