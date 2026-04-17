module pe_mac (
    input wire clk,
    input wire rst,
    input wire [7:0] a,
    input wire [7:0] b,
    output reg [15:0] mac_out
);

always @(posedge clk) begin
    if (rst) begin
        mac_out <= 0;
    end else begin
        mac_out <= mac_out + a * b;
    end
end

endmodule
