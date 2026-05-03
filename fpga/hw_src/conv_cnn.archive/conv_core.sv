// Tên file: conv_core.sv
// Chức năng: Trái tim của Hardware Accelerator. G�?i FSM, Line Buffer và mảng 9 con MAC.

module conv_core (
    input  wire clk,
    input  wire rst_n,

    // Cấu hình từ ARM (AXI-Lite)
    input  wire [9:0] active_width, // Kích thước ảnh (vd: 128 hoặc 224)
    input  wire [9:0] num_cin,      // Số kênh đầu vào
    input  wire       pool_en,
    input  wire       start,
    // Luồng Tr�?ng số (Weights) từ BRAM nội bộ
    input  wire signed [7:0] w00, w01, w02,
    input  wire signed [7:0] w10, w11, w12,
    input  wire signed [7:0] w20, w21, w22,

    // Giao tiếp AXI-Stream IN (Nhận ảnh từ DMA)
    input  wire [7:0] s_data,
    input  wire       s_valid,
    output wire       s_ready,

    // Giao tiếp AXI-Stream OUT (Trả kết quả)
    output reg  [7:0] m_data, // Lưu ý: �?ã ép v�? INT8 thay vì 32-bit
    output wire       m_valid,
    input  wire       m_ready,
    output wire       done
);

    // =====================================
    // 1. Dây dẫn nội bộ
    // =====================================
    wire mac_en, acc_clear, bias_relu_en;
    wire [23:0] col_pixels;
    wire signed [7:0] p00, p01, p02, p10, p11, p12, p20, p21, p22;
    wire signed [31:0] mac_out [0:8]; // Lối ra của 9 con PE_MAC

    // Sẵn sàng nhận dữ liệu khi luồng ra cũng sẵn sàng
    assign s_ready = m_ready; 

    // =====================================
    // 2. G�?i Máy Trạng Thái (FSM)
    // =====================================
controller_fsm u_fsm (
        .clk          (clk),
        .rst_n        (rst_n),
        
        // S? K?T H?P HO�N H?O: L?nh t? CPU & D? li?u t? DMA
        .start        (start & s_valid & s_ready), 
        
        .num_cin      (num_cin),
        .acc_clear    (acc_clear),
        .mac_en       (mac_en),
        .bias_relu_en (bias_relu_en),
        .out_valid    (), // C? t?m tr�?c khi qua MUX
        .done         (done)             // B�o v? cho CPU
    );

    // =====================================
    // 3. G�?i Bộ �?ệm Dòng (Line Buffer)
    // =====================================
    line_buffer u_line_buf (
        .clk          (clk),
        .rst_n        (rst_n),
        .shift_en     (s_valid && s_ready),
        .active_width (active_width),
        .pixel_in     (s_data),
        .col_out      (col_pixels) // Ra 1 cột 3 pixel
    );

    // =====================================
    // 4. Tạo Cửa Sổ 3x3 (Window Buffer)
    // =====================================
    // Nhiệm vụ của nó là nhận col_pixels và dịch ngang để tạo 9 pixel
    window_3x3 u_window (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (s_valid && s_ready),
        .col_in   (col_pixels),
        .p00(p00), .p01(p01), .p02(p02),
        .p10(p10), .p11(p11), .p12(p12),
        .p20(p20), .p21(p21), .p22(p22)
    );

    // =====================================
    // 5. Mảng Tính Toán: 9 con PE_MAC
    // =====================================
    // Dùng generate block để tự động đẻ ra 9 module pe_mac
    // Cực kỳ ngầu và chuẩn Verilog
    generate
        genvar i;
        // Gom pixel và weight vào mảng để xài vòng lặp cho tiện
        wire signed [7:0] P_arr [0:8] = '{p00, p01, p02, p10, p11, p12, p20, p21, p22};
        wire signed [7:0] W_arr [0:8] = '{w00, w01, w02, w10, w11, w12, w20, w21, w22};

        for (i = 0; i < 9; i = i + 1) begin : mac_array
            pe_mac u_mac (
                .clk     (clk),
                .rst_n   (rst_n),
                .clr     (acc_clear),
                .en      (mac_en),
                .a       (P_arr[i]),
                .b       (W_arr[i]),
                .acc_out (mac_out[i])
            );
        end
    endgenerate

    // =====================================
    // 6. Cây Cộng Dồn (Adder Tree) & Ép Kiểu (Requantize/ReLU)
    // =====================================
    // Cộng 9 kết quả lại (Phần này Vivado sẽ tự đưa vào DSP hoặc LUT tùy ý)
    reg signed [31:0] total_sum;
    reg [7:0] conv_relu_out;   // <--- Khai b�o d�y trung gian
    reg       conv_relu_valid; // <--- Khai b�o c? valid trung gian
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            conv_relu_valid <= 1'b0;
            conv_relu_out   <= 8'd0;
        end else begin
            conv_relu_valid <= bias_relu_en; // Tr? 1 nh?p so v?i m?ch c?ng    
            if (bias_relu_en) begin
                total_sum <= mac_out[0] + mac_out[1] + mac_out[2] + 
                         mac_out[3] + mac_out[4] + mac_out[5] + 
                         mac_out[6] + mac_out[7] + mac_out[8];
                         
            // Hàm ReLU và ép v�? INT8 (Giả sử scale factor đơn giản là cắt bit)
            if (total_sum < 0) begin
                m_data <= 8'd0; // ReLU
            end else begin
                // Lấy 8 bit hợp lý (cắt bớt bit dư thừa chống tràn)
                // Chú ý: Phần này phụ thuộc vào công thức Quantization của bạn
                m_data <= (total_sum > 255) ? 8'd255 : total_sum[7:0]; 
            end
        end
        end 
        end
// =====================================
    // 7. G?i MAX POOLING & MUX XU?T D? LI?U
    // =====================================
    wire [7:0] pool_out;
    wire       pool_valid;

    max_pool_2x2 u_max_pool (
        .clk          (clk),
        .rst_n        (rst_n),
        .en           (conv_relu_valid), // H? Conv t�nh xong 1 pixel th? nh�t v�o Pool
        .active_width (active_width),
        .pixel_in     (conv_relu_out),
        .pixel_out    (pool_out),
        .out_valid    (pool_valid)
    );

    // MUX: N?u ARM b?t pool_en = 1 -> L?y k?t qu? t? max_pool
    //      N?u ARM t?t pool_en = 0 -> L?y k?t qu? tr?c ti?p t? m?ch Conv
    assign m_data  = pool_en ? pool_out   : conv_relu_out;
    assign m_valid = pool_en ? pool_valid : conv_relu_valid;
endmodule