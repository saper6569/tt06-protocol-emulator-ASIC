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
    localparam [1:0] FETCH_INSTRUCTION = 1'd0; // State for fetching instruction from memory
    localparam [1:0] EXECUTE_INSTRUCTION = 1'd1; // State for executing the fetched instruction

    reg state; // Current state of the processor
    reg [INSTRUCTION_WIDTH-1:0] IR; // Instruction Register to hold the current instruction
    reg [MEMORY_ADDR_WIDTH-1:0] PC; // Program Counter to hold the address of the next instruction to fetch
    reg [3:0] CONTROL_BITS; // 00: 

    reg shift_dir_control; // 1: out, 0: in:
    reg [SHIFT_REG_WIDTH-1:0] shift_reg;
    
    wire wait_case_control = IR[0]; // 0: wait for time, 1: wait for value
    reg setup_complete;
    reg [WAIT_CYCLES_WIDTH-1:0] timer_wait_cycles;
    reg start_timer;
    wire timer_done;

    localparam JUMP_BLOCK_WIDTH = MEMORY_SIZE / (INSTRUCTION_WIDTH - 2)
    localparam JUMP_PC_MULTIPLIER = &clog2(JUMP_BLOCK_WIDTH);

    assign mem_addr_out = PC; // Automaticcaly read instruction memory at PC

    timer #(
        .WIDTH(WAIT_CYCLES_WIDTH)
    ) timer_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_timer),
        .wait_cycles(timer_wait_cycles),
        .done(timer_done)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= FETCH_INSTRUCTION;
            PC <= {MEMORY_ADDR_WIDTH{1'b0}};
            IR <= {INSTRUCTION_WIDTH{1'b0}};
            setup_complete <= 1'b0;
            timer_wait_cycles <= {WAIT_CYCLES_WIDTH{1'b0}};
            start_timer <= 1'b0;
            gpio_mode <= {IO_PORTS{1'b0}};
            gpio_write_en <= {IO_PORTS{1'b0}};
            gpio_out <= {IO_PORTS{1'b0}};
        end
        else begin
            start_timer <= 1'b0;

            // cycle 1 fetch instruction, cycle 2 execute instruction
            case (state)
                FETCH_INSTRUCTION: begin
                  // change to async sram memory with data ready signal
                    IR <= mem_data_in;
                    PC <= PC + 1'b1;
                    state <= EXECUTE_INSTRUCTION;
                end

                EXECUTE_INSTRUCTION: begin
                    if (IR[7:6] == 2'b00)  begin // Wait cases
                        if ( IR == 0) begin // Do nothing instruction
                           state <= FETCH_INSTRUCTION; 
                        end
                        else if (wait_case_control) begin // Wait for N cycles
                            // toggles start_timer
                            if (!setup_complete) begin
                                start_timer <= 1'b1;
                                setup_complete <= 1'b1; // flags that the timer to run
                            end
                            else if (timer_done) begin // flagged by timer module
                                setup_complete <= 1'b0;
                                state <= FETCH_INSTRUCTION;
                            end
                        end
                        else begin // Wait for value
                            if (!setup_complete) begin
                                gpio_write_en[IR[5:0]] <= 0;
                                setup_complete <= 1'b1;
                            end
                            else if (gpio_in[IR[5:1]] == IR[0]) begin
                                setup_complete <= 1'b0;
                                state <= FETCH_INSTRUCTION;
                            end
                        end
                    end
                    else if (IR[7:6] == 2'b01) begin
                        if (!setup_complete) begin
                            gpio_write_en[IR[5:1]] <= IR[0]; 
                            setup_complete <= 1'b1
                        end
                        // Shift logic goes here
                        if (IR[0] == 1) begin // Shift out
                            shift_reg <= {1'b0, shift_reg[SHIFT_REG_WIDTH-1:1};
                            gpio_out[IR[5:1]] <= shift_reg[0];
                            setup_complete <= 1'b0;
                            state <= FETCH_INSTRUCTION;
                        end
                        else begin // Shift in
                            shift_reg <= {shift_reg[SHIFT_REG_WIDTH-2:0], gpio_in[IR[5:1]]};
                            setup_complete <= 1'b0;
                            state <= FETCH_INSTRUCTION;
                        end
                    end
                    else if (IR[7:6] == 2'b10) begin
                        if (IR[5:1] < SHIFT_REG_WIDTH) begin
                            shift_reg[IR[5:1]] <= IR[0]; // First adresses are allocated for shift_reg index
                            state <= FETCH_INSTRUCTION;
                        end
                        else begin
                            CONTROL_BITS[IR[5:1] - SHIFT_REG_WIDTH] <= IR[0]; // Set a control bit
                            state <= FETCH_INSTRUCTION;
                        end
                    end
                    else begin
                        PC <= IR[5:0] << JUMP_PC_MULTIPLIER; // jumps to code section
                        state <= FETCH_INSTRUCTION;
                    end
                end
                default: begin
                    state <= FETCH_INSTRUCTION;
                end
            endcase
        end
    end


//always @(posedge clk or !rst_n) begin
//     if(!rst_n) begin
//         //reset on rst
//     end
//     else begin
//         //fetch
//         //IR <- get addr[PC]

//         if(IR[7:6] == 2b'0) // wait instruction 
//             if(wait_case_control)  // wait for time
//                 start_timer <= 1'b1; // start timer
//                 //start timer 
//                 //poll timer until timer_current == 0 should be timer some signal
//                 //increment PC
//             end
//             else            // wait for val
//                 // operand includes address(32 distinct vals) to poll and val to poll for (1 or 0)
//                 if( mem[address] == val)
//                     //increment PC
//                 end
//                 else
//                     //do not increment PC
//                 end
//             end

//         end
//         else if(IR[7:6] == 2b'1) // shift instruction; Operand includes address  maybe 32 vs maybe include shift dir in operand
//             if(shift_dir) // out 
//                 //shift shift_reg MSB -> address LSB
//                 //PC++
//             end
//             else // in
//                 // shift mem[address] MSB -> shift_reg LSB
//                 // PC++
//             end

//         end
//         else if(IR[7:6] == 2b'2) // toggle instruction Operand is address
//             //mem[address] = ~mem[address]
//             //PC++
//         end
//         else if(IR[7:6] == 2b'3) //  _____ instruction

//         end
//     end
// end


