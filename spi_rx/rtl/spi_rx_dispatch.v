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
 * CRC-8: polynomial x^8 + x^2 + x + 1 (0x07), init 0x00, MSB first, no final
 * XOR (the common "CRC-8/SMBUS"). Check value: "123456789" -> 0xF4.
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
 * Between frames
 * ---------------------------------------------------------------------------
 * When no frame bit is being processed (cs_n high, or spi_rx_serial not yet
 * armed after reset), bit_valid is low and the parser returns to S_CMD. A
 * partial last byte is dropped. enable and prog_hold are left alone.
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
 *          !bit_valid (between frames) from any state
 *   +----------------------------------------------------+
 *   v                                                    |
 * S_CMD --RUN/IDLE--> S_SKIP                             |
 *   |   --PROGRAM---> S_ADDR --byte--> S_INSTR --+       |
 *   |                                    ^       | byte: write, addr + 1
 *   |                                    +-------+       |
 *   +---- DATA -----> S_DATA (each bit -> data_bit) -----+
 */

module spi_rx_dispatch (
    input wire clk,
    input wire rst_n,      // synchronous, active low

    // ---- From spi_rx_serial (combinational, for the bit being processed) ----
    input wire bit_valid,        // 1: a frame bit is being processed this cycle
    input wire bit_data,         // that bit
    input wire byte_valid,       // 1: that bit is the 8th of a byte
    input wire [7:0] byte_data,  // the completed byte; only meaningful with byte_valid

    // ---- From the master ----
    input wire prog_ok,          // pin: PROGRAM CRC matched, release held processors

    // ---- To the processors ----
    // One bit per processor (bit i = processor i) unless noted.
    output reg [3:0] enable,     // 1 = run, 0 = idle. Set by RUN, cleared by IDLE.
    output reg [3:0] mem_we,     // one-cycle write strobe for that instruction memory
    output reg [7:0] mem_addr,   // shared by all memories; valid while a mem_we bit is high
    output reg [7:0] mem_wdata,  // shared by all memories; valid while a mem_we bit is high
    output reg data_bit,         // shared serial data; valid while a data_valid bit is high
    output reg [3:0] data_valid, // one-cycle strobe: data_bit is for that processor
    output reg [3:0] prog_hold,  // hold that processor in reset; its memory port is ours

    // ---- To spi_tx (status word back to the master) ----
    output reg crc_valid,        // one-cycle pulse at the end of each PROGRAM frame
    output wire [1:0] crc_id,    // processor that frame was for
    output wire [7:0] crc_value  // CRC-8 of the frame's complete bytes
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

    reg [2:0] state;

    // Processor selected by this frame's command byte. Captured once, at the
    // command byte, and used by every later byte of the frame. It isn't
    // cleared between frames because the next command byte always overwrites
    // it before it's used again.
    reg [1:0] id;

    // Address the next PROGRAM instruction byte goes to. Loaded from the
    // address byte, then incremented after every write (8 bits: 255 wraps to 0).
    reg [7:0] waddr;

    // Running CRC-8 of the current PROGRAM frame.
    reg [7:0] crc;

    // prog_ok is a pin: register it like the other RX inputs, so it only has
    // a pin -> flop path. Not reset, for the same reason as in spi_rx_serial.
    reg prog_ok_q;
    always @(posedge clk) prog_ok_q <= prog_ok;

    // Command byte fields. These are only meaningful in S_CMD with byte_valid
    // high, when byte_data is the command byte. Bits [3:0] are reserved and
    // ignored.
    wire [1:0] cmd_mode = byte_data[7:6];
    wire [1:0] cmd_id = byte_data[5:4];

    // One-hot versions of the processor ID, for the per-processor strobes:
    // id 0 -> 4'b0001, id 1 -> 4'b0010, id 2 -> 4'b0100, id 3 -> 4'b1000.
    //   id_onehot     uses the stored id, for bytes after the command byte.
    //   cmd_id_onehot uses the ID in the command byte arriving right now. It's
    //                 needed in S_CMD because id itself only updates at the end
    //                 of this clock edge.
    wire [3:0] id_onehot = 4'b0001 << id;
    wire [3:0] cmd_id_onehot = 4'b0001 << cmd_id;

    // A PROGRAM frame is in progress (its command byte has been decoded).
    wire in_program = (state == S_ADDR) || (state == S_INSTR);

    // The CRC report reads the registers directly. They only change at the
    // next frame's command byte, at least 9 cycles after crc_valid, and spi_tx
    // captures them on the crc_valid cycle.
    assign crc_id = id;
    assign crc_value = crc;

    // One byte of CRC-8 (poly 0x07, MSB first): the CRC after `data` is
    // appended to a message whose CRC so far is `c`. Unrolled by synthesis into
    // a small XOR network.
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

    always @(posedge clk) begin
        if (!rst_n) begin
            // ---- Reset: everything off, wait for a command byte ----
            // This is the only place besides IDLE that clears enable. It also
            // releases every held processor (enable is 0, so none of them run).
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
            // ---- Strobe defaults ----
            // These are pulses: cleared on every edge, and set below only on
            // the single edge where the event happens. That makes each one high
            // for exactly one cycle without needing its own counter.
            // (Nonblocking assignments: a later assignment in this block wins.)
            mem_we <= 4'b0000;
            data_valid <= 4'b0000;
            crc_valid <= 1'b0;

            // ---- Master confirmed the CRC(s) ----
            // Release every held processor whose PROGRAM frame is finished. If
            // a PROGRAM frame is in progress right now, keep its processor held.
            // If a new PROGRAM command arrives on this same edge, the case
            // statement below sets its bit again, and that later assignment wins.
            if (prog_ok_q)
                prog_hold <= in_program ? (prog_hold & id_onehot) : 4'b0000;

            if (!bit_valid) begin
                // ---- Between frames (cs_n high, or not armed after reset) ----
                // Go back to waiting for a command byte. A partial last byte is
                // dropped, because it never raised byte_valid.
                state <= S_CMD;

                // A PROGRAM frame just ended (this is the first cycle after
                // it, since state leaves S_ADDR/S_INSTR right here): report its
                // CRC to the master. prog_hold stays high until prog_ok.
                if (in_program)
                    crc_valid <= 1'b1;
            end else begin
                // ---- A frame bit is being processed ----
                case (state)
                    // Waiting for the command byte. Bits 1..7 just shift in
                    // inside spi_rx_serial; on the 8th (byte_valid) the whole
                    // byte is available and gets decoded here.
                    S_CMD: if (byte_valid) begin
                        // Remember which processor this frame is for.
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
                            // or corrupted program. Start a fresh CRC with the
                            // command byte itself.
                            MODE_PROG: begin
                                prog_hold[cmd_id] <= 1'b1;
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
                        mem_addr <= waddr;
                        mem_wdata <= byte_data;
                        mem_we <= id_onehot;
                        waddr <= waddr + 8'd1;
                        crc <= crc8_byte(crc, byte_data);
                    end

                    // DATA: no byte grouping. Every bit passes straight through
                    // with a one-cycle valid strobe for the selected processor
                    // only. Stay here until cs_n goes high.
                    S_DATA: begin
                        data_bit <= bit_data;
                        data_valid <= id_onehot;
                    end

                    // S_SKIP (and any unused state encoding): RUN/IDLE has
                    // already been applied; ignore everything else in this
                    // frame. The !bit_valid branch above brings us back to
                    // S_CMD when cs_n goes high.
                    default: ;
                endcase
            end
        end
    end
endmodule
