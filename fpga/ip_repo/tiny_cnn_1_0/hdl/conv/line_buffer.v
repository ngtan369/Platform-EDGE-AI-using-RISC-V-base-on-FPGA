module line_buffer (
    input wire clk,
    input wire rst,
    input wire [7:0] pixel_in,
    output reg [7:0] pixel_out
);

reg [7:0] buffer [0:2][0:2];

always @(posedge clk) begin
    if (rst) begin
        pixel_out <= 0;
    end else begin
        // Shift the buffer
        buffer[0][0] <= buffer[0][1];
        buffer[0][1] <= buffer[0][2];
        buffer[1][0] <= buffer[1][1];
        buffer[1][1] <= buffer[1][2];
        buffer[2][0] <= buffer[2][1];
        buffer[2][1] <= buffer[2][2];
        // Update the last column with the new pixel
        buffer[0][2] <= pixel_in;
        buffer[1][2] <= pixel_in;
        buffer[2][2] <= pixel_in;
        // Compute the output pixel (e.g., average)
        pixel_out <= (buffer[0][0] + buffer[0][1] + buffer[0][2] +
                      buffer[1][0] + buffer[1][1] + buffer[1][2] +
                      buffer[2][0] + buffer[2][1] + buffer[2][2]) / 9;
    end
end

endmodule
