/*
 * Dispatcher: the frame-level half of the receive-only link.
 *
 * spi_rx_serial turns the mosi/cs_n pins into bits and bytes. This module
 * decides what those bytes mean and drives the four processors.
 *
 * ---------------------------------------------------------------------------
 * Frame formats (each [ ] is one byte, sent MSB first while cs_n is low)
 * ---------------------------------------------------------------------------
 *   RUN     : [CMD]                           enable[id] = 1
 *   IDLE    : [CMD]                           enable[id] = 0
 *   PROGRAM : [CMD] [ADDR] [I0] [I1] [I2] ...  mem[id][ADDR + k] = Ik
 *   DATA    : [CMD] [D0] [D1] ...             bits streamed to processor id
 *
 *   CMD = {mode[1:0], id[1:0], 4'b0000}
 *         mode: 00 RUN, 01 PROGRAM, 10 DATA, 11 IDLE
 *         id:   processor 0..3
 *         low 4 bits: reserved, ignored
 *
 * PROGRAM sends the start address once; each instruction byte after it goes to
 * the next address (wrapping 255 -> 0).
 *
 * ---------------------------------------------------------------------------
 * PROGRAM confirmation (CRC-8 + prog_ok)
 * ---------------------------------------------------------------------------
 * There is no return path on this link, so the receiver reports what it got
 * over the TX link and the master confirms it:
 *   1. On the command byte, prog_hold[id] goes high: processor id is held in
 *      reset, and its instruction memory port belongs to this receiver.
 *   2. Instructions are written to memory as they arrive.
 *   3. When cs_n goes high, crc_valid pulses for one cycle with crc_id = id and
 *      crc_value = CRC-8 of every complete byte of the frame (command, address
 *      and instructions). spi_tx sends it to the master as a status word.
 *   4. The master compares it with its own CRC:
 *        match    -> pulse prog_ok. prog_hold drops and the processor restarts
 *                    from address 0 (running if enable[id] is 1).
 *        mismatch -> re-send the PROGRAM frame. The processor stays held, so
 *                    a corrupted program never runs.
 *   prog_ok releases every processor whose PROGRAM frame has finished. It
 *   never releases one whose frame is still in progress.
 *
 * ---------------------------------------------------------------------------
 * Timing
 * ---------------------------------------------------------------------------
 * spi_rx_serial registers the pins first, so every action happens one clock
 * after the rising edge that samples the bit causing it. All outputs are
 * registers. Memory writes are one address per cycle, with mem_we, mem_addr
 * and mem_wdata all stable for that whole cycle, as a single-port SRAM macro
 * needs. Nothing here ever clears or reads the memory.
 *
 * ---------------------------------------------------------------------------
 * States
 * ---------------------------------------------------------------------------
 *   S_CMD   wait for the command byte, then decode it
 *   S_ADDR  PROGRAM: wait for the start address
 *   S_INSTR PROGRAM: write each instruction byte, address + 1 each time
 *   S_DATA  DATA: forward every bit until the frame ends
 *   S_SKIP  RUN / IDLE: already done; ignore the rest of the frame
 *
 * ---------------------------------------------------------------------------
 * WORKED EXAMPLE: programming processor 2 with two instructions at address 0x10
 * ---------------------------------------------------------------------------
 * The master pulls cs_n low and sends these 5 bytes, then raises cs_n:
 *
 *   byte 0: 0x60   = 01 10 0000  -> mode = PROGRAM (01), id = 2 (10)
 *   byte 1: 0x10   start address
 *   byte 2: 0xAA   instruction  -> written to mem[2][0x10]
 *   byte 3: 0xBB   instruction  -> written to mem[2][0x11]
 *   (cs_n goes high)
 *
 * What the dispatcher does:
 *   byte 0 : state S_CMD  -> prog_hold[2] = 1, crc started, state = S_ADDR
 *   byte 1 : state S_ADDR -> waddr = 0x10, state = S_INSTR
 *   byte 2 : state S_INSTR-> mem_addr=0x10, mem_wdata=0xAA, mem_we=0100 (1 cycle)
 *   byte 3 : state S_INSTR-> mem_addr=0x11, mem_wdata=0xBB, mem_we=0100 (1 cycle)
 *   cs_n high: state -> S_CMD, crc_valid pulses once with crc_id=2.
 *   The master checks the CRC it received over TX, and pulses prog_ok
 *   -> prog_hold[2] drops, processor 2 starts from address 0.
 *
 * Another example, a RUN frame for processor 3: one byte 0x30 = 00 11 0000
 * (mode RUN, id 3) -> enable[3] = 1. Nothing else is needed.
 */

