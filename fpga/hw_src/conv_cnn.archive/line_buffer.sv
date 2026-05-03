// Tên file: line_buffer.sv
// Chức năng: Bộ đệm dòng linh hoạt (Hỗ trợ cấu hình kích thước từ ARM)

module line_buffer #(
    parameter MAX_WIDTH = 256 // Cấp phát cứng BRAM. Để 256 (2^8) cho tối ưu biên dịch, 
                              // đủ sức chứa ảnh 224x224 hoặc 128x128.
)(
    input  wire clk,
    input  wire rst_n,
    input  wire shift_en,
    
    // Tín hiệu này lấy từ thanh ghi S00_AXI (ARM truyền xuống)
    input  wire [9:0] active_width, 
    
    input  wire [7:0] pixel_in,
    output wire [23:0] col_out 
);

    // ========================================================
    // 1. Khai báo mảng bộ nhớ vật lý (Sẽ map vào BRAM)
    // ========================================================
    // Mảng luôn được tạo ra với kích thước MAX_WIDTH (256)
    reg [7:0] row_buf_0 [0:MAX_WIDTH-1]; 
    reg [7:0] row_buf_1 [0:MAX_WIDTH-1];

    // Con trỏ phải đủ bit để trỏ tới MAX_WIDTH
    reg [$clog2(MAX_WIDTH)-1:0] ptr; 

    // ========================================================
    // 2. Logic Đọc liên tục (Asynchronous Read)
    // ========================================================
    wire [7:0] delay_1 = row_buf_0[ptr];
    wire [7:0] delay_2 = row_buf_1[ptr];

    assign col_out = {delay_2, delay_1, pixel_in};

    // ========================================================
    // 3. Logic Ghi & Quay vòng con trỏ linh hoạt (Dynamic Wrap-around)
    // ========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ptr <= '0;
        end 
        else if (shift_en) begin
            // Ghi dữ liệu vào BRAM
            row_buf_0[ptr] <= pixel_in;
            row_buf_1[ptr] <= delay_1;

            // QUAN TRỌNG: Quay vòng con trỏ dựa trên kích thước ARM yêu cầu
            // Ví dụ: ARM cấu hình active_width = 128, thì ptr chạy đến 127 là quay về 0.
            if (ptr == active_width - 1) begin
                ptr <= '0;
            end else begin
                ptr <= ptr + 1'b1;
            end
        end
    end

endmodule