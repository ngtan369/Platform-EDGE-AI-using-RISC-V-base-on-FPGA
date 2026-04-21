// FSM phải có thêm một vòng lặp đếm số kênh đầu vào ($C_{in}$). 
// Nó sẽ cộng dồn kết quả MAC của từng kênh lại với nhau. 
// Khi nào quét đủ $C_{in}$ kênh, nó mới cộng thêm Bias, cho qua ReLU và đẩy ra ngoài.

module controller_fsm (
    input wire clk,
    input wire rst,
    input wire start,
    output reg done
);

typedef enum reg [1:0] {
    IDLE,
    PROCESSING,
    DONE
} state_t;

state_t current_state, next_state;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        current_state <= IDLE;
    end else begin
        current_state <= next_state;
    end
end

always @(*) begin
    case (current_state)
        IDLE: begin
            if (start) begin
                next_state = PROCESSING;
            end else begin
                next_state = IDLE;
            end
        end
        PROCESSING: begin
            if (done) begin
                next_state = DONE;
            end else begin
                next_state = PROCESSING;
            end
        end
        DONE: begin
            next_state = IDLE;
        end
    endcase
end

endmodule
