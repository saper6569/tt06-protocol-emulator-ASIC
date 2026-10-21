module processor #(
    parameter CLK_FREQ = 50_000_000,
    parameter IO_PORTS = 8,
    parameter MEMORY_ADDR_WIDTH = 8,
    parameter MEMORY_SIZE = 1 << MEMORY_ADDR_WIDTH,
    parameter SHIFT_REG_WIDTH = 8,
    parameter INSTRUCTION_WIDTH = 6,
    parameter WAIT_CYCLES_WIDTH = 17
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
    localparam [INSTRUCTION_WIDTH-1:0] WAIT0_BASE = 1;
    localparam [INSTRUCTION_WIDTH-1:0] WAIT1_BASE = 9;
    localparam [INSTRUCTION_WIDTH-1:0] SHIFT_TO_IO_BASE = 17;
    localparam [INSTRUCTION_WIDTH-1:0] SHIFT_INTO_REG_BASE = 25;
    localparam [INSTRUCTION_WIDTH-1:0] TOGGLE_IO_MODE_BASE = 33;
    localparam [INSTRUCTION_WIDTH-1:0] TOGGLE_COUNTER_BASE = 41;
    localparam [INSTRUCTION_WIDTH-1:0] SHIFT_ONE = 58;
    localparam [INSTRUCTION_WIDTH-1:0] SHIFT_ZERO = 59;
    localparam [INSTRUCTION_WIDTH-1:0] JUMP_BASE = 60;
    localparam integer JUMP_COUNT = 4;
    localparam [INSTRUCTION_WIDTH-1:0] JUMP_RANGE_WIDTH = 4;

    reg [1:0] state;
    reg [INSTRUCTION_WIDTH-1:0] IR;
    reg [MEMORY_ADDR_WIDTH-1:0] PC;
    reg [SHIFT_REG_WIDTH-1:0] shift_reg;
    reg setup_complete;
    reg [WAIT_CYCLES_WIDTH-1:0] timer_wait_cycles;
    reg start_timer;
    wire timer_done;

    wire [INSTRUCTION_WIDTH-1:0] instruction_value = IR;
    wire [INSTRUCTION_WIDTH-1:0] wait0_offset = instruction_value - WAIT0_BASE;
    wire [INSTRUCTION_WIDTH-1:0] wait1_offset = instruction_value - WAIT1_BASE;
    wire [INSTRUCTION_WIDTH-1:0] shift_to_io_offset =
        instruction_value - SHIFT_TO_IO_BASE;
    wire [INSTRUCTION_WIDTH-1:0] shift_into_reg_offset =
        instruction_value - SHIFT_INTO_REG_BASE;
    wire [INSTRUCTION_WIDTH-1:0] io_mode_offset =
        instruction_value - TOGGLE_IO_MODE_BASE;
    wire [INSTRUCTION_WIDTH-1:0] counter_offset =
        instruction_value - TOGGLE_COUNTER_BASE;
    wire [2:0] wait0_index = wait0_offset[2:0];
    wire [2:0] wait1_index = wait1_offset[2:0];
    wire [2:0] shift_to_io_index = shift_to_io_offset[2:0];
    wire [2:0] shift_into_reg_index = shift_into_reg_offset[2:0];
    wire [2:0] io_mode_index = io_mode_offset[2:0];
    wire [4:0] counter_index = counter_offset[4:0];
    wire [INSTRUCTION_WIDTH-1:0] jump_offset = instruction_value - JUMP_BASE;
    wire [1:0] jump_section = jump_offset[1:0];

    initial begin
        if (INSTRUCTION_WIDTH != 6 ||
            IO_PORTS != 8 ||
            WAIT_CYCLES_WIDTH != 17 ||
            MEMORY_ADDR_WIDTH < 2 ||
            MEMORY_SIZE != (1 << MEMORY_ADDR_WIDTH) ||
            MEMORY_SIZE % JUMP_COUNT != 0) begin
            $fatal(1, "instruction map requires 6-bit instructions, 8 IOs, 17 counter bits, and memory divisible into four sections");
        end
        if (WAIT0_BASE != WAIT_TIMER + 1 ||
            WAIT1_BASE != WAIT0_BASE + IO_PORTS ||
            SHIFT_TO_IO_BASE != WAIT1_BASE + IO_PORTS ||
            SHIFT_INTO_REG_BASE != SHIFT_TO_IO_BASE + IO_PORTS ||
            TOGGLE_IO_MODE_BASE != SHIFT_INTO_REG_BASE + IO_PORTS ||
            TOGGLE_COUNTER_BASE != TOGGLE_IO_MODE_BASE + IO_PORTS ||
            SHIFT_ONE != TOGGLE_COUNTER_BASE + WAIT_CYCLES_WIDTH ||
            SHIFT_ZERO != SHIFT_ONE + 1 ||
            JUMP_BASE != SHIFT_ZERO + 1 ||
            JUMP_BASE + JUMP_RANGE_WIDTH - 1 !=
                {INSTRUCTION_WIDTH{1'b1}}) begin
            $fatal(1, "instruction ranges must cover values 0 through 63 exactly once");
        end
    end

    assign mem_addr_out = PC;
    assign mem_write_en = 1'b0;
    assign mem_data_out = {INSTRUCTION_WIDTH{1'b0}};

    timer #(
        .WIDTH(WAIT_CYCLES_WIDTH)
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
            timer_wait_cycles <= {WAIT_CYCLES_WIDTH{1'b0}};
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
                    else if (instruction_value >= WAIT0_BASE &&
                             instruction_value < WAIT1_BASE) begin
                        if (!setup_complete) begin
                            gpio_write_en[wait0_index] <= 1'b0;
                            setup_complete <= 1'b1;
                        end
                        else if (!gpio_in[wait0_index]) begin
                            setup_complete <= 1'b0;
                            state <= FETCH_INSTRUCTION;
                        end
                    end
                    else if (instruction_value >= WAIT1_BASE &&
                             instruction_value < SHIFT_TO_IO_BASE) begin
                        if (!setup_complete) begin
                            gpio_write_en[wait1_index] <= 1'b0;
                            setup_complete <= 1'b1;
                        end
                        else if (gpio_in[wait1_index]) begin
                            setup_complete <= 1'b0;
                            state <= FETCH_INSTRUCTION;
                        end
                    end
                    else if (instruction_value >= SHIFT_TO_IO_BASE &&
                             instruction_value < SHIFT_INTO_REG_BASE) begin
                        gpio_write_en[shift_to_io_index] <= 1'b1;
                        shift_reg <= {1'b0, shift_reg[SHIFT_REG_WIDTH-1:1]};
                        gpio_out[shift_to_io_index] <= shift_reg[0];
                        setup_complete <= 1'b0;
                        state <= FETCH_INSTRUCTION;
                    end
                    else if (instruction_value >= SHIFT_INTO_REG_BASE &&
                             instruction_value < TOGGLE_IO_MODE_BASE) begin
                        gpio_write_en[shift_into_reg_index] <= 1'b0;
                        shift_reg <= {shift_reg[SHIFT_REG_WIDTH-2:0],
                                      gpio_in[shift_into_reg_index]};
                        setup_complete <= 1'b0;
                        state <= FETCH_INSTRUCTION;
                    end
                    else if (instruction_value >= TOGGLE_IO_MODE_BASE &&
                             instruction_value < TOGGLE_COUNTER_BASE) begin
                        gpio_mode[io_mode_index] <= ~gpio_mode[io_mode_index];
                        setup_complete <= 1'b0;
                        state <= FETCH_INSTRUCTION;
                    end
                    else if (instruction_value >= TOGGLE_COUNTER_BASE &&
                             instruction_value < SHIFT_ONE) begin
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
                    else if (instruction_value >= JUMP_BASE) begin
                        // The top two address bits select one of four equal sections.
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
