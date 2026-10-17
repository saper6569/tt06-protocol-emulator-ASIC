module io_port #(
    parameter GPIO_WIDTH = 8
)(
    input wire [GPIO_WIDTH-1:0] gpio_out,
    input wire [GPIO_WIDTH-1:0] write_en,
    input wire [GPIO_WIDTH-1:0] gpio_mode,

    input wire [GPIO_WIDTH-1:0] gpio_in,

    output wire [GPIO_WIDTH-1:0] gpio_pad_out,
    output wire [GPIO_WIDTH-1:0] gpio_pad_oe
);

    genvar i;
    generate
        for (i = 0; i < GPIO_WIDTH; i = i + 1) begin : GPIO_PINS

            // Output value: open-drain can only drive LOW.
            assign gpio_pad_out[i] =
                gpio_mode[i] ? 1'b0 : gpio_out[i];

            // Enable output driver.
            assign gpio_pad_oe[i] =
                write_en[i] &
                (~gpio_mode[i] | ~gpio_out[i]);

        end
    endgenerate

endmodule
