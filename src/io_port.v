module io_port #(
    parameter GPIO_WIDTH = 8 // Number of GPIO pins
)(
    input wire clk, // Not used but we can add if we want synchronized stuff later on
    input wire reset, // Not used but we can add if we want synchronized stuff later on

    // Processor interface
    input wire write_data, 
    input wire write_en, // Set using the registor for REF_BIT
    input wire [GPIO_WIDTH-1:0] gpio_mode, // 0: push-pull, 1: open-drain

    // Physical GPIO pins (bi-directional)
    inout wire [GPIO_WIDTH-1:0] gpio,

    // GPIO input state
    output wire [GPIO_WIDTH-1:0] gpio_in
);

    genvar i;

    generate
        for (i = 0; i < GPIO_WIDTH; i = i + 1) begin : GPIO_PINS

            /*
            Push-pull mode:
            write_en = 1, write_data = 0  drive LOW
            write_en = 1, write_data = 1  drive HIGH
            
            Open-drain mode:
            write_en = 1, write_data = 0  drive LOW
            write_en = 1, write_data = 1  release line
            
            write_en = 0  release line / high-impedance state for read
            */

            always begin
                if (!write_en) begin
                    // Not writing: release the pin
                    gpio[i] = 1'bz;
                end
                else if (gpio_mode[i] == 1'b0) begin
                    // Push-pull mode: drive either 0 or 1
                    gpio[i] = write_data;
                end
                else if (write_data == 1'b0) begin
                    // Open-drain: drive LOW
                    gpio[i] = 1'b0;
                end
                else begin
                    // Open-drain: release the pin for external pull-up
                    gpio[i] = 1'bz;
                end
            end

            // Read the state of the pin
            assign gpio_in[i] = gpio[i];
        end
    endgenerate

endmodule