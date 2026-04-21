module conv_core #(
    parameter WIDTH = 128
)(
    input wire clk,
    input wire rst,

    // AXIS input
    input wire [7:0] s_data,
    input wire s_valid,
    output wire s_ready,

    // AXIS output
    output reg [31:0] m_data,
    output reg m_valid,
    input wire m_ready
);

// =====================
// Line buffer (2 dòng)
// =====================
reg [7:0] line0 [0:WIDTH-1];
reg [7:0] line1 [0:WIDTH-1];

reg [7:0] shift_reg0, shift_reg1, shift_reg2;

integer i;
reg [15:0] col;

// =====================
// Kernel (hardcode)
// =====================
wire signed [7:0] k [0:8];

assign k[0]=1; assign k[1]=0; assign k[2]=-1;
assign k[3]=1; assign k[4]=0; assign k[5]=-1;
assign k[6]=1; assign k[7]=0; assign k[8]=-1;

// =====================
// Window pixels
// =====================
reg signed [7:0] w [0:8];

// =====================
// MAC
// =====================
reg signed [31:0] acc;

integer j;

// =====================
// READY logic
// =====================
assign s_ready = m_ready;

// =====================
// MAIN
// =====================
always @(posedge clk) begin
    if (rst) begin
        col <= 0;
        m_valid <= 0;
    end else begin
        if (s_valid && s_ready) begin

            // shift registers
            shift_reg0 <= s_data;
            shift_reg1 <= shift_reg0;
            shift_reg2 <= shift_reg1;

            // line buffer shift
            line1[col] <= line0[col];
            line0[col] <= s_data;

            // build window
            w[0] <= line1[col];
            w[1] <= line1[col+1];
            w[2] <= line1[col+2];

            w[3] <= line0[col];
            w[4] <= line0[col+1];
            w[5] <= line0[col+2];

            w[6] <= shift_reg2;
            w[7] <= shift_reg1;
            w[8] <= shift_reg0;

            // MAC
            acc = 0;
            for (j=0; j<9; j=j+1) begin
                acc = acc + w[j] * k[j];
            end

            // output
            m_data  <= acc;
            m_valid <= 1;

            col <= col + 1;
        end else begin
            m_valid <= 0;
        end
    end
end

endmodule