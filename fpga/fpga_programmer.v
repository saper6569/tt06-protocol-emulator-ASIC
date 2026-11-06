/*
 * Top level of the programmer FPGA, a separate board that loads a program into
 * the processor FPGA.
 *
 * The instruction list is the text file PROGRAM_FILE (see fpga/instructions.txt).
 * Pressing start sends the whole list to program_receiver on the processor FPGA:
 * prog_en_n stays low while every address is sent in order as one
 * {address, instruction} word, MSB first. prog_data changes while prog_clk is
 * low, so it is stable on the rising edge. Addresses the file does not set are
 * sent as zero, so nothing from an earlier program is left behind.
 */

module fpga_programmer #(
    parameter PROGRAM_FILE = "../instructions.txt",
    parameter ADDRESS_WIDTH = 8,
    parameter INSTRUCTION_WIDTH = 8,
    parameter HALF_BIT_CYCLES = 25 // 1 Mbit/s from 50 MHz.
) (
    input wire clk,
    input wire start_n, // button, active low

    output reg prog_en_n = 1'b1,
    output reg prog_clk = 1'b0,
    output reg prog_data = 1'b0,

    output reg done = 1'b0 // set once a list has been sent
);
    localparam WORD_WIDTH = ADDRESS_WIDTH + INSTRUCTION_WIDTH;
    localparam LIST_LENGTH = 1 << ADDRESS_WIDTH;
    localparam BIT_INDEX_WIDTH = $clog2(WORD_WIDTH);
    localparam DELAY_WIDTH = $clog2(HALF_BIT_CYCLES);

    reg [INSTRUCTION_WIDTH-1:0] instruction_list [0:LIST_LENGTH-1];

    integer i;
    initial begin
        for (i = 0; i < LIST_LENGTH; i = i + 1)
            instruction_list[i] = {INSTRUCTION_WIDTH{1'b0}};
        $readmemb(PROGRAM_FILE, instruction_list);
    end

    reg [ADDRESS_WIDTH-1:0] address = {ADDRESS_WIDTH{1'b0}};
    reg [BIT_INDEX_WIDTH-1:0] bit_index = WORD_WIDTH - 1;
    reg [DELAY_WIDTH-1:0] delay = {DELAY_WIDTH{1'b0}};
    reg [INSTRUCTION_WIDTH-1:0] instruction;
    reg [2:0] start_sync = 3'b111;

    wire start_pressed = ~start_sync[1] & start_sync[2];

    wire [WORD_WIDTH-1:0] word = {address, instruction};

    always @(posedge clk) begin
        start_sync <= {start_sync[1:0], start_n};
        instruction <= instruction_list[address];
        prog_data <= word[bit_index];

        if (prog_en_n) begin
            if (start_pressed) begin
                prog_en_n <= 1'b0;
                done <= 1'b0;
                delay <= HALF_BIT_CYCLES - 1;
            end
        end
        else if (delay != 0) begin
            delay <= delay - 1'b1;
        end
        else begin
            delay <= HALF_BIT_CYCLES - 1;
            if (done) begin
                // The last word is out, end the load
                prog_en_n <= 1'b1;
            end
            else begin
                prog_clk <= ~prog_clk;
                // prog_clk is falling, move on to the next bit
                if (prog_clk) begin
                    if (bit_index != 0) begin
                        bit_index <= bit_index - 1'b1;
                    end
                    else begin
                        bit_index <= WORD_WIDTH - 1;
                        address <= address + 1'b1;
                        done <= &address;
                    end
                end
            end
        end
    end
endmodule
