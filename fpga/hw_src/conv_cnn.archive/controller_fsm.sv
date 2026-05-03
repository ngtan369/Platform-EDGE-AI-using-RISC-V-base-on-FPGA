// file: controller_fsm.sv
// Chức năng: Điều phối luồng dữ liệu 4 vòng lặp (C_out, Y, X, C_in) cho Standard Convolution

module controller_fsm (
    input  wire clk,
    input  wire rst_n,            // Reset tích cực mức thấp (chuẩn AXI)
    input  wire start,            // Lệnh Start từ thanh ghi S00_AXI (ARM)
    
    // Cấu hình mạng từ ARM (thông qua AXI-Lite)
    input  wire [9:0] num_cin,    // Số kênh đầu vào (C_in)
    input  wire [9:0] num_cout,   // Số kênh đầu ra (C_out)
    input  wire [9:0] width,      // Chiều rộng Feature Map
    input  wire [9:0] height,     // Chiều cao Feature Map

    // Tín hiệu điều khiển Datapath (xuất ra cho conv_core)
    output reg  acc_clear,        // Lệnh xóa thanh ghi cộng dồn (bắt đầu pixel mới)
    output reg  mac_en,           // Cho phép khối PE tính MAC
    output reg  bias_relu_en,     // Lệnh cộng Bias và tính ReLU
    output reg  out_valid,        // Cờ báo kết quả pixel đã tính xong, đẩy ra AXI-Stream
    output reg  done              // Báo cho ARM biết đã chạy xong toàn bộ Layer
);

    // 1. Định nghĩa các Trạng thái (FSM States)
    typedef enum logic [2:0] {
        IDLE,             // Chờ ARM ra lệnh
        INIT_PIXEL,       // Khởi tạo tính toán 1 pixel mới (Xóa Accumulator)
        CALC_CIN,         // Vòng lặp trong cùng: Quét C_in và cộng dồn MAC
        APPLY_ACTIVATION, // Đã quét đủ C_in -> Cộng Bias, qua ReLU và đẩy ra
        NEXT_COORD,       // Tăng bộ đếm tọa độ (X, Y) hoặc chuyển sang C_out tiếp theo
        DONE_STATE        // Hoàn thành Layer
    } state_t;

    state_t current_state, next_state;

    // 2. Định nghĩa các Bộ đếm (Counters)
    reg [9:0] cnt_cin;
    reg [9:0] cnt_cout;
    reg [9:0] cnt_x;
    reg [9:0] cnt_y;

    // Logic cập nhật trạng thái FSM (Sequential)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= IDLE;
        end else begin
            current_state <= next_state;
        end
    end

    // 3. Logic chuyển trạng thái (Combinational)
    always_comb begin
        // Mặc định các tín hiệu điều khiển để tránh sinh chốt (latch)
        next_state   = current_state;
        acc_clear    = 1'b0;
        mac_en       = 1'b0;
        bias_relu_en = 1'b0;
        out_valid    = 1'b0;
        done         = 1'b0;

        case (current_state)
            IDLE: begin
                done = 1'b1; // Báo rảnh
                if (start) begin
                    next_state = INIT_PIXEL;
                    done = 1'b0;
                end
            end

            INIT_PIXEL: begin
                acc_clear  = 1'b1; // Xóa sạch rác trong Accumulator trước khi tính
                next_state = CALC_CIN;
            end

            CALC_CIN: begin
                mac_en = 1'b1;     // Kích hoạt bộ nhân cộng 3x3 chạy
                
                // Giả sử MAC cần 1 chu kỳ để tính và cộng dồn (Pipeline)
                if (cnt_cin == num_cin - 1) begin
                    next_state = APPLY_ACTIVATION; // Đã quét xong C_in cuối cùng
                end else begin
                    next_state = CALC_CIN;         // Tiếp tục quay vòng
                end
            end

            APPLY_ACTIVATION: begin
                bias_relu_en = 1'b1; // Kích hoạt cộng Bias và so sánh ReLU
                out_valid    = 1'b1; // Kết quả INT8 lúc này đã chốt, báo M00_AXIS lấy đi
                next_state   = NEXT_COORD;
            end

            NEXT_COORD: begin
                // Trạng thái này đóng vai trò như một nhịp trễ để hệ thống Stream lấy data
                // và kiểm tra xem đã duyệt hết toàn bộ ảnh chưa.
                if (cnt_cout == num_cout - 1 && cnt_y == height - 1 && cnt_x == width - 1) begin
                    next_state = DONE_STATE; // Đã xong khối lượng công việc
                end else begin
                    next_state = INIT_PIXEL; // Vòng lại tính pixel tiếp theo
                end
            end

            DONE_STATE: begin
                done = 1'b1;
                if (!start) begin // Đợi ARM hạ cờ start xuống mới về IDLE
                    next_state = IDLE;
                end
            end
            
            default: next_state = IDLE;
        endcase
    end

    // 4. Logic quản lý các Bộ đếm (Counters)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_cin  <= '0;
            cnt_cout <= '0;
            cnt_x    <= '0;
            cnt_y    <= '0;
        end else if (current_state == IDLE) begin
            cnt_cin  <= '0;
            cnt_cout <= '0;
            cnt_x    <= '0;
            cnt_y    <= '0;
        end else if (current_state == CALC_CIN) begin
            // Đếm số kênh đầu vào
            if (cnt_cin == num_cin - 1) begin
                cnt_cin <= '0;
            end else begin
                cnt_cin <= cnt_cin + 1'b1;
            end
        end else if (current_state == NEXT_COORD) begin
            // Logic lồng vòng lặp X -> Y -> C_out
            if (cnt_x == width - 1) begin
                cnt_x <= '0;
                if (cnt_y == height - 1) begin
                    cnt_y <= '0;
                    if (cnt_cout == num_cout - 1) begin
                        cnt_cout <= '0;
                    end else begin
                        cnt_cout <= cnt_cout + 1'b1;
                    end
                end else begin
                    cnt_y <= cnt_y + 1'b1;
                end
            end else begin
                cnt_x <= cnt_x + 1'b1;
            end
        end
    end

endmodule