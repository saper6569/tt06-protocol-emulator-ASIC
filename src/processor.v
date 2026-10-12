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
    reg [INSTRUCTION_WIDTH-1:0] ret_addr;

    reg shift_dir_control;
    reg [SHIFT_REG_WIDTH-1:0] shift_reg;

    wire wait_case_control = IR[0]; // 0: wait for time, 1: wait for value
    reg timer_wait_active;
    reg [WAIT_CYCLES_WIDTH-1:0] timer_wait_cycles;
    reg start_timer;
    wire timer_done;

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
            timer_wait_active <= 1'b0;
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
                    IR <= mem_data_in;
                    PC <= PC + 1'b1;
                    state <= EXECUTE_INSTRUCTION;
                end

                EXECUTE_INSTRUCTION: begin
                    if (IR[7:6] == 2'b00) begin
                        if (wait_case_control) begin
                            // toggles start_timer
                            if (!timer_wait_active) begin
                                start_timer <= 1'b1;
                                timer_wait_active <= 1'b1; // flags that the timer is running
                            end
                            else if (timer_done) begin
                                timer_wait_active <= 1'b0;
                                state <= FETCH_INSTRUCTION;
                            end
                        end
                        else begin
                            // wait for value
                            if (gpio_in[IR[5:0]] == IR[6]) begin
                                state <= FETCH_INSTRUCTION;
                            end
                        end
                    end
                    else if () begin
                        
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


