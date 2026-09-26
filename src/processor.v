module processor #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD_RATE = 115_200,
    parameter IO_PORTS = 8,
    parameter MEMORY_WIDTH = 8,
    parameter MEMORY_ADDR_WIDTH = 8,
    parameter MEMORY_SIZE = 1 << MEMORY_ADDR_WIDTH,
    parameter SHIFT_REG_WIDTH = 8,
    parameter 
) 
(
    // Input
    input wire clk,
    input wire reset,
    input wire uart_rx,
    input wire [IO_PORTS-1:0] io_in,
    input wire [MEMORY_WIDTH-1:0] mem_in,
    output wire [MEMORY_WIDTH-1:0] mem_out,
    input wire [IO_PORTS-1:0] io_out,
    
    // Output
    output wire uart_tx,
    output wire [IO_PORTS-1:0] io_out,
    output wire [MEMORY_WIDTH-1:0] mem_out,
    output wire [SHIFT_REG_WIDTH-1:0] shift_reg_out,
    output wire [MEMORY_ADDR_WIDTH-1:0] mem_addr_out
);