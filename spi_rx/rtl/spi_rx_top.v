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
 *
 * ---------------------------------------------------------------------------
 * HOW THE PIECES FIT TOGETHER
 * ---------------------------------------------------------------------------
 * This file contains no logic of its own; it only wires two modules in series:
 *
 *   mosi, cs_n (pins)                                     processors (x4)
 *        |                                                   ^  ^  ^  ^
 *        v                                                   |  |  |  |
 *  +---------------+  bit_valid/bit_data     +-----------------------------+
 *  | spi_rx_serial |------------------------>|      spi_rx_dispatch        |
 *  | (bits, bytes) |  byte_valid/byte_data   | (what do the bytes mean?)   |
 *  +---------------+------------------------>|  enable, mem_*, data_*,     |
 *                                            |  prog_hold                  |
 *   prog_ok (pin) ---------------------------->                            |
 *                                            +-----------------------------+
 *                                                   |
 *                                                   v crc_valid/crc_id/crc_value
 *                                              to spi_tx_top (reported back
 *                                              to the master over the TX link)
 *
 * Why two modules? Separation of concerns: "serial" only knows about wires
 * and bits (no idea what a command is); "dispatch" only knows about bytes and
 * commands (no idea about cs_n or clocks-per-bit).
 */

module spi_rx_top (
    input wire clk,
    input wire rst_n,           // synchronous, active low

    // From the master (all registered on entry)
    input wire mosi,            // serial data, one bit per clock, MSB first
    input wire cs_n,            // frame select, low while a frame is being sent
    input wire prog_ok,         // PROGRAM CRC matched: release held processors

    // To the processors
    output wire [3:0] enable,       // bit i = 1: processor i runs
    output wire [3:0] mem_we,       // bit i: write strobe for processor i's instruction memory
    output wire [7:0] mem_addr,     // memory address to write (shared by all four)
    output wire [7:0] mem_wdata,    // instruction byte to write (shared by all four)
    output wire data_bit,           // one serial data bit for a processor (shared)
    output wire [3:0] data_valid,   // bit i: data_bit is for processor i this cycle
    output wire [3:0] prog_hold, // processor held in reset; its memory port is ours

    // To spi_tx_top (status word)
    output wire crc_valid,          // one-cycle pulse: a PROGRAM frame just ended
    output wire [1:0] crc_id,       // which processor that frame was for
    output wire [7:0] crc_value     // CRC-8 of the frame, for the master to check
);
    // Internal wires between the two sub-modules (the "bus" in the diagram).
    wire bit_valid;         // a frame bit is present this cycle
    wire bit_data;          // the bit itself
    wire byte_valid;        // that bit finished a byte
    wire [7:0] byte_data;   // the finished byte

    // Stage 1: pins -> bits and bytes.
    // `.port(signal)` connects the sub-module's port (left) to a signal in
    // this module (right).
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

    // Stage 2: bytes -> actions on the processors. Takes the serial stage's
    // outputs as inputs, plus prog_ok straight from the pin, and drives all of
    // this module's outputs.
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
