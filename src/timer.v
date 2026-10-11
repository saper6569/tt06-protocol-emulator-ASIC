// set curr count = 0 decrease by 1 every cycle
// when curr count == 0 set flag bit then copy  total count into curr count
//required procesor to set total count and enable counting
// flag signals processor to move onto next instruction

module timer #(
    parameter WIDTH = 32
)
(
    input clk,
    input rst_n,
    input [WIDTH-1:0] total_count,
    input wire count_enable,
    output reg flag
);
    reg [WIDTH-1:0] curr_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curr_count <= {WIDTH{1'b0}};
            flag <= 1'b0;
        end else begin
            if (count_enable) begin
                if (curr_count == {WIDTH{1'b0}}) begin
                    flag <= 1'b1; // Set flag when count reaches zero
                    curr_count <= total_count; // Reload total count
                end else begin
                    curr_count <= curr_count - 1; // Decrease count
                    flag <= 1'b0; // Clear flag when counting down
                end
            end 
        end
    end