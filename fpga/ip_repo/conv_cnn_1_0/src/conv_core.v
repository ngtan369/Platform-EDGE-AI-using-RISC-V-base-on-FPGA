module conv_core (
    input wire clk,
    input wire rst,
    input wire start,
    output reg done
);

reg [7:0] counter;

always @(posedge clk) begin
    if (rst) begin
        counter <= 0;
        done <= 0;
    end else begin
        if (start) begin
            counter <= counter + 1;
            if (counter == 100) begin
                done <= 1;
            end
        end else begin
            done <= 0;
            counter <= 0;
        end
    end
end

endmodule