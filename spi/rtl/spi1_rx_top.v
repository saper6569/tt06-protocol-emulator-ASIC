/*
 * Receive link for a single processor: serial receiver (spi pins -> bytes)
 * and parser (bytes -> actions, io pins -> data bits).
 *
 *   mosi, cs_n --> spi1_rx_serial --> spi1_rx_parser --> enable, mem_*, prog_hold
 *                                          ^   |
 *   prog_ok (pin), io_in[7:0] -------------+   +--> pin_bit, pin_valid,
 *                                                   crc_valid/crc_value
 *                                                   (crc to spi1_tx_top)
 *
 * There is one processor, so there is no id, no arbitration and no routing.
 * See spi1_rx_parser for the frame formats and the pin modes (single ended /
 * differential, push-pull / open-drain).
 *
 * Instruction memory hookup (one single-port SRAM macro):
 *   - While prog_hold is high, the processor is in reset and its SRAM port
 *     belongs to the receiver: addr = mem_addr, din = mem_wdata,
 *     write = mem_we. Otherwise the processor owns the port for fetches.
 */

module spi1_rx_top (
    input wire clk,
    input wire rst_n,           // synchronous, active low

    // From the master
    input wire mosi,            // serial data, one bit per clock, MSB first
    input wire cs_n,            // frame select, low while a frame is being sent
    input wire prog_ok,         // PROGRAM CRC matched: release the processor

    // The 8 io pins, as inputs
    input wire [7:0] io_in,

    // To the processor
    output wire enable,         // 1: processor runs
    output wire mem_we,         // write strobe for instruction memory
    output wire [7:0] mem_addr,
    output wire [7:0] mem_wdata,
    output wire prog_hold,      // processor held in reset; its memory port is ours

    // Countdown values set by TIMER frames
    output wire [15:0] timer1_value,
    output wire [15:0] timer2_value,

    // Received data per io pin
    output wire [7:0] pin_bit,
    output wire [7:0] pin_valid, // bit i: pin_bit[i] is a real bit this cycle
    output wire [7:0] pin_mode,  // bit i: 0 push-pull, 1 open-drain

    // To spi1_tx_top (status word)
    output wire crc_valid,      // one-cycle pulse: a PROGRAM frame just ended
    output wire [7:0] crc_value // CRC-8 of the frame, for the master to check
);
    wire bit_valid;
    wire bit_data;
    wire byte_valid;
    wire [7:0] byte_data;

    spi1_rx_serial serial (
        .clk(clk),
        .rst_n(rst_n),
        .mosi(mosi),
        .cs_n(cs_n),
        .bit_valid(bit_valid),
        .bit_data(bit_data),
        .byte_valid(byte_valid),
        .byte_data(byte_data)
    );

    spi1_rx_parser parser (
        .clk(clk),
        .rst_n(rst_n),
        .bit_valid(bit_valid),
        .byte_valid(byte_valid),
        .byte_data(byte_data),
        .prog_ok(prog_ok),
        .enable(enable),
        .mem_we(mem_we),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .prog_hold(prog_hold),
        .timer1_value(timer1_value),
        .timer2_value(timer2_value),
        .io_in(io_in),
        .pin_bit(pin_bit),
        .pin_valid(pin_valid),
        .pin_mode(pin_mode),
        .crc_valid(crc_valid),
        .crc_value(crc_value)
    );
endmodule
