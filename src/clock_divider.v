module clock #(
    parameter COUNT_BITS = 16, // Number of bits for the counter 
    parameter COUNT = 1 << COUNT_BITS
)(
    input wire clk_in,
    input wire rst_n,
    input reg clk_en,
    input reg [COUNT_BITS-1:0] count,
    output reg clk_out_pulse
);

    reg [COUNT_BITS-1:0] counter;

    always @(posedge clk_in) begin
        if (!rst_n) begin
            counter <= 0;
            clk_en <= 0;
            clk_out_pulse <= 0;
        end else begin
            if (clk_en) begin
                if (counter == count - 1) begin
                    counter <= 0;
                    clk_out_pulse <= 1;
                end else begin
                    counter <= counter + 1;
                    clk_out_pulse <= 0;
                end
            end
        end
    end
endmodule