

module cpu_wrapper(
    input wire clk,
    input wire rst,
    input wire [31:0] instr,
    output wire [31:0] pc,
    output wire [31:0] alu_result
);

    // Instantiate the CPU core
    cpu cpu_core (
        .clk(clk),
        .rst(rst),
        .instr(instr),
        .pc(pc),
        .alu_result(alu_result)
    );

endmodule