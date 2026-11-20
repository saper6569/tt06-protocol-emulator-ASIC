/*
 * Transmit link for a single processor: one FIFO plus CRC status reports share
 * one serial link back to the master. No arbiter is needed.
 *
 *   processor --push--> fifo ---------+
 *                                     +--> spi1_tx_serial --> tx_cs_n, miso
 *   spi1_rx CRC report --> status fifo (always first)
 *
 * Word on the wire, 11 bits, MSB first:
 *     {io[2:0], data[7:0]}
 *     io says which of the 8 io pins the byte came from (the processor
 *     supplies tx_io with each push).
 *
 * There is no status bit. The CRC report is a word with io = 0 whose data is
 * the CRC-8 of the PROGRAM frame just received (from spi1_rx). The master
 * knows it just sent a PROGRAM frame, so the next word is the CRC, and it
 * answers with prog_ok. To keep that unambiguous, no processor word is
 * started while prog_hold is high (the processor is in reset anyway); words
 * already in the FIFO wait until prog_ok releases the processor. The master
 * should not start a PROGRAM frame while a processor word may still be on the
 * wire (e.g. send IDLE first, or use tx_hold, and let the link drain).
 *
 * Order: a waiting CRC word always goes next, then the processor FIFO.
 *
 * tx_hold (pin, from the master): while high, no new word starts. A word
 * already being sent finishes. Words wait in the FIFO meanwhile, so a long
 * hold fills it and the processor sees tx_full.
 *
 * Full FIFO: tx_full goes back to the processor. A push while full is ignored
 * by the FIFO, so the processor must wait while tx_full is high.
 *
 * Example words:
 *   Byte 0x41 from io pin 5:  {101, 01000001}
 *   CRC report, crc 0xF4:     {000, 11110100}
 */

module spi1_tx_top #(
    parameter FIFO_SIZE = 4,    // words buffered
    parameter STATUS_SIZE = 2   // status words buffered
) (
    input wire clk,
    input wire rst_n,           // synchronous, active low

    // From the processor
    input wire tx_push,         // push {tx_io, tx_data} this cycle
    input wire [2:0] tx_io,     // which io pin the byte came from
    input wire [7:0] tx_data,
    output wire tx_full,        // FIFO is full; wait before pushing

    // From spi1_rx_top
    input wire prog_hold,       // processor is being programmed: send only the CRC
    input wire status_valid,    // CRC report: one-cycle pulse at the end of each PROGRAM frame
    input wire [7:0] status_data,

    // To / from the master
    input wire tx_hold,         // pin: 1 = don't start a new word
    output wire tx_cs_n,
    output wire miso
);
    // tx_hold is a pin: register it so it only has a pin -> flop path. Not
    // reset, so it follows the pin during reset too.
    reg tx_hold_q;
    always @(posedge clk) tx_hold_q <= tx_hold;

    // ---- Processor FIFO, entries are {io, data} ----
    // 11 bits wide so a word keeps its io pin number with its data byte.
    // The processor pushes; the serializer pops through the arbiter-free
    // selection below. data_out always shows the oldest entry (it is only
    // meaningful while the FIFO is not empty).    wire fifo_empty;
    wire fifo_pop;
    wire [10:0] fifo_out;

    fifo #(
        .WIDTH(11),
        .SIZE(FIFO_SIZE)
    ) tx_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .push(tx_push),
        .pop(fifo_pop),
        .data_in({tx_io, tx_data}),
        .data_out(fifo_out),
        .full(tx_full),
        .empty(fifo_empty)
    );

    // ---- Status words from the receive link ----
    // A small separate FIFO for CRC reports, so a CRC is never stuck behind
    // processor data. full is left unconnected: a report that does not fit is
    // dropped, which cannot happen in practice because the master answers each
    // CRC with prog_ok before sending another PROGRAM frame.    wire status_empty;
    wire status_pop;
    wire [7:0] status_out;

    fifo #(
        .WIDTH(8),
        .SIZE(STATUS_SIZE)
    ) status_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .push(status_valid),
        .pop(status_pop),
        .data_in(status_data),
        .data_out(status_out),
        .full(),
        .empty(status_empty)
    );

    // ---- Pick the next word ----
    // Priority is fixed: a waiting CRC report first, then the processor FIFO.
    wire word_ready;            // serializer: link is free

    // A CRC report is waiting.
    wire status_waiting = !status_empty;
    // Start a word only if the master is not holding the link, and either a CRC
    // is waiting, or the processor has data and is not being reprogrammed
    // (prog_hold blocks processor words so the CRC is the next word the
    // master sees after a PROGRAM frame).
    wire word_valid = !tx_hold_q && (status_waiting || (!fifo_empty && !prog_hold));
    // The word is taken on this edge (valid/ready handshake with the serializer).
    wire accept = word_valid && word_ready;

    // Pop exactly the FIFO the word came from, only on the accepting edge.
    assign status_pop = accept && status_waiting;
    assign fifo_pop = accept && !status_waiting;

    // CRC report: {000, crc}    processor: {io, data}
    wire [10:0] word = status_waiting ? {3'b000, status_out} : fifo_out;

    spi1_tx_serial #(
        .WIDTH(11)
    ) serial (
        .clk(clk),
        .rst_n(rst_n),
        .word_valid(word_valid),
        .word(word),
        .word_ready(word_ready),
        .tx_cs_n(tx_cs_n),
        .miso(miso)
    );
endmodule
