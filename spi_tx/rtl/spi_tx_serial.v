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
 *
 * ---------------------------------------------------------------------------
 * BIG PICTURE
 * ---------------------------------------------------------------------------
 * This is a "parallel to serial" converter (a serializer). The rest of the
 * chip hands it a whole 11-bit word at once; it sends that word out on the
 * single miso wire, one bit per clock, MSB first, with tx_cs_n low during the
 * word so the master knows which bits belong together.
 *
 * It is the mirror image of spi_rx_serial (which turns a serial stream back
 * into bytes).
 *
 * ---------------------------------------------------------------------------
 * EXAMPLE: sending a word with WIDTH = 4 to keep the picture small
 * (word = 4'b1011; the real design uses WIDTH = 11)
 * ---------------------------------------------------------------------------
 *   edge:        0          1       2       3       4       5
 *   state:       idle       send    send    send    end     idle/gap
 *   word_valid:  1          -       -       -       -       -
 *   tx_cs_n:     1    -->   0       0       0       0  -->  1
 *   miso:        0    -->   1       0       1       1  -->  0
 *   remaining:   0    -->   3       2       1       0       0
 *
 *   - Edge 0: idle with a word waiting -> take it. tx_cs_n falls and the MSB
 *     (1) is put on miso immediately; the other 3 bits go into `shift`.
 *   - Edges 1..3: each edge pushes the next bit onto miso.
 *   - Edge 4: remaining == 0 means the last bit has had its full cycle on the
 *     wire; raise tx_cs_n again. That one high cycle is the gap between words.
 *   Total: WIDTH cycles low + 1 cycle high = WIDTH + 1 clocks per word.
 */

module spi_tx_serial #(
    parameter WIDTH = 11    // bits per word (a parameter can be overridden when instantiated)
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
    // Number of bits needed to count 0..WIDTH-1. $clog2 is "ceiling of log2",
    // evaluated at build time: $clog2(11) = 4, so remaining is a 4-bit counter
    // (it must hold up to WIDTH-1 = 10).
    localparam CNT_W = $clog2(WIDTH);

    // Why WIDTH-1 bits in `shift`? The MSB is sent immediately on `miso`, so
    // only the remaining WIDTH-1 bits ever have to wait in the shift register.
    reg [WIDTH-2:0] shift;      // bits of the current word not yet sent
    reg [CNT_W-1:0] remaining;  // how many of them are left (WIDTH-1 .. 0)

    // The link is free whenever tx_cs_n is high: before the first word, and in
    // the one-cycle gap after each word.
    // Handshake rule: the word is transferred on a clock edge where BOTH
    // word_valid (source says "I have data") and word_ready (we say "I can
    // take it") are high - the standard valid/ready handshake.
    assign word_ready = tx_cs_n;

    always @(posedge clk) begin
        if (!rst_n) begin
            // Reset: link idle (cs_n high), data line low, nothing to send.
            tx_cs_n <= 1'b1;
            miso <= 1'b0;
            shift <= {(WIDTH-1){1'b0}};     // {N{x}} = replicate x N times: all zeros
            remaining <= {CNT_W{1'b0}};
        end else if (tx_cs_n) begin
            // ---- Idle or gap: start a word if one is waiting ----
            if (word_valid) begin
                tx_cs_n <= 1'b0;            // frame starts: pull chip select low
                miso <= word[WIDTH-1];      // MSB goes out right away
                shift <= word[WIDTH-2:0];   // the rest follow
                // WIDTH-1 bits are still waiting in `shift`.
                remaining <= WIDTH - 1;
            end
            // (No word waiting: do nothing, stay idle with tx_cs_n high.)
        end else if (remaining != 0) begin
            // ---- Sending: next bit ----
            // The next bit to send is the top bit of `shift`...
            miso <= shift[WIDTH-2];
            // ...then slide everything up one place so the following bit
            // becomes the top bit (zeros enter at the bottom, unused).
            shift <= shift << 1;
            remaining <= remaining - 1'b1;
        end else begin
            // ---- Last bit has been out for its cycle: end the frame ----
            // tx_cs_n high for at least this one cycle before the next word.
            // During this cycle word_ready is high again, so a waiting word
            // is picked up on the very next edge - back-to-back words have
            // exactly one cycle between them.
            tx_cs_n <= 1'b1;
            miso <= 1'b0;   // park the data line low between words
        end
    end
endmodule
