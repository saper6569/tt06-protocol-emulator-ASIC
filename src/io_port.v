// set gpio_mode to 0 for push-pull, 1 for open-drain
// at top level set write enable and set gpio_out to value to write to pin
module io_port #(
    parameter GPIO_WIDTH = 8  // Number of GPIO pins
)(
    input  wire clk,   // Unused for now 
    input  wire rst_n, // Unused for now

    // Processor interface
    input wire [GPIO_WIDTH-1:0] gpio_out, // Value to drive on each pin
    input wire [GPIO_WIDTH-1:0] write_en,   // 1: drive pin, 0: release (input)
    input wire [GPIO_WIDTH-1:0] gpio_mode,  // 0: push-pull, 1: open-drain

    // Physical GPIO pins (bi-directional)
    inout wire [GPIO_WIDTH-1:0] gpio,

    // Input read from the pin
    output wire [GPIO_WIDTH-1:0] gpio_in
);

    genvar i;
    generate
        for (i = 0; i < GPIO_WIDTH; i = i + 1) begin : GPIO_PINS

            /*
            Push-pull mode (gpio_mode = 0):
              write_en = 1, gpio_out = 0 -> drive LOW
              write_en = 1, gpio_out = 1 -> drive HIGH

            Open-drain mode (gpio_mode = 1):
              write_en = 1, gpio_out = 0 -> drive LOW
              write_en = 1, gpio_out = 1 -> release line (external pull-up)
            
            write_en = 0 -> release line (high-Z) so the pin can be read

            Truth Table:
            gpio_mode | write_en | gpio_out | gpio
            ----------+----------+------------+-----
                0     |    1     |     0      |  0
                0     |    1     |     1      |  1
                0     |    0     |     X      | high-Z (input)
                1     |    1     |     0      |  0
                1     |    1     |     1      | high-Z (input)
                1     |    0     |     X      | high-Z (input)
            */

            // Drive only when enabled, and in open-drain mode only when pulling low
            wire drive = write_en[i] & (~gpio_mode[i] | ~gpio_out[i]);
            assign gpio[i] = drive ? gpio_out[i] : 1'bz;
            // Read back the pin value
            assign gpio_in[i] = gpio[i];
        end
    endgenerate
endmodule