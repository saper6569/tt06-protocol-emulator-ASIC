module tb_io_port (
    input wire clk,
    input wire rst_n,
    input wire [7:0] gpio_out,
    input wire [7:0] write_en,
    input wire [7:0] gpio_mode,
    input wire [7:0] external_drive_en,
    input wire [7:0] external_drive,
    output wire [7:0] gpio,
    output wire [7:0] gpio_in,
    output wire [7:0] gpio_pad_out,
    output wire [7:0] gpio_pad_oe
);
    tri [7:0] gpio_bus;

    assign (weak1, weak0) gpio_bus =
        external_drive_en ? external_drive : 8'bz;
    assign gpio = gpio_bus;

    assign gpio_bus = gpio_pad_oe ? gpio_pad_out : 8'bz;

    io_port #(
        .GPIO_WIDTH(8)
    ) dut (
        .gpio_out(gpio_out),
        .write_en(write_en),
        .gpio_mode(gpio_mode),
        .gpio_in(gpio_bus),
        .gpio_pad_out(gpio_pad_out),
        .gpio_pad_oe(gpio_pad_oe)
    );

    assign gpio_in = gpio_bus;
endmodule
