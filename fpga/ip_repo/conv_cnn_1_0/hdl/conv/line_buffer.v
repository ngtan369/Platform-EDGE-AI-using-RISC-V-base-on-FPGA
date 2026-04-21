module line_buffer #(
    parameter IMAGE_WIDTH = 128 // Kích thước ảnh
)(
    input  wire clk,
    input  wire rst,
    input  wire shift_en,      // FSM cho phép dịch
    input  wire [7:0] pixel_in,
    output wire [23:0] col_out // Xuất 3 pixel (3 x 8-bit) cùng lúc
);

    // Mảng bộ nhớ RAM nội bộ: Đủ sức chứa 2 hàng ngang của ảnh
    // Bắt buộc phải dùng 2 bộ đệm để chứa (N-1) hàng cho cửa sổ NxN
    reg [7:0] row_buf_0 [0:IMAGE_WIDTH-1]; 
    reg [7:0] row_buf_1 [0:IMAGE_WIDTH-1];

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            for(i=0; i<IMAGE_WIDTH; i=i+1) begin
                row_buf_0[i] <= 8'd0;
                row_buf_1[i] <= 8'd0;
            end
        end 
        else if (shift_en) begin
            // 1. Dịch toàn bộ bộ đệm sang phải 1 bước
            for(i=IMAGE_WIDTH-1; i>0; i=i-1) begin
                row_buf_0[i] <= row_buf_0[i-1];
                row_buf_1[i] <= row_buf_1[i-1];
            end
            
            // 2. Nạp dữ liệu mới vào đầu bộ đệm
            row_buf_0[0] <= pixel_in;           // Pixel mới nhất vào hàng 0
            row_buf_1[0] <= row_buf_0[IMAGE_WIDTH-1]; // Pixel rớt từ hàng 0 xuống hàng 1
        end
    end

    // Ghép 3 pixel trên cùng 1 cột lại tống ra ngoài
    // Hàng mới nhất (pixel_in), Hàng trễ 1 dòng (buf_0), Hàng trễ 2 dòng (buf_1)
    assign col_out = {row_buf_1[IMAGE_WIDTH-1], row_buf_0[IMAGE_WIDTH-1], pixel_in};

endmodule