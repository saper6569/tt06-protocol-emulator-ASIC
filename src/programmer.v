/*
 Module: programmer
 Description:
   A serial-to-parallel programming interface module designed to load instruction
   and address words into memory over a simple 2-wire serial protocol (data + enable).

 Protocol & Operation:
   1. Serial Stream:
      - When `program_en` is asserted HIGH, data bits from `program_data` are 
        shifted into an internal shift register LSB-first.
      - A counter tracks the number of received bits during transmission.

   2. Framing & Validation:
      - Transmission ends when `program_en` drops LOW.
      - A full word is validated ONLY if `program_en` transitions from HIGH to LOW
        and exactly `TOTAL_WIDTH` bits (ADDRESS_WIDTH + INSTRUCTION_WIDTH) were shifted in.

   3. Parallel Latch & Memory Write:
      - On a valid frame completion (`full_instruction_flag`), the shift register 
        contents are latched into `data_reg`.
      - Output Data Split:
          - Upper bits [TOTAL_WIDTH-1 : INSTRUCTION_WIDTH] -> `address_out`
          - Lower bits [INSTRUCTION_WIDTH-1 : 0]          -> `instruction_out`
      - Generates a synchronized single-cycle `write_en` pulse to commit the 
        instruction and address to memory.

 Parameters:
   - INSTRUCTION_WIDTH : Bit width of the instruction bus (Default: 8)
   - ADDRESS_WIDTH     : Bit width of the target address bus (Default: 8)

 Ports:
   - clk               : System clock signal
   - rst_n             : Active-LOW global asynchronous reset
   - program_data      : Serial input data line
   - program_en        : Active-HIGH serial transfer enable
   - address_out       : Parallel output driving target memory address
   - instruction_out   : Parallel output driving target instruction memory
   - write_en          : Active-HIGH single-cycle memory write pulse
*/

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
    output wire write_en
);
    localparam TOTAL_WIDTH = ADDRESS_WIDTH + INSTRUCTION_WIDTH;
    localparam COUNT_WIDTH = $clog2(TOTAL_WIDTH + 1);

    // Internal wire declarations for modules
    wire [TOTAL_WIDTH-1:0] shift_reg_out;
    wire [TOTAL_WIDTH-1:0] shift_reg_in;
    wire [TOTAL_WIDTH-1:0] data_reg_out;
    wire [TOTAL_WIDTH-1:0] data_reg_in; // Most significant -> address, Least -> instruction
    wire [COUNT_WIDTH-1:0] bit_count;
    wire prev_program_en;
    wire full_instruction_flag;
    wire write_en_next;
    wire counter_rst_n;
    wire counter_en;

    // Address and Instruction memory output assignments
    assign address_out = data_reg_out[TOTAL_WIDTH-1:INSTRUCTION_WIDTH];
    assign instruction_out = data_reg_out[INSTRUCTION_WIDTH-1:0];  

    // Shift in bit when programming, hold value otherwise
    assign shift_reg_in = program_en ? {shift_reg_out[TOTAL_WIDTH-2:0], program_data} : shift_reg_out;

    // Shift Register for holding data during cycle
    register #(
        .WIDTH(TOTAL_WIDTH)
    ) shift_reg_inst (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(shift_reg_in),
        .data_out(shift_reg_out)
    );

    // Register to track last cycle's program_en
    register #(
        .WIDTH(1)
    ) prev_prog_en_reg (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(program_en),
        .data_out(prev_program_en)
    );

    // Counter stays out of reset during transfer and during the single evaluation cycle after program_en drops
    assign counter_rst_n = rst_n && (program_en || prev_program_en);
    assign counter_en = program_en && (bit_count < TOTAL_WIDTH);

    // Bit Counter for registering when a full instruction has been passed
    counter #(
        .N(COUNT_WIDTH)
    ) bit_counter_inst (
        .clk(clk),
        .rst_n(counter_rst_n),
        .enable(counter_en),
        .count(bit_count)
    );

    // Check for an entire instruction to have been passed program_en fell low 
    // and exactly TOTAL_WIDTH bits were received
    assign full_instruction_flag = prev_program_en && !program_en && (bit_count == TOTAL_WIDTH);

    // Load shift_reg_in when a valid word is complete, hold otherwise
    assign data_reg_in = full_instruction_flag ? shift_reg_out : data_reg_out;

    // Instruction/Address Data Register
    register #(
        .WIDTH(TOTAL_WIDTH)
    ) data_reg (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(data_reg_in),
        .data_out(data_reg_out)
    );

    // Write to memory when the flag goes off
    assign write_en_next = full_instruction_flag;

    // Write Enable Output Register
    register #(
        .WIDTH(1)
    ) write_en_inst (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(write_en_next),
        .data_out(write_en)
    );
endmodule