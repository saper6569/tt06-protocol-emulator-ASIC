/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_example #(
    parameter INSTRUCTION_WIDTH = 5,
    parameter INSTRUCTION_MEMORY_ADDR_WIDTH = 7,
    parameter COUNTER_BITS = 11,
    parameter CLK_PERIOD_NS = 20,
    parameter TICK_CYCLES = 1
) (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);
    localparam IO_PORTS = 4;

    // ui_in[7:6] form a serial programming interface. Hold ui_in[7] high
    // Shift an INSTRUCTION_MEMORY_ADDR_WIDTH-bit address followed by an
    // INSTRUCTION_WIDTH-bit instruction, MSB first.
    // ui_in[5] must be high to run the processor.
    wire program_en = ui_in[7];
    wire program_data = ui_in[6];
    reg previous_program_en;

    wire [INSTRUCTION_MEMORY_ADDR_WIDTH-1:0] program_address;
    wire [INSTRUCTION_WIDTH-1:0] program_instruction;
    wire program_write_en;
    wire [INSTRUCTION_MEMORY_ADDR_WIDTH-1:0] processor_address;
    wire [INSTRUCTION_WIDTH-1:0] instruction_data;
    wire [INSTRUCTION_MEMORY_ADDR_WIDTH-1:0] memory_address =
        program_write_en ? program_address : processor_address;
    wire programming_mode =
        program_en | previous_program_en | program_write_en | ~ui_in[5];

    wire [IO_PORTS-1:0] gpio_mode;
    wire [IO_PORTS-1:0] gpio_write_en;
    wire [IO_PORTS-1:0] gpio_out;

    always @(posedge clk) begin
        if (!rst_n)
            previous_program_en <= 1'b0;
        else
            previous_program_en <= program_en;
    end

    programmer #(
        .INSTRUCTION_WIDTH(INSTRUCTION_WIDTH),
        .ADDRESS_WIDTH(INSTRUCTION_MEMORY_ADDR_WIDTH)
    ) programmer_inst (
        .clk(clk),
        .rst_n(rst_n),
        .program_data(program_data),
        .program_en(program_en),
        .address_out(program_address),
        .instruction_out(program_instruction),
        .write_en(program_write_en)
    );

    instruction_memory #(
        .MEMORY_ADDR_WIDTH(INSTRUCTION_MEMORY_ADDR_WIDTH),
        .INSTRUCTION_WIDTH(INSTRUCTION_WIDTH)
    ) instruction_memory_inst (
        .clk(clk),
        .w_en(program_write_en),
        .data_in(program_instruction),
        .addr(memory_address),
        .data(instruction_data)
    );

    processor #(
        .INSTRUCTION_WIDTH(INSTRUCTION_WIDTH),
        .IO_PORTS(IO_PORTS),
        .MEMORY_ADDR_WIDTH(INSTRUCTION_MEMORY_ADDR_WIDTH),
        .COUNTER_BITS(COUNTER_BITS),
        .CLK_PERIOD_NS(CLK_PERIOD_NS),
        .TICK_CYCLES(TICK_CYCLES)
    ) processor_inst (
        .clk(clk),
        .rst_n(rst_n),
        .programming_mode(programming_mode),
        .mem_data_in(instruction_data),
        .mem_write_en(),
        .mem_addr_out(processor_address),
        .mem_data_out(),
        .gpio_mode(gpio_mode),
        .gpio_write_en(gpio_write_en),
        .gpio_out(gpio_out),
        .gpio_in(uio_in[IO_PORTS-1:0])
    );

    io_port #(
        .GPIO_WIDTH(8)
    ) gpio_inst (
        .gpio_out({4'b0000, gpio_out}),
        .write_en({4'b0000, gpio_write_en}),
        .gpio_mode({4'b0000, gpio_mode}),
        .gpio_in(uio_in),
        .gpio_pad_out(uio_out),
        .gpio_pad_oe(uio_oe)
    );

    generate
        if (INSTRUCTION_MEMORY_ADDR_WIDTH < 8) begin : g_pad_address_output
            assign uo_out = {
                {(8-INSTRUCTION_MEMORY_ADDR_WIDTH){1'b0}},
                processor_address
            };
        end else begin : g_truncate_address_output
            assign uo_out = processor_address[7:0];
        end
    endgenerate
    wire _unused = &{ena, ui_in[4:0], 1'b0};

endmodule
