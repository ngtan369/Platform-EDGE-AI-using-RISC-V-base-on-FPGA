module conv_accel_top (
    input wire clk,
    input wire rst,
    input wire start,
    output wire done
);

wire [7:0] pixel_in;
wire [7:0] pixel_out;

window_3x3 u_window (
    .clk(clk),
    .rst(rst),
    .pixel_in(pixel_in),
    .pixel_out(pixel_out)
);

line_buffer u_line_buffer (
    .clk(clk),
    .rst(rst),
    .pixel_in(pixel_in),
    .pixel_out(pixel_out)
);

pe_mac u_pe_mac (
    .clk(clk),
    .rst(rst),
    .a(pixel_in),
    .b(pixel_out),
    .mac_out(mac_out)
);

controller_fsm u_controller_fsm (
    .clk(clk),
    .rst(rst),
    .start(start),
    .done(done)
);

endmodule
