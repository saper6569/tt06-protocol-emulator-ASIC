module flip_flop (
    input wire clk,
    input wire rst_n, // Active-low reset
    input wire t, // Toggle signal
    output reg q
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q <= 1'b0;
        end else begin
            if (t) begin
                q <= ~q;
            end else begin
                q <= q;
            end
        end
    end
endmodule