/*
 * TX serializer: sends one WIDTH-bit word per frame to the master.
 *
 * Link: the ASIC drives tx_cs_n (frame select, active low) and miso (data) on
 * the shared clk. Both change on the RISING edge of clk; the master samples
 * them on the FALLING edge, which gives half a cycle of margin either way.
 *
 * Frame: tx_cs_n low for exactly WIDTH cycles, one bit per cycle, MSB first.
 * spi_tx_top uses WIDTH = 11: {status, id[1:0], data[7:0]}.
 *
 * Between frames tx_cs_n is high for at least one cycle, so the master can
 * always tell where a word starts. With words waiting, the gap is exactly one
 * cycle: one word every WIDTH + 1 clocks.
 *
 * Handshake with the word source: word_ready is high while tx_cs_n is high
 * (the link is free). When word_valid and word_ready are both high on a rising
 * edge, the word is taken on that edge and its first bit goes out.
 */

module spi_tx_serial #(
    parameter WIDTH = 11
) (
    input wire clk,
    input wire rst_n,           // synchronous, active low

    // From the word source
    input wire word_valid,      // a word is waiting
    input wire [WIDTH-1:0] word,// only meaningful with word_valid
    output wire word_ready,     // 1: the link is free; a valid word is taken this edge

    // To the master
    output reg tx_cs_n,         // low while a word is being sent
    output reg miso             // the word's bits, MSB first
);
    localparam CNT_W = $clog2(WIDTH);

    reg [WIDTH-2:0] shift;      // bits of the current word not yet sent
    reg [CNT_W-1:0] remaining;  // how many of them are left (WIDTH-1 .. 0)

    // The link is free whenever tx_cs_n is high: before the first word, and in
    // the one-cycle gap after each word.
    assign word_ready = tx_cs_n;

    always @(posedge clk) begin
        if (!rst_n) begin
            tx_cs_n <= 1'b1;
            miso <= 1'b0;
            shift <= {(WIDTH-1){1'b0}};
            remaining <= {CNT_W{1'b0}};
        end else if (tx_cs_n) begin
            // ---- Idle or gap: start a word if one is waiting ----
            if (word_valid) begin
                tx_cs_n <= 1'b0;
                miso <= word[WIDTH-1];      // MSB goes out right away
                shift <= word[WIDTH-2:0];   // the rest follow
                remaining <= WIDTH - 1;
            end
        end else if (remaining != 0) begin
            // ---- Sending: next bit ----
            miso <= shift[WIDTH-2];
            shift <= shift << 1;
            remaining <= remaining - 1'b1;
        end else begin
            // ---- Last bit has been out for its cycle: end the frame ----
            // tx_cs_n high for at least this one cycle before the next word.
            tx_cs_n <= 1'b1;
            miso <= 1'b0;
        end
    end
endmodule
