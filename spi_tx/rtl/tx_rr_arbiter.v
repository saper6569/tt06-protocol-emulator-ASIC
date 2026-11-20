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
 *
 * ---------------------------------------------------------------------------
 * WHY AN ARBITER?
 * ---------------------------------------------------------------------------
 * Four processors share ONE outgoing link, and the link can only send one
 * word at a time. Something has to decide whose byte goes next. That is the
 * arbiter. "Round robin" means "take turns fairly": whoever was served most
 * recently goes to the back of the line.
 *
 * ---------------------------------------------------------------------------
 * EXAMPLES  (req shown as bits [3:2:1:0], prio = 0000, last starts at 3)
 * ---------------------------------------------------------------------------
 *   req = 1111, last = 3: search order 0,1,2,3 -> grant 0, then last = 0
 *   req = 1111, last = 0: search order 1,2,3,0 -> grant 1, then last = 1
 *   req = 1010 (procs 1 and 3), last = 1: order 2,3,0,1 -> 2 not requesting,
 *         3 is -> grant 3. Next time last = 3: order 0,1,2,3 -> grant 1.
 *   req = 0100 (only proc 2), last = 2: order 3,0,1,2 -> only `last` itself
 *         is requesting, so it is granted again (nobody else is waiting).
 *
 * With priority: req = 1111, prio = 0100 -> cand = 0100, so only processor 2
 * is considered, even if it was granted last time.
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
    // req & prio is a bitwise AND: it leaves a 1 only where a processor is
    // BOTH requesting and high priority. "!= 4'b0000" asks "is there at least
    // one such processor?". `? :` is an if/else that can be used inside an
    // expression: (condition) ? value_if_true : value_if_false.
    wire [3:0] req_hi = req & prio;
    wire [3:0] cand = (req_hi != 4'b0000) ? req_hi : req;

    // Search order after `last`. 2-bit adds wrap 3 -> 0 by themselves.
    // (2 bits can only hold 0..3, so 3 + 1 = 4 overflows to 0: free modulo-4.)
    wire [1:0] next1 = last + 2'd1;
    wire [1:0] next2 = last + 2'd2;
    wire [1:0] next3 = last + 2'd3;

    // "|req" is a reduction OR: 1 if ANY bit of req is 1. Note it looks at
    // req, not cand: cand is a subset of req, so it is non-empty exactly when
    // req is non-empty.
    assign grant_valid = |req;

    // First candidate in round-robin order. If only `last` itself is a
    // candidate, it is granted again (no one else is waiting). When nobody is
    // requesting, grant_id is don't-care and grant_valid is low.
    //
    // always @(*) = combinational logic (no clock): the output updates
    // immediately whenever any input changes. "cand[next1]" indexes the
    // 4-bit vector with a number: is the processor numbered next1 a candidate?
    // The if / else-if chain gives next1 the highest precedence, then next2,
    // then next3, then `last` - exactly the round-robin order.
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

    // The only state in this module: remember who was served last.
    always @(posedge clk) begin
        if (!rst_n)
            last <= 2'd3;
        // Only advance when a word was REALLY taken. Until then (e.g. the link
        // is busy or tx_hold is set) the same processor stays granted, so the
        // choice does not flicker. The grant_valid check is just a safeguard.
        else if (accept && grant_valid)
            last <= grant_id;  // this processor has had its turn
    end
endmodule
