/*
 * Transmit link: four processors and the receive link share one serial link
 * back to the master.
 *
 *   processor i --push--> fifo i ----+
 *   (x4)                             +--> tx_rr_arbiter --+
 *                                                         +--> spi_tx_serial --> tx_cs_n, miso
 *   spi_rx CRC report --> status fifo (always first) -----+
 *
 * Word on the wire, 11 bits, MSB first:
 *     {status, id[1:0], data[7:0]}
 *     status = 0: data is a byte from processor id
 *     status = 1: data is the CRC-8 of the PROGRAM frame just received for
 *                 processor id (from spi_rx); the master answers with prog_ok
 *
 * Each processor pushes bytes into its own FIFO (src/fifo.v). The FIFOs soak up
 * bursts, because the link carries one word every 12 clocks while up to four
 * processors may be producing bytes.
 *
 * Order: a waiting status word always goes next. Otherwise the arbiter picks a
 * non-empty processor FIFO: high-priority processors (tx_priority) first,
 * round robin within each group.
 *
 * tx_hold (pin, from the master): while it is high, no new word starts. A word
 * already being sent finishes. Words wait in the FIFOs meanwhile, so a long
 * hold fills them and the processors see tx_full.
 *
 * Full FIFOs: tx_full[i] goes back to processor i. A push while full is
 * ignored by the FIFO, so the processor must wait while tx_full[i] is high.
 *
 * Per-processor buses are packed: processor i uses tx_data[8*i +: 8].
 *
 * ---------------------------------------------------------------------------
 * HOW TO READ THIS FILE
 * ---------------------------------------------------------------------------
 * Data flows top to bottom through four stages:
 *   1. FIFOs      - each processor drops bytes into its own queue (and a
 *                   separate small queue holds CRC status reports from RX).
 *   2. Choose     - decide whether the next word is a status word or a
 *                   processor word, and which processor (the arbiter).
 *   3. Build word - glue {status, id, data} into the 11-bit word.
 *   4. Serialize  - spi_tx_serial shifts it out on tx_cs_n / miso.
 *
 * Example words:
 *   Processor 2 sends byte 0x41:  {0, 10, 01000001} = 0b0_10_01000001
 *   CRC report for proc 1, crc 0xF4: {1, 01, 11110100}
 *
 * "Packed" bus note: tx_data is 32 bits wide = four bytes side by side.
 *   processor 0 -> tx_data[7:0],  processor 1 -> tx_data[15:8],
 *   processor 2 -> tx_data[23:16], processor 3 -> tx_data[31:24].
 * The syntax tx_data[8*i +: 8] means "starting at bit 8*i, take 8 bits
 * upward" - a way to select a slice whose position depends on i.
 */

