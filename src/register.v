
module register #(
    parameter WIDTH = 8
)(
    input wire clk,    
    input wire rst_n, // Active-low reset
    input wire [WIDTH-1:0] data_in, 
    output reg [WIDTH-1:0] data_out 
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= {WIDTH{1'b0}};
        end else begin
            data_out <= data_in;
        end
    end
endmodule