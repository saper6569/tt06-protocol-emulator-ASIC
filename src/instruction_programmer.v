module programmer #(
    parameter INSTRUCTION_WIDTH = 8,
    parameter ADDRESS_WIDTH = 8
)(
    input wire clk,
    input wire rst_n,

    // 2-wire programming interface
    input wire program_data,
    input wire program_en,

    // Interface to instruction memory
    output wire [ADDRESS_WIDTH-1:0] address_out,
    output wire [INSTRUCTION_WIDTH-1:0] instruction_out,
    output reg write_en
);

    localparam TOTAL_WIDTH = ADDRESS_WIDTH + INSTRUCTION_WIDTH;
    localparam COUNT_WIDTH = $clog2(TOTAL_WIDTH + 1);

    // Shift register
    reg [TOTAL_WIDTH-1:0] shift_reg;
    // Holds the completed address + instruction
    reg [TOTAL_WIDTH-1:0] data_reg;
    // Counts the number of received bits
    reg [COUNT_WIDTH-1:0] bit_count;
    // Previous cycle's program enable
    reg prev_program_en;

    // Address and instruction outputs
    assign address_out = data_reg[TOTAL_WIDTH-1:INSTRUCTION_WIDTH];
    assign instruction_out = data_reg[INSTRUCTION_WIDTH-1:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            shift_reg <= {TOTAL_WIDTH{1'b0}};
            data_reg <= {TOTAL_WIDTH{1'b0}};
            bit_count <= {COUNT_WIDTH{1'b0}};
            prev_program_en <= 1'b0;
            write_en <= 1'b0;
        end
        else begin
            // write enable is only active for one cycle
            write_en <= 1'b0;
            // Remember previous program_en state
            prev_program_en <= program_en;
            // Receive programming data
            if (program_en) begin
                // Shift in one bit
                if (bit_count < TOTAL_WIDTH) begin
                    shift_reg <= {
                        shift_reg[TOTAL_WIDTH-2:0],
                        program_data
                    };
                    bit_count <= bit_count + 1'b1;
                end
            end

            // program_en has just gone low
            if (prev_program_en && !program_en) begin
                // Check that exactly one complete word was received
                if (bit_count == TOTAL_WIDTH) begin
                    data_reg <= shift_reg;
                    write_en <= 1'b1;
                end
                // Reset counter for next word to be programmed
                bit_count <= {COUNT_WIDTH{1'b0}};
            end
        end
    end
endmodule
