/*
 * Serial receiver: the bit-level half of the receive-only link.
 *
 * The sender changes mosi and cs_n on the falling edge of clk; this module
 * samples them on the rising edge. Sender and receiver share clk, so no
 * synchronizers are needed.
 *
 * The pins go straight into flip-flops (mosi_q, cs_n_q) with no logic in
 * front, so the only half-cycle path is pin -> flop. Everything after that
 * gets a full clock period. The cost is one cycle of latency: a bit sampled
 * into mosi_q on edge N is acted on at edge N+1.
 */

module spi_rx_serial (
    input wire clk,
    input wire rst_n,      // synchronous, active low
    input wire mosi,
    input wire cs_n,

    output wire bit_valid,
    output wire bit_data,
    output wire byte_valid,
    output wire [7:0] byte_data
);
    // Input registers. Deliberately not reset: they must keep following the
    // pins during reset, so that right after reset cs_n_q shows the real
    // cs_n and a frame already in progress is not mistaken for a new one.
    reg mosi_q;
    reg cs_n_q;

    always @(posedge clk) begin
        mosi_q <= mosi;
        cs_n_q <= cs_n;
    end

    reg [6:0] shift;    // the bits of the current byte received so far
    reg [2:0] bit_cnt;  // bits received so far (0..7)
    reg armed; // flag to make sure that bits are only accepted if a cs_n occured

    assign bit_valid = armed & ~cs_n_q; // only accept a bit if armed
    assign bit_data = mosi_q;
    assign byte_valid = bit_valid & (bit_cnt == 3'd7); // check that an entire byte is passed
    assign byte_data = {shift, mosi_q}; // builds full 8 bits by combining first 7 with newest value

    always @(posedge clk) begin
        if (!rst_n) begin
            shift <= 7'd0;
            bit_cnt <= 3'd0;
            armed <= 1'b0;
        end else if (cs_n_q) begin
            // Prepare for the first bit of the frame
            bit_cnt <= 3'd0;
            armed <= 1'b1;
        end else if (armed) begin
            // Shift the new bit in
            shift <= {shift[5:0], mosi_q};
            bit_cnt <= bit_cnt + 3'd1;  // wraps 7 -> 0 at each byte boundary
        end
    end
endmodule
