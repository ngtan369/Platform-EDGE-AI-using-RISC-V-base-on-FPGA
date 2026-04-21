module pool (
    input wire clk,
    input wire rst,
    input wire [7:0] pixel_in,
    output wire [7:0] pixel_out
);

reg [7:0] max_pool [0:8];
integer i;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        for (i = 0; i < 9; i = i + 1) begin
            max_pool[i] <= 0;
        end
    end else begin
        // Update the pooling window
        max_pool[0] <= pixel_in;
        max_pool[1] <= max_pool[0];
        max_pool[2] <= max_pool[1];
        max_pool[3] <= max_pool[2];
        max_pool[4] <= max_pool[3];
        max_pool[5] <= max_pool[4];
        max_pool[6] <= max_pool[5];
        max_pool[7] <= max_pool[6];
        max_pool[8] <= max_pool[7];
    end
end

assign pixel_out = max_pool[0];

endmodule
