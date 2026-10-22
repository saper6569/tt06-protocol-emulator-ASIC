module instruction_memory #(
    parameter MEMORY_ADDR_WIDTH = 7,
    parameter INSTRUCTION_WIDTH = 5
)( input wire clk,
    input wire w_en,

    input wire [INSTRUCTION_WIDTH-1:0] data_in,
    input wire [MEMORY_ADDR_WIDTH-1:0] addr,

    output reg [INSTRUCTION_WIDTH-1:0] data
);
    reg [INSTRUCTION_WIDTH-1:0] memory [0:(1 << MEMORY_ADDR_WIDTH)-1];
    // Synchronous read/write memory
    always @(posedge clk) begin
        if (w_en) begin
            memory[addr] <= data_in;
        end
        else begin
            data <= memory[addr];
        end
    end
endmodule
