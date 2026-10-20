/**
 * 
 * A parameterizable countdown timer that loads a specified number of wait 
 * cycles upon an active-high start signal and asserts a 'done' pulse once 
 * the countdown completes.
 */

module timer #(
    parameter WIDTH = 16
)(
    input wire clk,
    input wire rst_n,
    input wire enable,
    input wire start, // Active-high start signal
    input wire [WIDTH-1:0] wait_cycles, // Number of clock cycles to wait
    output wire done //timer output
);

    reg [WIDTH-1:0] count;
    always @(posedge clk) begin
        if(!rst_n) begin
            count <= 0;    // Resets the timer
        end
        else if (enable && start) begin
            count <= wait_cycles; // Loads the wait cycles
        end
        else if (enable && count != 0) begin
            count <= count - 1'b1; // Decrements count down to 0
        end
    end
    // Done is high only when count reaches 0 and we aren't actively starting/reloading
    assign done = (count == 0) && !start;
endmodule
