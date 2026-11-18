/*
 * Round-robin arbiter for the four processor TX FIFOs, with a priority group.
 *
 * req[i] is high when processor i's FIFO has a byte waiting. prio[i]
 * marks processor i as high priority (for example one receiving a protocol
 * that can't be paused, like Ethernet).
 *
 *   1. If any high-priority processor is requesting, only those are
 *      considered. Otherwise every requester is.
 *   2. Among the processors considered, round robin: the search starts at the
 *      processor after the one granted last (`last`), in the order last+1,
 *      last+2, last+3, last (wrapping 3 -> 0), and grants the first one
 *      requesting. Processors with nothing to send are skipped.
 *
 * With prio = 0000 (or 1111) this is plain round robin: all four FIFOs
 * with data -> 0, 1, 2, 3, 0, ...; only 1 and 3 -> 1, 3, 1, 3, ...
 * A high-priority processor that never runs out of data starves the others.
 * That's the point of priority, but use it only for a processor whose average
 * rate is below the link rate.
 *
 * The choice is combinational from req, priority and `last`. `last` only moves
 * when the serializer actually takes the word (accept), so grant_id stays
 * stable while a word waits for the link.
 */

module tx_rr_arbiter (
    input wire clk,
    input wire rst_n,           // synchronous, active low

    input wire [3:0] req,       // bit i: processor i has a byte to send
    input wire [3:0] prio,      // bit i: processor i is high priority
    input wire accept,          // the granted word was taken this cycle

    output wire grant_valid,    // at least one processor is requesting
    output reg [1:0] grant_id   // processor whose byte goes next
);
    // Processor granted most recently. Reset to 3 so the first search starts
    // at processor 0.
    reg [1:0] last;

    // Requesters that take part in this round: the high-priority ones if any
    // are requesting, otherwise everyone.
    wire [3:0] req_hi = req & prio;
    wire [3:0] cand = (req_hi != 4'b0000) ? req_hi : req;

    // Search order after `last`. 2-bit adds wrap 3 -> 0 by themselves.
    wire [1:0] next1 = last + 2'd1;
    wire [1:0] next2 = last + 2'd2;
    wire [1:0] next3 = last + 2'd3;

    assign grant_valid = |req;

    // First candidate in round-robin order. If only `last` itself is a
    // candidate, it is granted again (no one else is waiting). When nobody is
    // requesting, grant_id is don't-care and grant_valid is low.
    always @(*) begin
        if (cand[next1])
            grant_id = next1;
        else if (cand[next2])
            grant_id = next2;
        else if (cand[next3])
            grant_id = next3;
        else
            grant_id = last;
    end

    always @(posedge clk) begin
        if (!rst_n)
            last <= 2'd3;
        else if (accept && grant_valid)
            last <= grant_id;  // this processor has had its turn
    end
endmodule
