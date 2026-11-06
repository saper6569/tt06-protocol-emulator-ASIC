/*
 * Receives programs from the programmer FPGA (see fpga_programmer.v).
 *
 * Works like the programmer in src/instruction_programmer.v, except that the
 * other FPGA has its own clock, so a bit is taken on each rising edge of
 * prog_clk. Each complete word is then shifted out into the programmer at one
 * bit per clk.
 *
 * prog_en_n stays low for the whole load, with one {address, instruction}
 * word after another, MSB first. When it rises, an unfinished word is dropped
 * and the processor restarts.
 *
 * A word uses the same shift register on its way in and out, and takes about
 * WORD_WIDTH + 6 clk to reach instruction memory. Rising edges of prog_clk must
 * be at least that far apart, and prog_en_n must stay low that long after the
 * last one.
 *
 * prog_en_n is active low so that a disconnected cable, pulled up at the pin,
 * reads as idle.
 */

module program_receiver #(
    parameter WORD_WIDTH = 16
) (
    input wire clk,
    input wire rst_n,

    // From the other FPGA that acts as programmer
    input wire prog_en_n,
    input wire prog_clk,
    input wire prog_data,

    // To the programmer
    output reg program_en,
    output reg program_data,

    output wire busy, // keep the processor stopped while high
    output wire restart // one-cycle pulse after a load finishes
);
    localparam COUNT_WIDTH = $clog2(WORD_WIDTH + 1);

    // Two-stage synchronizers. Data and clock have the same depth, so data is
    // sampled where the other FPGA saw the rising edge.
    reg [1:0] en_sync;
    reg [1:0] clk_sync;
    reg [1:0] data_sync;
    // Shift register
    reg [WORD_WIDTH-1:0] shift_reg;
    // Counts the number of received bits
    reg [COUNT_WIDTH-1:0] bit_count;
    // Counts the bits left to send to the programmer
    reg [COUNT_WIDTH-1:0] send_count;
    // Previous cycle's program enable and clock
    reg prev_prog_en;
    reg prev_prog_clk;

    wire prog_en = en_sync[1];

    assign busy = prog_en | prev_prog_en;
    assign restart = prev_prog_en & ~prog_en;

    always @(posedge clk) begin
        if (!rst_n) begin
            en_sync <= 2'b00;
            clk_sync <= 2'b00;
            data_sync <= 2'b00;
            shift_reg <= {WORD_WIDTH{1'b0}};
            bit_count <= {COUNT_WIDTH{1'b0}};
            send_count <= {COUNT_WIDTH{1'b0}};
            prev_prog_en <= 1'b0;
            prev_prog_clk <= 1'b0;
            program_en <= 1'b0;
            program_data <= 1'b0;
        end
        else begin
            en_sync <= {en_sync[0], ~prog_en_n};
            clk_sync <= {clk_sync[0], prog_clk};
            data_sync <= {data_sync[0], prog_data};
            // Remember previous prog_en and prog_clk states
            prev_prog_en <= prog_en;
            prev_prog_clk <= clk_sync[1];

            // Send the completed word to the programmer
            program_en <= (send_count != 0);
            if (send_count != 0) begin
                program_data <= shift_reg[WORD_WIDTH-1];
                shift_reg <= {shift_reg[WORD_WIDTH-2:0], 1'b0};
                send_count <= send_count - 1'b1;
            end

            // Receive programming data
            if (!prog_en) begin
                // Drop any unfinished word
                bit_count <= {COUNT_WIDTH{1'b0}};
            end
            else if (clk_sync[1] && !prev_prog_clk) begin
                // Shift in one bit
                shift_reg <= {shift_reg[WORD_WIDTH-2:0], data_sync[1]};
                if (bit_count == WORD_WIDTH - 1) begin
                    bit_count <= {COUNT_WIDTH{1'b0}};
                    send_count <= WORD_WIDTH;
                end
                else begin
                    bit_count <= bit_count + 1'b1;
                end
            end
        end
    end
endmodule
