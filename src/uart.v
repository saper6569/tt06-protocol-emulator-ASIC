module uart #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  wire clk,
    input  wire reset,

    // Transmit interface
    input  wire [7:0] tx_data,
    input  wire tx_start,
    output reg tx_busy,
    output reg uart_tx,

    // Receive interface
    input  wire uart_rx,
    output reg [7:0] rx_data,
    output reg rx_valid
);

    localparam integer CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    // ============================================================
    // TX
    // ============================================================

    reg [3:0] tx_bit;
    reg [15:0] tx_count;
    reg [9:0] tx_shift;

    always @(posedge clk) begin
        if (reset) begin
            tx_busy  <= 1'b0;
            uart_tx  <= 1'b1;
            tx_bit   <= 4'd0;
            tx_count <= 16'd0;
            tx_shift <= 10'b1111111111;
        end
        else begin

            // Start a transmission
            if (tx_start && !tx_busy) begin
                // {stop, data, start}
                // 1 stop bit
                // 8 data bits
                // 1 start bit
                tx_shift <= {1'b1, tx_data, 1'b0};

                tx_busy  <= 1'b1;
                tx_bit   <= 4'd0;
                tx_count <= 16'd0;

                uart_tx  <= 1'b0;
            end

            // Currently transmitting
            else if (tx_busy) begin

                if (tx_count == CLKS_PER_BIT - 1) begin
                    tx_count <= 16'd0;

                    if (tx_bit == 4'd9) begin
                        // Transmission finished
                        tx_busy <= 1'b0;
                        uart_tx <= 1'b1;
                    end
                    else begin
                        tx_bit   <= tx_bit + 1'b1;
                        tx_shift <= {1'b1, tx_shift[9:1]};
                        uart_tx  <= tx_shift[1];
                    end
                end
                else begin
                    tx_count <= tx_count + 1'b1;
                end
            end
        end
    end


    // ============================================================
    // RX
    // ============================================================

    reg [1:0]  rx_sync;
    reg [3:0]  rx_bit;
    reg [15:0] rx_count;
    reg [7:0]  rx_shift;
    reg        rx_busy;

    always @(posedge clk) begin
        if (reset) begin
            rx_sync  <= 2'b11;
            rx_busy  <= 1'b0;
            rx_bit   <= 4'd0;
            rx_count <= 16'd0;
            rx_shift <= 8'd0;
            rx_data  <= 8'd0;
            rx_valid <= 1'b0;
        end
        else begin

            // Synchronize asynchronous UART input
            rx_sync[0] <= uart_rx;
            rx_sync[1] <= rx_sync[0];

            // rx_valid is a one-clock pulse
            rx_valid <= 1'b0;

            // ----------------------------------------------------
            // Wait for start bit
            // ----------------------------------------------------
            if (!rx_busy) begin

                if (rx_sync[1] == 1'b0) begin
                    // Detected possible start bit

                    rx_busy  <= 1'b1;
                    rx_bit   <= 4'd0;

                    // Wait half a bit period so we sample
                    // in the middle of the start bit
                    rx_count <= CLKS_PER_BIT / 2;
                end
            end

            // ----------------------------------------------------
            // Receiving
            // ----------------------------------------------------
            else begin

                if (rx_count == CLKS_PER_BIT - 1) begin
                    rx_count <= 16'd0;

                    if (rx_bit == 4'd0) begin
                        // Start bit already detected.
                        // Move to first data bit.
                        rx_bit <= 4'd1;
                    end

                    else if (rx_bit <= 4'd8) begin
                        // Receive data bits LSB first
                        rx_shift[rx_bit - 1] <= rx_sync[1];

                        rx_bit <= rx_bit + 1'b1;
                    end

                    else begin
                        // Stop bit
                        rx_busy  <= 1'b0;
                        rx_data  <= rx_shift;
                        rx_valid <= 1'b1;
                    end
                end

                else begin
                    rx_count <= rx_count + 1'b1;
                end
            end
        end
    end

endmodule