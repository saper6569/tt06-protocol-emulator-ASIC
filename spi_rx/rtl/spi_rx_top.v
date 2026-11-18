/*
 * Receive link: the serial receiver (pins -> bits and bytes) plus the
 * dispatcher (frames -> actions). See spi_rx/SPEC.md for the protocol.
 *
 * Instruction memory hookup (one single-port SRAM macro per processor):
 *   - While prog_hold[i] is high, processor i is in reset and its SRAM port
 *     belongs to the receiver: addr = mem_addr, din = mem_wdata,
 *     write = mem_we[i]. Otherwise the processor owns the port for fetches.
 *   - Writes are one address per cycle, with all three signals registered and
 *     stable for the whole cycle. The receiver never reads or bulk-clears.
 *
 * crc_valid / crc_id / crc_value go to spi_tx_top's status input. The master
 * reads the CRC from the TX link and answers with prog_ok.
 */

module spi_rx_top (
    input wire clk,
    input wire rst_n,           // synchronous, active low

    // From the master (all registered on entry)
    input wire mosi,
    input wire cs_n,
    input wire prog_ok,         // PROGRAM CRC matched: release held processors

    // To the processors
    output wire [3:0] enable,
    output wire [3:0] mem_we,
    output wire [7:0] mem_addr,
    output wire [7:0] mem_wdata,
    output wire data_bit,
    output wire [3:0] data_valid,
    output wire [3:0] prog_hold, // processor held in reset; its memory port is ours

    // To spi_tx_top (status word)
    output wire crc_valid,
    output wire [1:0] crc_id,
    output wire [7:0] crc_value
);
    wire bit_valid;
    wire bit_data;
    wire byte_valid;
    wire [7:0] byte_data;

    spi_rx_serial serial (
        .clk(clk),
        .rst_n(rst_n),
        .mosi(mosi),
        .cs_n(cs_n),
        .bit_valid(bit_valid),
        .bit_data(bit_data),
        .byte_valid(byte_valid),
        .byte_data(byte_data)
    );

    spi_rx_dispatch dispatch (
        .clk(clk),
        .rst_n(rst_n),
        .bit_valid(bit_valid),
        .bit_data(bit_data),
        .byte_valid(byte_valid),
        .byte_data(byte_data),
        .prog_ok(prog_ok),
        .enable(enable),
        .mem_we(mem_we),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .data_bit(data_bit),
        .data_valid(data_valid),
        .prog_hold(prog_hold),
        .crc_valid(crc_valid),
        .crc_id(crc_id),
        .crc_value(crc_value)
    );
endmodule
