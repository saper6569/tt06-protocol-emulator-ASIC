/**
 * Countdown timer with a clock-enable prescaler.
 *
 * Resolution/minimum nonzero wait: TICK_CYCLES * CLK_PERIOD_NS ns.
 * Maximum wait: (2^COUNTER_BITS - 1) * TICK_CYCLES * CLK_PERIOD_NS ns.
 * Counter bit b represents 2^b * TICK_CYCLES * CLK_PERIOD_NS ns.
 */
module timer #(
    parameter COUNTER_BITS = 11,
    parameter CLK_PERIOD_NS = 20,
    parameter TICK_CYCLES = 1
)(
    input wire clk,
    input wire rst_n,
    input wire enable,
    input wire start,
    input wire [COUNTER_BITS-1:0] wait_cycles,
    output wire done
);
    localparam PRESCALER_WIDTH =
        (TICK_CYCLES > 1) ? $clog2(TICK_CYCLES) : 1;

    reg [COUNTER_BITS-1:0] count;
    reg [PRESCALER_WIDTH-1:0] prescaler;
    wire tick = TICK_CYCLES == 1 ||
                prescaler == TICK_CYCLES - 1;

    initial begin
        if (COUNTER_BITS < 1 || CLK_PERIOD_NS < 1 || TICK_CYCLES < 1) begin
            $fatal(1, "timer parameters must be positive");
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            count <= {COUNTER_BITS{1'b0}};
            prescaler <= {PRESCALER_WIDTH{1'b0}};
        end
        else if (enable && start) begin
            count <= wait_cycles;
            prescaler <= {PRESCALER_WIDTH{1'b0}};
        end
        else if (enable) begin
            if (count != 0) begin
                if (tick) begin
                    count <= count - 1'b1;
                    prescaler <= {PRESCALER_WIDTH{1'b0}};
                end
                else begin
                    prescaler <= prescaler + 1'b1;
                end
            end
            else begin
                prescaler <= {PRESCALER_WIDTH{1'b0}};
            end
        end
    end

    assign done = (count == 0) && !start;
endmodule