module spi_tx_top #(
    parameter FIFO_SIZE = 4,    // bytes buffered per processor
    parameter STATUS_SIZE = 2   // status words buffered (see SPEC.md)
) (
    input wire clk,
    input wire rst_n,           // synchronous, active low

    // From the processors
    input wire [3:0] tx_push,   // bit i: processor i pushes tx_data[8*i +: 8] this cycle
    input wire [31:0] tx_data,  // one byte per processor
    output wire [3:0] tx_full,  // bit i: processor i's FIFO is full; wait before pushing
    input wire [3:0] tx_priority, // bit i: processor i is high priority

    // From spi_rx_top: CRC report at the end of each PROGRAM frame
    input wire status_valid,    // one-cycle pulse
    input wire [1:0] status_id,
    input wire [7:0] status_data,

    // To / from the master
    input wire tx_hold,         // pin: 1 = don't start a new word
    output wire tx_cs_n,
    output wire miso
);
    // tx_hold is a pin: register it so it only has a pin -> flop path. Not
    // reset, so it follows the pin during reset too.
    // (Same trick as in spi_rx_serial: always put a flop right on an input
    // pin, then use the "_q" copy everywhere else.)
    reg tx_hold_q;
    always @(posedge clk) tx_hold_q <= tx_hold;

    // ---- One FIFO per processor ----
    // A FIFO ("first in, first out") is a small queue: bytes come out in the
    // order they went in. It lets a processor push a byte and carry on
    // without waiting for the slow serial link.
    wire [3:0] fifo_empty;      // bit i: FIFO i has nothing in it
    wire [3:0] fifo_pop;        // bit i: remove the oldest byte from FIFO i
    wire [31:0] fifo_out;       // oldest byte of each FIFO, packed like tx_data

    genvar i;
    // generate/for builds four copies of the FIFO at compile time (hardware,
    // not a runtime loop). Each copy is named g_fifo[0]..g_fifo[3].
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_fifo
            fifo #(
                .WIDTH(8),          // 8 bits per entry (one byte)
                .SIZE(FIFO_SIZE)    // how many entries it can hold
            ) tx_fifo (
                .clk(clk),
                .rst_n(rst_n),
                .push(tx_push[i]),                  // processor i writes
                .pop(fifo_pop[i]),                  // we read (when its word is taken)
                .data_in(tx_data[8*i +: 8]),        // processor i's byte
                .data_out(fifo_out[8*i +: 8]),      // the oldest byte, always visible
                .full(tx_full[i]),                  // reported back to processor i
                .empty(fifo_empty[i])
            );
        end
    endgenerate

    // ---- Status words from the receive link ----
    // Normally at most one is waiting: PROGRAM frames end at least 17 clocks
    // apart and a status word waits at most one word time (12 clocks). The
    // extra slot covers a master that holds tx_hold across two PROGRAM frames.
    wire status_empty;
    wire status_pop;
    wire [9:0] status_out;      // {id, crc}

    fifo #(
        .WIDTH(10),             // 2 bits of id + 8 bits of CRC
        .SIZE(STATUS_SIZE)
    ) status_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .push(status_valid),                    // spi_rx's one-cycle crc_valid pulse
        .pop(status_pop),
        .data_in({status_id, status_data}),     // {} glues id on top of the CRC
        .data_out(status_out),
        .full(),                // see SPEC.md: only reachable by holding TX for a long time
        .empty(status_empty)
    );

    // ---- Pick the next word ----
    wire grant_valid;           // arbiter: some processor FIFO has data
    wire [1:0] grant_id;        // arbiter: which one goes next
    wire word_ready;            // serializer: link is free

    // A status word is waiting whenever its FIFO is non-empty.
    wire status_waiting = !status_empty;
    // We have a word to offer if the master is not holding us off AND there is
    // either a status word or a processor byte.
    wire word_valid = !tx_hold_q && (status_waiting || grant_valid);

    // A word is taken when one is offered and the link is free.
    // (valid && ready handshake - see spi_tx_serial.)
    wire accept = word_valid && word_ready;

    // Status first; otherwise the arbiter's processor.
    // Split "a word was taken" into WHICH kind, so we pop the right FIFO.
    wire take_status = accept && status_waiting;
    wire take_proc = accept && !status_waiting;

    // Build the 11-bit word. Status words have priority over processor bytes.
    //   status:    {1, id, crc}               (status_out is already {id, crc})
    //   processor: {0, grant_id, byte}        byte = the granted FIFO's output
    // fifo_out[8*grant_id +: 8] picks that processor's byte out of the packed bus.
    wire [10:0] word = status_waiting ? {1'b1, status_out}
                                      : {1'b0, grant_id, fifo_out[8*grant_id +: 8]};

    tx_rr_arbiter arbiter (
        .clk(clk),
        .rst_n(rst_n),
        .req(~fifo_empty),      // "requesting" = FIFO is not empty
        .prio(tx_priority),
        .accept(take_proc),     // only a processor word uses up a turn
        .grant_valid(grant_valid),
        .grant_id(grant_id)
    );

    // Pop exactly the FIFO whose word was just taken.
    // Popping happens on the same edge the serializer latches the word, so the
    // byte is removed from the queue exactly once. For a processor word the
    // one-hot mask (1 << grant_id) selects only the granted FIFO.
    assign status_pop = take_status;
    assign fifo_pop = take_proc ? (4'b0001 << grant_id) : 4'b0000;

    // ---- Serializer ----
    // Turns the 11-bit word into tx_cs_n/miso. WIDTH must match the width of
    // `word` above.
    spi_tx_serial #(
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