module spi_rx_dispatch (
    input wire clk,
    input wire rst_n, // synchronous, active low

    // From spi_rx_serial
    input wire bit_valid, // 1: a frame bit is being processed this cycle
    input wire bit_data,
    input wire byte_valid,  // 1: that bit is the 8th of a byte
    input wire [7:0] byte_data, // the completed byte; only meaningful with byte_valid

    // From the master
    input wire prog_ok, // pin: PROGRAM CRC matched, release held processors

    // To the processors, has one hot data for total 4 processors
    output reg [3:0] enable,  // 1 = run, 0 = idle. Set by RUN, cleared by IDLE.
    output reg [3:0] mem_we,  // one-cycle write strobe for instruction memory
    output reg [7:0] mem_addr,  // shared by all memories; valid while a mem_we bit is high
    output reg [7:0] mem_wdata, // shared by all memories; valid while a mem_we bit is high
    output reg data_bit,  // shared serial data; valid while a data_valid bit is high
    output reg [3:0] data_valid,  // one-cycle strobe
    output reg [3:0] prog_hold, // hold that processor in reset

    // To spi_tx (status word back to the master)
    output reg crc_valid, // one-cycle pulse at the end of each PROGRAM frame
    output wire [1:0] crc_id, // processor that frame was for
    output wire [7:0] crc_value // CRC-8 of the frame's complete bytes
);
    // Mode field, command byte bits [7:6].
    localparam [1:0] MODE_RUN = 2'b00,
                     MODE_PROG = 2'b01,
                     MODE_DATA = 2'b10,
                     MODE_IDLE = 2'b11;

    // Parser states. 3 bits for 5 states.
    localparam [2:0] S_CMD = 3'd0,
                     S_ADDR = 3'd1,
                     S_INSTR = 3'd2,
                     S_DATA = 3'd3,
                     S_SKIP = 3'd4;

    // Current state of the parser
    reg [2:0] state;

    // Processor selected by this frame's command byte. Captured once, at the
    // command byte, and used by every later byte of the frame. Every command
    // byte overwrites it, so it needs no clearing between frames. 
    reg [1:0] id;

    // Address the next PROGRAM instruction byte goes to. Loaded from the
    // address byte, then incremented after every write (8 bits: 255 wraps to 0).
    reg [7:0] waddr;

    // Running CRC-8 of the current PROGRAM frame.
    reg [7:0] crc;

    // prog_ok is a pin
    reg prog_ok_q;
    always @(posedge clk) prog_ok_q <= prog_ok;

    // Command byte fields. These are only meaningful in S_CMD with byte_valid
    // high, when byte_data is the command byte. Bits [3:0] are reserved and
    // ignored.
    // Example: byte_data = 8'b01_10_0000 -> cmd_mode = 01 (PROGRAM), cmd_id = 10 (2).
    // "byte_data[7:6]" means "bits 7 down to 6" (a slice of the vector).
    wire [1:0] cmd_mode = byte_data[7:6];
    wire [1:0] cmd_id = byte_data[5:4];

    // One hot encodings
    wire [3:0] id_onehot = 4'b0001 << id;
    wire [3:0] cmd_id_onehot = 4'b0001 << cmd_id;

    // A PROGRAM frame is in progress (its command byte has been decoded).
    wire in_program = (state == S_ADDR) || (state == S_INSTR);

    // The CRC report values
    assign crc_id = id;
    assign crc_value = crc;

    // Turns any sequence of bytes into a single 8-bit for error checking
    function [7:0] crc8_byte;
        input [7:0] c; 
        input [7:0] data; 
        integer k;  
        reg [7:0] x; 
        begin
            x = c ^ data;
            for (k = 0; k < 8; k = k + 1)
                x = x[7] ? ({x[6:0], 1'b0} ^ 8'h07) : {x[6:0], 1'b0};
            crc8_byte = x;
        end
    endfunction

    // Main state machine
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_CMD;
            id <= 2'd0;
            waddr <= 8'd0;
            crc <= 8'd0;
            enable <= 4'b0000;
            mem_we <= 4'b0000;
            mem_addr <= 8'd0;
            mem_wdata <= 8'd0;
            data_bit <= 1'b0;
            data_valid <= 4'b0000;
            prog_hold <= 4'b0000;
            crc_valid <= 1'b0;
        end else begin
            // These are pulses, so reseting them here allows 1 cycle high
            mem_we <= 4'b0000;
            data_valid <= 4'b0000;
            crc_valid <= 1'b0;

            // prog_ok releases all held processors, except one whose PROGRAM
            // frame is still arriving (incomplete, CRC not yet checked). 
            if (prog_ok_q)
                prog_hold <= in_program ? (prog_hold & id_onehot) : 4'b0000;

            if (!bit_valid) begin
                // Between frames (cs_n high, or not armed after reset)
                // Go back to waiting for a command byte. A partial last byte is
                // dropped, because it never raised byte_valid.
                state <= S_CMD;

                // A PROGRAM frame just ended so pulse crc_valid
                if (in_program)
                    crc_valid <= 1'b1;
            end else begin
                // A frame bit is being processed
                case (state)
                    // Waiting for the command byte. Bits 1..7 just shift in
                    // inside spi_rx_serial; on the 8th (byte_valid) the whole
                    // byte is available and gets decoded here.
                    S_CMD: if (byte_valid) begin
                        // Remember which processor this frame is for. Later
                        id <= cmd_id;
                        case (cmd_mode)
                            // RUN: start the processor now. If it's held for
                            // programming, it starts when prog_ok releases it.
                            // The rest of the frame is ignored.
                            MODE_RUN: begin
                                enable[cmd_id] <= 1'b1;
                                state <= S_SKIP;
                            end

                            // IDLE: stop the processor now. The rest of the
                            // frame is ignored.
                            MODE_IDLE: begin
                                enable[cmd_id] <= 1'b0;
                                state <= S_SKIP;
                            end

                            // PROGRAM: hold the processor in reset until the
                            // master confirms, so it never runs a half-loaded
                            // or corrupted program. Start a new CRC with the
                            // command byte itself
                            MODE_PROG: begin
                                // hold current processor.
                                prog_hold[cmd_id] <= 1'b1;
                                // CRC restarts from 0x00 and includes this
                                // command byte, so the CRC covers the whole
                                // frame (command, address, instructions).
                                crc <= crc8_byte(8'h00, byte_data);
                                state <= S_ADDR;
                            end

                            // DATA: every following bit goes to the processor.
                            MODE_DATA: state <= S_DATA;
                        endcase
                    end

                    // PROGRAM, second byte: the start address. No write yet.
                    S_ADDR: if (byte_valid) begin
                        waddr <= byte_data;
                        crc <= crc8_byte(crc, byte_data);
                        state <= S_INSTR;
                    end

                    // PROGRAM, every byte after that: an instruction. Put the
                    // address, the instruction and the selected processor's
                    // write enable out on the same edge, so all three are valid
                    // together for one cycle. The memory writes on the next
                    // edge. Then move to the next address and stay here.
                    S_INSTR: if (byte_valid) begin
                        mem_addr <= waddr;  // where to write
                        mem_wdata <= byte_data; // what to write
                        mem_we <= id_onehot;  // Strobes since defaults to 0
                        waddr <= waddr + 8'd1;  // next instruction goes one address up
                        crc <= crc8_byte(crc, byte_data); // Set new crc
                    end

                    // DATA: no byte grouping. Every bit passes straight through
                    // with a one-cycle valid strobe for the selected processor.
                    S_DATA: begin
                        data_bit <= bit_data; // the raw bit from the serial stage
                        data_valid <= id_onehot;
                    end

                    // S_SKIP (and any unused state encoding): RUN/IDLE has
                    // already been applied; ignore everything else in this
                    // frame.
                    default: ;
                endcase
            end
        end
    end
endmodule
