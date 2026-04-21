module window_3x3 (
    input wire clk,
    input wire rst,
    input wire [7:0] pixel_in,
    output reg [7:0] pixel_out
);

reg [7:0] window [0:2][0:2];

always @(posedge clk) begin
    if (rst) begin
        pixel_out <= 0;
    end else begin
        // Shift the window
        window[0][0] <= window[0][1];
        window[0][1] <= window[0][2];
        window[1][0] <= window[1][1];
        window[1][1] <= window[1][2];
        window[2][0] <= window[2][1];
        window[2][1] <= window[2][2];
        // Update the last column with the new pixel
        window[0][2] <= pixel_in;
        window[1][2] <= pixel_in;
        window[2][2] <= pixel_in;
        // Compute the output pixel (e.g., average)
        pixel_out <= (window[0][0] + window[0][1] + window[0][2] +
                      window[1][0] + window[1][1] + window[1][2] +
                      window[2][0] + window[2][1] + window[2][2]) / 9;
    end
end

endmodule
