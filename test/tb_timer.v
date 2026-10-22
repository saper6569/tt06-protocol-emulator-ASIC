module tb_timer (
    input wire clk,
    input wire rst_n,
    input wire enable,
    input wire start,
    input wire [10:0] wait_cycles,
    output wire done_tick_1,
    output wire done_tick_3,
    output wire [10:0] count_tick_1,
    output wire [10:0] count_tick_3
);
    timer #(
        .COUNTER_BITS(11),
        .CLK_PERIOD_NS(20),
        .TICK_CYCLES(1)
    ) timer_tick_1 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .start(start),
        .wait_cycles(wait_cycles),
        .done(done_tick_1)
    );

    timer #(
        .COUNTER_BITS(11),
        .CLK_PERIOD_NS(20),
        .TICK_CYCLES(3)
    ) timer_tick_3 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .start(start),
        .wait_cycles(wait_cycles),
        .done(done_tick_3)
    );

    assign count_tick_1 = timer_tick_1.count;
    assign count_tick_3 = timer_tick_3.count;
endmodule
