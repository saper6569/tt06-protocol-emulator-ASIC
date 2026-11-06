/*
 * Top level of the processor FPGA
 *
 *   CLOCK_50            50 MHz clock
 *   CPU_RESET_n         reset button, also applied after configuration
 *   SW[0]               run enable
 *   GPIO[7:0]           protocol pins
 *   PROG_EN_n/CLK/DATA  programming pins (see program_receiver.v)
 */

module processor_fpga_top (
    input wire CLOCK_50,
    input wire CPU_RESET_n,
    input wire [0:0] SW,
    inout wire [7:0] GPIO,
    input wire PROG_EN_n,
    input wire PROG_DATA,
    input wire PROG_CLK
);
    wire clk = CLOCK_50;

    reg [1:0] reset_sync = 2'b00;
    wire rst_n = reset_sync[1];

    always @(posedge clk or negedge CPU_RESET_n) begin
        if (!CPU_RESET_n)
            reset_sync <= 2'b00;
        else
            reset_sync <= {reset_sync[0], 1'b1};
    end

    // Two-stage synchronizers for the switch and protocol pins.
    reg [8:0] input_meta;
    reg [8:0] input_sync;

    always @(posedge clk) begin
        input_meta <= {SW[0], GPIO};
        input_sync <= input_meta;
    end

    wire [7:0] gpio_in = input_sync[7:0];
    wire run_input = input_sync[8];

    wire program_en;
    wire program_data;
    wire programming_busy;
    wire programming_restart;

    program_receiver #(
        .WORD_WIDTH(16)
    ) program_receiver_inst (
        .clk(clk),
        .rst_n(rst_n),
        .prog_en_n(PROG_EN_n),
        .prog_clk(PROG_CLK),
        .prog_data(PROG_DATA),
        .program_en(program_en),
        .program_data(program_data),
        .busy(programming_busy),
        .restart(programming_restart)
    );

    // Registered because the processor resets asynchronously, so this must
    // not glitch. A finished load starts the processor from address 0.
    reg core_rst_n = 1'b0;

    always @(posedge clk)
        core_rst_n <= rst_n & ~programming_restart;

    wire run = run_input & ~programming_busy;

    wire [7:0] uo_out;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    tt_um_example core (
        .ui_in({program_en, program_data, run, 5'b00000}),
        .uo_out(uo_out),
        .uio_in(gpio_in),
        .uio_out(uio_out),
        .uio_oe(uio_oe),
        .ena(1'b1),
        .clk(clk),
        .rst_n(core_rst_n)
    );

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_gpio
            assign GPIO[i] = uio_oe[i] ? uio_out[i] : 1'bz;
        end
    endgenerate
endmodule

