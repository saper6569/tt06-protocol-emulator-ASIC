module counter #(
    parameter N = 8
)(
    input wire clk, 
    input wire rst_n, // Active-low reset
    input wire enable, 
    output reg [N-1:0] count // Counter output
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= {N{1'b0}}; 
        end else if (enable) begin
            count <= count + 1'b1; 
        end
    end
endmodule