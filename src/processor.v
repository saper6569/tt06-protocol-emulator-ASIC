module processor #(
    parameter CLK_FREQ = 50_000_000,
    parameter IO_PORTS = 4,
    parameter MEMORY_ADDR_WIDTH = 7,
    parameter SHIFT_REG_WIDTH = 8,
    parameter INSTRUCTION_WIDTH = 5,
    parameter COUNTER_BITS = 11,
    parameter CLK_PERIOD_NS = 20,
    parameter TICK_CYCLES = 1
)
(
    input wire clk,
    input wire rst_n,
    input wire programming_mode,

    input wire [INSTRUCTION_WIDTH-1:0] mem_data_in,
    output wire mem_write_en,
    output wire [MEMORY_ADDR_WIDTH-1:0] mem_addr_out,
    output wire [INSTRUCTION_WIDTH-1:0] mem_data_out,

    output reg [IO_PORTS-1:0] gpio_mode,
    output reg [IO_PORTS-1:0] gpio_write_en,
    output reg [IO_PORTS-1:0] gpio_out,
    input wire [IO_PORTS-1:0] gpio_in
);
    localparam [1:0] FETCH_INSTRUCTION = 2'd0;
    localparam [1:0] CAPTURE_INSTRUCTION = 2'd1;
    localparam [1:0] EXECUTE_INSTRUCTION = 2'd2;

    localparam [INSTRUCTION_WIDTH-1:0] WAIT_TIMER = 0;
    localparam [INSTRUCTION_WIDTH-1:0] WAIT_FOR_BASE = 1;
    localparam [INSTRUCTION_WIDTH-1:0] SHIFT_BASE = 5;
    localparam [INSTRUCTION_WIDTH-1:0] TOGGLE_IO_MODE_BASE = 9;
    localparam [INSTRUCTION_WIDTH-1:0] TOGGLE_WAIT_FOR_VALUE = 13;
    localparam [INSTRUCTION_WIDTH-1:0] TOGGLE_SHIFT_DIR = 14;
    localparam [INSTRUCTION_WIDTH-1:0] TOGGLE_COUNTER_BASE = 15;
    localparam [INSTRUCTION_WIDTH-1:0] SHIFT_ONE =
        TOGGLE_COUNTER_BASE + COUNTER_BITS;
    localparam [INSTRUCTION_WIDTH-1:0] SHIFT_ZERO = SHIFT_ONE + 1'b1;
    localparam [INSTRUCTION_WIDTH-1:0] JUMP_BASE = SHIFT_ZERO + 1'b1;
    localparam JUMP_COUNT = 4;
    localparam IO_INDEX_WIDTH = (IO_PORTS > 1) ? $clog2(IO_PORTS) : 1;
    localparam COUNTER_INDEX_WIDTH =
        (COUNTER_BITS > 1) ? $clog2(COUNTER_BITS) : 1;

    reg [1:0] state;
    reg [INSTRUCTION_WIDTH-1:0] IR;
    reg [MEMORY_ADDR_WIDTH-1:0] PC;
    reg [SHIFT_REG_WIDTH-1:0] shift_reg;
    reg setup_complete;
    reg wait_for_value;
    reg shift_dir;
    reg [COUNTER_BITS-1:0] timer_wait_cycles;
    reg start_timer;
    wire timer_done;

    wire [INSTRUCTION_WIDTH-1:0] instruction_value = IR;
    wire [INSTRUCTION_WIDTH-1:0] wait_for_offset =
        instruction_value - WAIT_FOR_BASE;
    wire [INSTRUCTION_WIDTH-1:0] shift_offset =
        instruction_value - SHIFT_BASE;
    wire [INSTRUCTION_WIDTH-1:0] io_mode_offset =
        instruction_value - TOGGLE_IO_MODE_BASE;
    wire [INSTRUCTION_WIDTH-1:0] counter_offset =
        instruction_value - TOGGLE_COUNTER_BASE;
    wire [INSTRUCTION_WIDTH-1:0] jump_offset =
        instruction_value - JUMP_BASE;
    wire [IO_INDEX_WIDTH-1:0] wait_for_index =
        wait_for_offset[IO_INDEX_WIDTH-1:0];
    wire [IO_INDEX_WIDTH-1:0] shift_index =
        shift_offset[IO_INDEX_WIDTH-1:0];
    wire [IO_INDEX_WIDTH-1:0] io_mode_index =
        io_mode_offset[IO_INDEX_WIDTH-1:0];
    wire [COUNTER_INDEX_WIDTH-1:0] counter_index =
        counter_offset[COUNTER_INDEX_WIDTH-1:0];
    wire [1:0] jump_section = jump_offset[1:0];

    assign mem_addr_out = PC;
    assign mem_write_en = 1'b0;
    assign mem_data_out = {INSTRUCTION_WIDTH{1'b0}};

    initial begin
        if (INSTRUCTION_WIDTH != 5 || IO_PORTS != 4 ||
            COUNTER_BITS < 1 || COUNTER_BITS > 11 || MEMORY_ADDR_WIDTH < 2 ||
            SHIFT_REG_WIDTH < 2 || TICK_CYCLES < 1) begin
            $fatal(1,
                   "processor parameters do not match the 5-bit instruction map");
        end
        if (WAIT_TIMER != 0 ||
            WAIT_FOR_BASE + IO_PORTS != SHIFT_BASE ||
            SHIFT_BASE + IO_PORTS != TOGGLE_IO_MODE_BASE ||
            TOGGLE_IO_MODE_BASE + IO_PORTS != TOGGLE_WAIT_FOR_VALUE ||
            TOGGLE_WAIT_FOR_VALUE + 1 != TOGGLE_SHIFT_DIR ||
            TOGGLE_SHIFT_DIR + 1 != TOGGLE_COUNTER_BASE ||
            TOGGLE_COUNTER_BASE + COUNTER_BITS != SHIFT_ONE ||
            SHIFT_ONE + 1 != SHIFT_ZERO ||
            SHIFT_ZERO + 1 != JUMP_BASE ||
            JUMP_BASE + JUMP_COUNT > (1 << INSTRUCTION_WIDTH) ||
            (COUNTER_BITS == 11 &&
             JUMP_BASE + JUMP_COUNT != (1 << INSTRUCTION_WIDTH))) begin
            $fatal(1,
                   "instruction ranges must be contiguous and fit the 5-bit space");
        end
    end

    timer #(
        .COUNTER_BITS(COUNTER_BITS),
        .CLK_PERIOD_NS(CLK_PERIOD_NS),
        .TICK_CYCLES(TICK_CYCLES)
    ) timer_inst (
        .clk(clk),
        .rst_n(rst_n),
        .enable(!programming_mode),
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
            setup_complete <= 1'b0;
            wait_for_value <= 1'b0;
            shift_dir <= 1'b0;
            timer_wait_cycles <= {COUNTER_BITS{1'b0}};
            start_timer <= 1'b0;
            gpio_mode <= {IO_PORTS{1'b0}};
            gpio_write_en <= {IO_PORTS{1'b0}};
            gpio_out <= {IO_PORTS{1'b0}};
        end
        else if (!programming_mode) begin
            start_timer <= 1'b0;

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
                    if (instruction_value == WAIT_TIMER) begin
                        if (!setup_complete) begin
                            start_timer <= 1'b1;
                            setup_complete <= 1'b1;
                        end
                        else if (timer_done) begin
                            setup_complete <= 1'b0;
                            state <= FETCH_INSTRUCTION;
                        end
                    end
                    else if (instruction_value >= WAIT_FOR_BASE &&
                             instruction_value < WAIT_FOR_BASE + IO_PORTS) begin
                        if (!setup_complete) begin
                            gpio_write_en[wait_for_index] <= 1'b0;
                            setup_complete <= 1'b1;
                        end
                        else if (gpio_in[wait_for_index] == wait_for_value) begin
                            setup_complete <= 1'b0;
                            state <= FETCH_INSTRUCTION;
                        end
                    end
                    else if (instruction_value >= SHIFT_BASE &&
                             instruction_value < SHIFT_BASE + IO_PORTS) begin
                        if (!shift_dir) begin
                            gpio_write_en[shift_index] <= 1'b1;
                            shift_reg <= {1'b0, shift_reg[SHIFT_REG_WIDTH-1:1]};
                            gpio_out[shift_index] <= shift_reg[0];
                        end
                        else begin
                            gpio_write_en[shift_index] <= 1'b0;
                            shift_reg <= {
                                shift_reg[SHIFT_REG_WIDTH-2:0],
                                gpio_in[shift_index]
                            };
                        end
                        setup_complete <= 1'b0;
                        state <= FETCH_INSTRUCTION;
                    end
                    else if (instruction_value >= TOGGLE_IO_MODE_BASE &&
                             instruction_value <
                                 TOGGLE_IO_MODE_BASE + IO_PORTS) begin
                        gpio_mode[io_mode_index] <= ~gpio_mode[io_mode_index];
                        setup_complete <= 1'b0;
                        state <= FETCH_INSTRUCTION;
                    end
                    else if (instruction_value == TOGGLE_WAIT_FOR_VALUE) begin
                        wait_for_value <= ~wait_for_value;
                        setup_complete <= 1'b0;
                        state <= FETCH_INSTRUCTION;
                    end
                    else if (instruction_value == TOGGLE_SHIFT_DIR) begin
                        shift_dir <= ~shift_dir;
                        setup_complete <= 1'b0;
                        state <= FETCH_INSTRUCTION;
                    end
                    else if (instruction_value >= TOGGLE_COUNTER_BASE &&
                             instruction_value <
                                 TOGGLE_COUNTER_BASE + COUNTER_BITS) begin
                        timer_wait_cycles[counter_index] <=
                            ~timer_wait_cycles[counter_index];
                        setup_complete <= 1'b0;
                        state <= FETCH_INSTRUCTION;
                    end
                    else if (instruction_value == SHIFT_ONE) begin
                        shift_reg <= {shift_reg[SHIFT_REG_WIDTH-2:0], 1'b1};
                        setup_complete <= 1'b0;
                        state <= FETCH_INSTRUCTION;
                    end
                    else if (instruction_value == SHIFT_ZERO) begin
                        shift_reg <= {shift_reg[SHIFT_REG_WIDTH-2:0], 1'b0};
                        setup_complete <= 1'b0;
                        state <= FETCH_INSTRUCTION;
                    end
                    else if (instruction_value >= JUMP_BASE &&
                             instruction_value < JUMP_BASE + JUMP_COUNT) begin
                        PC <= {jump_section, {(MEMORY_ADDR_WIDTH-2){1'b0}}};
                        setup_complete <= 1'b0;
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
