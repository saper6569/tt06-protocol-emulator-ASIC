module counter #(
    parameter N = 8
)(
    input wire clk, 
    input wire reset_n, // Active-low reset
    input wire enable, 
    output reg [N-1:0] count // Counter output
);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            count <= {N{1'b0}}; 
        end else if (enable) begin
            count <= count + 1'b1; 
        end
    end
endmodule