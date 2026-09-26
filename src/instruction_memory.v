module instruction_memory #(
    parameter ADDR_WIDTH = 7, // 2^7 = 128 instructions
    parameter DATA_WIDTH = 8 // 2 bit opcode + 6 bit data
)(
    input wire clk,
    input wire [ADDR_WIDTH-1:0] addr,
    output reg [DATA_WIDTH-1:0] data
);
    reg [DATA_WIDTH-1:0] memory [0:(1 << ADDR_WIDTH)-1];

    // Instruction memory read
    always @(posedge clk) begin
        data <= memory[addr];
    end

endmodule