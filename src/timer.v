// One-shot down counter for the WAIT N instruction.
// Pulse `start` for one cycle with N on `wait_cycles`; `done` goes high
// N+1 cycles later (WAIT 0 = 1 cycle). Holding `start` high keeps
// reloading, so `done` never rises. Synchronous active-low reset.
module timer #(
    parameter N = 6
)(
    input wire clk,
    input wire rst_n,
    input wire start, // Active-high start signal
    input wire [N-1:0] wait_cycles, // Number of clock cycles to wait
    output wire done //timer output
);

    reg [N-1:0] count;
    always @(posedge clk) begin
        if(!rst_n) begin
            count <= 0;    //resets the timer if reset is pressed
        end
        else if(start) begin //if start is high
            count <= wait_cycles; //sets the count to wait the imputted amount of cycles
        end
        else if(count != 0) begin
            count <= count - 1'b1; 
        end
        else begin
            count <= count; //just wait at 0
        end
    end
    //!start because in start cycle, count holds 0 until clk edge
    //which would skip wait
    assign done = (count == 0) && !start; 
endmodule