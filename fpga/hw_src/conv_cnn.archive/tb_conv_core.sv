module tb;

reg clk;
reg rst;
reg start;
wire done;

// Instantiate the controller FSM
conv_core uut (
    .clk(clk),
    .rst(rst),
    .start(start),
    .done(done)
);

// Clock generation
always begin
    #5 clk = ~clk;
end

// Test sequence
initial begin
    // Initialize signals
    clk = 0;
    rst = 0;
    start = 0;

    // Reset the FSM
    rst = 1;
    #10;
    rst = 0;

    // Start the processing
    start = 1;
    #10;
    start = 0;

    // Wait for done signal
    wait(done);
    #10;

    // Finish simulation
    $finish;
end

endmodule
