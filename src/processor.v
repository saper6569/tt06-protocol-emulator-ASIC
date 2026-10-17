module processor #(
    parameter CLK_FREQ = 50_000_000,
    parameter IO_PORTS = 8, // Number of GPIO pins
    parameter MEMORY_WIDTH = 8, // Width of the memory data bus
    parameter MEMORY_ADDR_WIDTH = 8, // Width of the memory address bus
    parameter MEMORY_SIZE = 1 << MEMORY_ADDR_WIDTH, // Size of the memory in bytes
    parameter SHIFT_REG_WIDTH = 8, // Width of the shift register
    parameter INSTRUCTION_WIDTH = 8, // Width of the instruction register
    parameter WAIT_CYCLES_WIDTH = 16 // Width of the wait cycles counter
) 
(
    input wire clk,
    input wire rst_n,
    input wire programming_mode, // 1: programming mode, 0: normal operation

    input wire [MEMORY_WIDTH-1:0] mem_data_in, // Data read from memory
    output wire mem_write_en, // 1: write to memory, 0: read from memory
    output wire [MEMORY_ADDR_WIDTH-1:0] mem_addr_out, // Address to read/write in memory
    output wire [MEMORY_WIDTH-1:0] mem_data_out, // Data to write to memory

    output reg [IO_PORTS-1:0] gpio_mode, // 0: push-pull, 1: open-drain
    output reg [IO_PORTS-1:0] gpio_write_en, // 1: drive pin, 0: release (input)
    output reg [IO_PORTS-1:0] gpio_out, // value to drive on each pin
    input wire [IO_PORTS-1:0] gpio_in // input read from the pin
);
    localparam [1:0] FETCH_INSTRUCTION = 2'd0;
    localparam [1:0] CAPTURE_INSTRUCTION = 2'd1;
    localparam [1:0] EXECUTE_INSTRUCTION = 2'd2;

    reg [1:0] state;
    reg [INSTRUCTION_WIDTH-1:0] IR; // Instruction Register to hold the current instruction
    reg [MEMORY_ADDR_WIDTH-1:0] PC; // Program Counter to hold the address of the next instruction to fetch
    reg [SHIFT_REG_WIDTH-1:0] shift_reg;
    // Shift-in sources beyond the GPIO range provide zero and one bits.
    reg one_reg;
    reg zero_reg;
    localparam integer GPIO_INDEX_BITS = (IO_PORTS > 1) ? $clog2(IO_PORTS) : 1;
    // GPIO and bit-set instructions encode their operand in IR[5:1].
    wire [GPIO_INDEX_BITS-1:0] gpio_index = IR[GPIO_INDEX_BITS:1];
    localparam integer INSTRUCTION_INDEX_WIDTH = INSTRUCTION_WIDTH - 3;
    localparam integer TIMER_INDEX_BITS =
        (WAIT_CYCLES_WIDTH > 1) ? $clog2(WAIT_CYCLES_WIDTH) : 1;
    wire [INSTRUCTION_INDEX_WIDTH-1:0] instruction_index =
        IR[INSTRUCTION_WIDTH-3:1];
    wire [TIMER_INDEX_BITS-1:0] timer_index =
        instruction_index[TIMER_INDEX_BITS-1:0];
    // Bit-set indices enumerate timer_wait_cycles first, then gpio_mode.
    wire [GPIO_INDEX_BITS-1:0] gpio_mode_index =
        instruction_index[GPIO_INDEX_BITS-1:0] - GPIO_INDEX_BITS'(WAIT_CYCLES_WIDTH);

    // Wait instructions hold EXECUTE until their condition is satisfied.
    reg setup_complete;
    reg [WAIT_CYCLES_WIDTH-1:0] timer_wait_cycles;
    reg start_timer;
    wire timer_done;
    localparam [INSTRUCTION_WIDTH-1:0] TIMER_WAIT_INSTRUCTION = 8'b00111111;

    localparam integer JUMP_BLOCK_WIDTH =
        MEMORY_SIZE / (1 << (INSTRUCTION_WIDTH - 2));
    localparam integer JUMP_PC_MULTIPLIER = $clog2(JUMP_BLOCK_WIDTH);

    // This processor only reads instruction memory; programming is handled externally.
    assign mem_addr_out = PC; // Automaticcaly read instruction memory at PC
    assign mem_write_en = 1'b0;
    assign mem_data_out = {MEMORY_WIDTH{1'b0}};

    timer #(
        .WIDTH(WAIT_CYCLES_WIDTH)
    ) timer_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_timer),
        .wait_cycles(timer_wait_cycles),
        .done(timer_done)
    );

    // Synchronous memory requires a request cycle followed by capture and execute.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= FETCH_INSTRUCTION;
            PC <= {MEMORY_ADDR_WIDTH{1'b0}};
            IR <= {INSTRUCTION_WIDTH{1'b0}};
            shift_reg <= {SHIFT_REG_WIDTH{1'b0}};
            one_reg <= 1'b1;
            zero_reg <= 1'b0;
            setup_complete <= 1'b0;
            timer_wait_cycles <= {WAIT_CYCLES_WIDTH{1'b0}};
            start_timer <= 1'b0;
            gpio_mode <= {IO_PORTS{1'b0}};
            gpio_write_en <= {IO_PORTS{1'b0}};
            gpio_out <= {IO_PORTS{1'b0}};
        end
        else begin
            start_timer <= 1'b0;

            // Fetch request, capture the synchronous memory result, then execute.
            case (state)
                FETCH_INSTRUCTION: begin
                    state <= CAPTURE_INSTRUCTION;
                end

                CAPTURE_INSTRUCTION: begin
                    IR <= mem_data_in;
                    PC <= PC + 1'b1;
                    state <= EXECUTE_INSTRUCTION;
                end

                EXECUTE_INSTRUCTION: begin
                    // 00: wait for timer_wait_cycles, otherwise poll GPIO.
                    if (IR[INSTRUCTION_WIDTH-1:INSTRUCTION_WIDTH-2] == 2'b00) begin
                        if (IR == TIMER_WAIT_INSTRUCTION) begin
                            if (!setup_complete) begin
                                start_timer <= 1'b1;
                                setup_complete <= 1'b1;
                            end
                            else if (timer_done) begin
                                setup_complete <= 1'b0;
                                state <= FETCH_INSTRUCTION;
                            end
                        end
                        else begin
                            // IR[5:1] selects the input; IR[0] is the value being polled for.
                            if (instruction_index < IO_PORTS) begin
                                if (!setup_complete) begin
                                    gpio_write_en[gpio_index] <= 1'b0;
                                    setup_complete <= 1'b1;
                                end
                                else if (gpio_in[gpio_index] == IR[0]) begin
                                    setup_complete <= 1'b0;
                                    state <= FETCH_INSTRUCTION;
                                end
                            end
                            else begin
                                setup_complete <= 1'b0;
                                state <= FETCH_INSTRUCTION;
                            end
                        end
                    end
                    // 01: shift one bit between the shift register and a GPIO/source.
                    else if (IR[INSTRUCTION_WIDTH-1:INSTRUCTION_WIDTH-2] == 2'b01) begin
                        if (IR[0]) begin // Shift out
                            if (instruction_index < IO_PORTS) begin
                                gpio_write_en[gpio_index] <= 1'b1;
                                shift_reg <= {1'b0, shift_reg[SHIFT_REG_WIDTH-1:1]};
                                gpio_out[gpio_index] <= shift_reg[0];
                            end
                            state <= FETCH_INSTRUCTION;
                            setup_complete <= 1'b0;
                        end
                        else if (instruction_index < IO_PORTS) begin
                            gpio_write_en[gpio_index] <= 1'b0;
                            shift_reg <= {shift_reg[SHIFT_REG_WIDTH-2:0],
                                          gpio_in[gpio_index]};
                            state <= FETCH_INSTRUCTION;
                            setup_complete <= 1'b0;
                        end
                        else if (instruction_index == IO_PORTS) begin
                            // The first source after the GPIO range is constant zero.
                            shift_reg <= {shift_reg[SHIFT_REG_WIDTH-2:0], zero_reg};
                            state <= FETCH_INSTRUCTION;
                            setup_complete <= 1'b0;
                        end
                        else if (instruction_index == IO_PORTS + 1) begin
                            // The next source index is constant one.
                            shift_reg <= {shift_reg[SHIFT_REG_WIDTH-2:0], one_reg};
                            state <= FETCH_INSTRUCTION;
                            setup_complete <= 1'b0;
                        end
                        else begin
                            state <= FETCH_INSTRUCTION;
                        end
                    end
                    // 10: set or clear an individual timer-duration or GPIO-mode bit.
                    else if (IR[INSTRUCTION_WIDTH-1:INSTRUCTION_WIDTH-2] == 2'b10) begin
                        if (instruction_index < WAIT_CYCLES_WIDTH) begin
                            timer_wait_cycles[timer_index] <= IR[0];
                        end
                        else if (instruction_index < WAIT_CYCLES_WIDTH + IO_PORTS) begin
                            gpio_mode[gpio_mode_index] <= IR[0];
                        end
                        state <= FETCH_INSTRUCTION;
                    end
                    else begin
                        // 11: jump to a block of instructions.
                        PC <= {{(MEMORY_ADDR_WIDTH - (INSTRUCTION_WIDTH - 2)){1'b0}},
                               IR[INSTRUCTION_WIDTH-3:0]} << JUMP_PC_MULTIPLIER;
                        state <= FETCH_INSTRUCTION;
                    end
                end
                default: begin
                    state <= FETCH_INSTRUCTION;
                end
            endcase
        end
    end
endmodule
