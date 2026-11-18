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
    reg tx_hold_q;
    always @(posedge clk) tx_hold_q <= tx_hold;

    // ---- One FIFO per processor ----
    wire [3:0] fifo_empty;
    wire [3:0] fifo_pop;
    wire [31:0] fifo_out;       // oldest byte of each FIFO, packed like tx_data

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_fifo
            fifo #(
                .WIDTH(8),
                .SIZE(FIFO_SIZE)
            ) tx_fifo (
                .clk(clk),
                .rst_n(rst_n),
                .push(tx_push[i]),
                .pop(fifo_pop[i]),
                .data_in(tx_data[8*i +: 8]),
                .data_out(fifo_out[8*i +: 8]),
                .full(tx_full[i]),
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
        .WIDTH(10),
        .SIZE(STATUS_SIZE)
    ) status_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .push(status_valid),
        .pop(status_pop),
        .data_in({status_id, status_data}),
        .data_out(status_out),
        .full(),                // see SPEC.md: only reachable by holding TX for a long time
        .empty(status_empty)
    );

    // ---- Pick the next word ----
    wire grant_valid;
    wire [1:0] grant_id;
    wire word_ready;

    wire status_waiting = !status_empty;
    wire word_valid = !tx_hold_q && (status_waiting || grant_valid);

    // A word is taken when one is offered and the link is free.
    wire accept = word_valid && word_ready;

    // Status first; otherwise the arbiter's processor.
    wire take_status = accept && status_waiting;
    wire take_proc = accept && !status_waiting;

    wire [10:0] word = status_waiting ? {1'b1, status_out}
                                      : {1'b0, grant_id, fifo_out[8*grant_id +: 8]};

    tx_rr_arbiter arbiter (
        .clk(clk),
        .rst_n(rst_n),
        .req(~fifo_empty),
        .prio(tx_priority),
        .accept(take_proc),     // only a processor word uses up a turn
        .grant_valid(grant_valid),
        .grant_id(grant_id)
    );

    // Pop exactly the FIFO whose word was just taken.
    assign status_pop = take_status;
    assign fifo_pop = take_proc ? (4'b0001 << grant_id) : 4'b0000;

    // ---- Serializer ----
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
