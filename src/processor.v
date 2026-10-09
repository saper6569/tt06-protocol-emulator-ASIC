module processor #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD_RATE = 115_200,
    parameter IO_PORTS = 8,
    parameter MEMORY_WIDTH = 8,
    parameter MEMORY_ADDR_WIDTH = 8,
    parameter MEMORY_SIZE = 1 << MEMORY_ADDR_WIDTH,
    parameter SHIFT_REG_WIDTH = 8,
    parameter INSTRUCTION_WIDTH = 8,
    parameter
) 
(
    // Input
    input wire clk,
    input wire reset,
    input wire uart_rx,
    input wire [IO_PORTS-1:0] io_in,
    input wire [MEMORY_WIDTH-1:0] mem_in,
    output wire [MEMORY_WIDTH-1:0] mem_out,
    input wire [IO_PORTS-1:0] io_out,
    
    // Output
    output wire uart_tx,
    output wire [IO_PORTS-1:0] io_out,
    output wire [MEMORY_WIDTH-1:0] mem_out,
    output wire [SHIFT_REG_WIDTH-1:0] shift_reg_out,
    output wire [MEMORY_ADDR_WIDTH-1:0] mem_addr_out
);
    wire wait_case;    // 1 == time 0 == value
    wire shift_dir;     // 0 == in 1 == out
    reg  shift_reg[7:0];
    reg  timer_totaltime[15:0];
    reg  timer_currTime[15:0];

always @(posedge clk or !rst_n) begin
    if(!rst_n) begin
        //reset on rst
    end
    else begin
        //fetch
        //IR <- get addr[pc]

        if(IR[7:6] == 2b'0) // wait instruction 
            if(wait_case)  // wait for time
                //start timer 
                //poll timer until timer_current == 0 should be timer some signal
                //increment pc
            end
            else            // wait for val
                // operand includes address(32 distinct vals) to poll and val to poll for (1 or 0)
                if( mem[address] == val)
                    //increment pc
                end
                else
                    //do not increment pc
                end
            end

        end
        else if(IR[7:6] == 2b'1) // shift instruction; Operand includes address  maybe 32 vs maybe include shift dir in operand
            if(shift_dir) // out 
                //shift shift_reg MSB -> address LSB
                //pc++
            end
            else // in
                // shift mem[address] MSB -> shift_reg LSB
                // pc++
            end

        end
        else if(IR[7:6] == 2b'2) // toggle instruction Operand is address
            //mem[address] = ~mem[address]
            //pc++
        end
        else if(IR[7:6] == 2b'3) //  _____ instruction

        end


