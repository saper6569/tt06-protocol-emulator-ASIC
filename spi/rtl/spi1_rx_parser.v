/*
 * Parser for the single-processor receive link: commands and io pins.
 *
 * spi1_rx_serial turns the mosi/cs_n pins into bits and bytes. This module
 * decides what those bytes mean, and also receives data on the 8 io pins.
 * There is only one processor, so there is no routing and no processor id:
 * every frame acts on that one processor.
 *
 * ---------------------------------------------------------------------------
 * Frame formats (each [ ] is one byte, sent MSB first while cs_n is low)
 * ---------------------------------------------------------------------------
 *   RUN     : [CMD]                           enable = 1
 *   IDLE    : [CMD]                           enable = 0
 *   PROGRAM : [CMD] [ADDR] [I0] [I1] [I2] ...  mem[ADDR + k] = Ik
 *   CONFIG  : [CMD] [CFG0] [CFG1] ...         configure io pins (see below)
 *   TIMER   : [CMD] [HI] [LO]                 timer t countdown = {HI, LO}
 *
 *   CMD = {mode[1:0], 6'b000000}
 *         mode: 00 RUN, 01 PROGRAM, 10 CONFIG (pins or timer), 11 IDLE
 *         low 6 bits: reserved, ignored, except for mode 10 (below)
 *
 *   Mode 10 uses CMD = {2'b10, timer, t, 4'b0000}:
 *         timer [5]  0 = pin config, 1 = TIMER
 *         t     [4]  TIMER only: 0 = timer 1, 1 = timer 2
 *   TIMER takes exactly the next two bytes: the high byte, then the low byte.
 *   The timer value changes when the low byte arrives, so a frame cut short
 *   leaves it as it was. Bytes after the second are ignored.
 *
 * PROGRAM sends the start address once; each instruction byte after it goes to
 * the next address (wrapping 255 -> 0).
 *
 * CONFIG (pins): each CFG byte configures one of the 8 io pins:
 *   CFG = {pin[2:0], en, neg[2:0], mode}
 *     pin  [7:5]  which io pin this byte configures (the positive pin)
 *     en   [4]    1 = receive on this pin, 0 = pin not received
 *     neg  [3:1]  the io pin used as this pin's negative. neg == pin means
 *                 single ended; neg != pin means differential.
 *     mode [0]    output driver: 0 = push-pull, 1 = open-drain (pin_mode)
 *   Any number of CFG bytes may follow the command byte.
 *
 * ---------------------------------------------------------------------------
 * PROGRAM confirmation (CRC-8 + prog_ok)
 * ---------------------------------------------------------------------------
 *   1. On the command byte, prog_hold goes high: the processor is held in reset
 *      and its instruction memory port belongs to this receiver.
 *   2. Instructions are written to memory as they arrive.
 *   3. When cs_n goes high, crc_valid pulses for one cycle with crc_value =
 *      CRC-8 of every complete byte of the frame. spi1_tx_top sends it to the
 *      master as a CRC word.
 *   4. The master compares it with its own CRC:
 *        match    -> pulse prog_ok. prog_hold drops and the processor restarts
 *                    from address 0 (running if enable is 1).
 *        mismatch -> re-send the PROGRAM frame. The processor stays held.
 *   prog_ok never releases the processor while its PROGRAM frame is in progress.
 *
 * Timing: spi1_rx_serial registers the pins first, so every action happens one
 * clock after the rising edge that samples the bit causing it. All outputs are
 * registers. mem_we, mem_addr and mem_wdata are stable together for one cycle.
 *
 * ---------------------------------------------------------------------------
 * io pin receiving
 * ---------------------------------------------------------------------------
 *
 * Each pin has its own operation, set by a CONFIG byte (see CONFIG above):
 *
 *   disabled    pin_valid[i] stays 0.
 *   single ended (neg == pin). The pin is the bit: pin_bit[i] = io[i], and
 *               pin_valid[i] is high every cycle.
 *   differential (neg != pin)  pin i is the positive wire and pin neg[i] is its negative
 *               wire. pin_bit[i] = io[i], and pin_valid[i] is high only while
 *               the two wires disagree (io[i] != io[neg[i]]). When they are
 *               equal the pair is idle or invalid, so no bit is produced.
 *               The negative pin is only read; it gets no data output of its
 *               own unless it is also enabled as a pin.
 *
 * The pins go straight into flip-flops first, the same as the SPI pins, so
 * the only pin path is pin -> flop. Outputs are registers, one clock after
 * the sampling edge. Pins are sampled every clock on the shared clk.
 *
 * Reset leaves every pin disabled.
 */

module spi1_rx_parser (
    input wire clk,
    input wire rst_n, // synchronous, active low

    // From spi1_rx_serial
    input wire bit_valid,
    input wire byte_valid,
    input wire [7:0] byte_data,

    // From the master
    input wire prog_ok, // pin: PROGRAM CRC matched, release the processor

    // To the processor
    output reg enable,        // 1 = run, 0 = idle
    output reg mem_we,        // one-cycle write strobe for instruction memory
    output reg [7:0] mem_addr,
    output reg [7:0] mem_wdata,
    output reg prog_hold,     // hold the processor in reset

    // Countdown values from TIMER frames
    output reg [15:0] timer1_value,
    output reg [15:0] timer2_value,

    // The 8 io pins, as inputs, and what is received on them
    input wire [7:0] io_in,
    output reg [7:0] pin_bit,   // received bit of each pin
    output reg [7:0] pin_valid, // 1: pin_bit[i] is a real bit this cycle
    output reg [7:0] pin_mode,  // output driver of each pin: 0 push-pull, 1 open-drain

    // To spi1_tx_top (status word back to the master)
    output reg crc_valid,     // one-cycle pulse at the end of each PROGRAM frame
    output wire [7:0] crc_value
);
    // ---- Command decoding ----
    // cmd_mode is the top two bits of the first byte of a frame.
    localparam [1:0] MODE_RUN = 2'b00,
                     MODE_PROG = 2'b01,
                     MODE_CFG = 2'b10,
                     MODE_IDLE = 2'b11;

    // Frame state machine. The state says what the NEXT byte means:
    //   S_CMD       first byte of a frame: a command
    //   S_ADDR      PROGRAM: the start address
    //   S_INSTR     PROGRAM: an instruction (stays here for every byte)
    //   S_CFG       CONFIG (pins): a pin config byte (stays here)
    //   S_TIMER_HI  CONFIG (timer): the high half of the countdown
    //   S_TIMER_LO  CONFIG (timer): the low half, then go to S_SKIP
    //   S_SKIP      RUN/IDLE/TIMER done: ignore any extra bytes
    // Whenever bit_valid is low (cs_n high) the state returns to S_CMD.
    localparam [2:0] S_CMD = 3'd0,
                     S_ADDR = 3'd1,
                     S_INSTR = 3'd2,
                     S_CFG = 3'd3,
                     S_SKIP = 3'd4,
                     S_TIMER_HI = 3'd5,
                     S_TIMER_LO = 3'd6;

    // Pin config bytes are registered here, then decoded in the io pins
    // section below, so the byte decode is not on the same cycle as the
    // state machine.
    reg cfg_we;        // one-cycle strobe: cfg_byte is a pin config byte
    reg [7:0] cfg_byte;
    reg timer_sel;     // TIMER frame: 0 = timer 1, 1 = timer 2
    reg [7:0] timer_hi;

    reg [2:0] state;
    reg [7:0] waddr;   // address the next PROGRAM instruction goes to
    reg [7:0] crc;     // running CRC-8 of the current PROGRAM frame

    // prog_ok is a pin from the master: register it so it only has a pin ->
    // flop path. Not reset, so it follows the pin during reset.
    reg prog_ok_q;
    always @(posedge clk) prog_ok_q <= prog_ok;

    wire [1:0] cmd_mode = byte_data[7:6];

    // True while the current frame is a PROGRAM frame (address or instruction
    // byte expected). Used to hold off prog_ok and to detect the frame's end.
    wire in_program = (state == S_ADDR) || (state == S_INSTR);

    // The CRC is read by spi1_tx_top at the crc_valid pulse.
    assign crc_value = crc;

    // CRC-8, polynomial x^8 + x^2 + x + 1 (0x07), initial value 0, no
    // reflection and no final XOR. Folds one byte into the running CRC: XOR the
    // byte in, then shift out 8 bits, XORing in the polynomial each time a 1
    // falls off the top. The master must compute the same CRC over the same
    // bytes (command, address, then every instruction).
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
            state <= S_CMD;
            waddr <= 8'd0;
            crc <= 8'd0;
            enable <= 1'b0;
            mem_we <= 1'b0;
            mem_addr <= 8'd0;
            mem_wdata <= 8'd0;
            prog_hold <= 1'b0;
            cfg_we <= 1'b0;
            cfg_byte <= 8'd0;
            timer_sel <= 1'b0;
            timer_hi <= 8'd0;
            timer1_value <= 16'd0;
            timer2_value <= 16'd0;
            crc_valid <= 1'b0;
        end else begin
            // Strobes default low every cycle and are raised below for exactly
            // one cycle. Later assignments in this block override these.
            mem_we <= 1'b0;
            cfg_we <= 1'b0;
            crc_valid <= 1'b0;

            // prog_ok releases the processor unless its PROGRAM frame is
            // still arriving (incomplete, CRC not yet checked).
            if (prog_ok_q && !in_program)
                prog_hold <= 1'b0;

            if (!bit_valid) begin
                // Between frames: wait for a command byte. A partial last byte
                // is dropped, because it never raised byte_valid.
                state <= S_CMD;

                // A PROGRAM frame just ended so pulse crc_valid
                if (in_program)
                    crc_valid <= 1'b1;
            end else begin
                case (state)
                    S_CMD: if (byte_valid) begin
                        case (cmd_mode)
                            // RUN: start the processor. Nothing else in the
                            // frame matters.
                            MODE_RUN: begin
                                enable <= 1'b1;
                                state <= S_SKIP;
                            end

                            // IDLE: stop the processor (it keeps its state).
                            MODE_IDLE: begin
                                enable <= 1'b0;
                                state <= S_SKIP;
                            end

                            // Hold the processor in reset until the master
                            // confirms, and start a CRC that includes this
                            // command byte.
                            MODE_PROG: begin
                                prog_hold <= 1'b1;
                                crc <= crc8_byte(8'h00, byte_data);
                                state <= S_ADDR;
                            end

                            // CONFIG: bit 5 picks pins (0) or a timer (1), bit 4
                            // picks which timer. Remember the timer choice now,
                            // because the command byte is gone by the time the
                            // timer bytes arrive.
                            MODE_CFG: begin
                                timer_sel <= byte_data[4];
                                state <= byte_data[5] ? S_TIMER_HI : S_CFG;
                            end
                        endcase
                    end

                    // PROGRAM, second byte: the start address. No write yet.
                    S_ADDR: if (byte_valid) begin
                        waddr <= byte_data;
                        crc <= crc8_byte(crc, byte_data);
                        state <= S_INSTR;
                    end

                    // PROGRAM, every byte after that: an instruction.
                    S_INSTR: if (byte_valid) begin
                        mem_addr <= waddr;
                        mem_wdata <= byte_data;
                        mem_we <= 1'b1;
                        waddr <= waddr + 8'd1;
                        crc <= crc8_byte(crc, byte_data);
                    end

                    // CONFIG: every byte configures one pin.
                    S_CFG: if (byte_valid) begin
                        cfg_byte <= byte_data;
                        cfg_we <= 1'b1;
                    end

                    // TIMER, first byte: the high half. Not applied yet.
                    S_TIMER_HI: if (byte_valid) begin
                        timer_hi <= byte_data;
                        state <= S_TIMER_LO;
                    end

                    // TIMER, second byte: the low half. Apply both halves.
                    S_TIMER_LO: if (byte_valid) begin
                        if (timer_sel)
                            timer2_value <= {timer_hi, byte_data};
                        else
                            timer1_value <= {timer_hi, byte_data};
                        state <= S_SKIP;
                    end

                    // S_SKIP: RUN/IDLE already applied; ignore the rest.
                    default: ;
                endcase
            end
        end
    end

    // ---- io pins ----
    // Not reset: follows the pins during reset.
    reg [7:0] io_q;
    always @(posedge clk) io_q <= io_in;

    // Per-pin config, written when a CFG byte arrives (cfg_we):
    //   en       receive on this pin
    //   neg      which pin is the negative wire (own number = single ended)
    //   pin_mode output driver, handed out to whoever drives the pads
    reg [7:0] en;
    reg [23:0] neg;             // neg[3*i +: 3]: negative pin of pin i

    // Which pin the current CFG byte is for.
    wire [2:0] cfg_pin = cfg_byte[7:5];

    always @(posedge clk) begin
        if (!rst_n) begin
            en <= 8'd0;
            pin_mode <= 8'd0;
            neg <= 24'd0;
        end else if (cfg_we) begin
            en[cfg_pin] <= cfg_byte[4];
            pin_mode[cfg_pin] <= cfg_byte[0];
            neg[3*cfg_pin +: 3] <= cfg_byte[3:1];
        end
    end

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_pin
            // Differential when the negative pin is a different pin.
            wire diff = neg[3*i +: 3] != i;
            // Current level of the negative pin (io_q is the registered pins).
            wire neg_val = io_q[neg[3*i +: 3]];

            always @(posedge clk) begin
                if (!rst_n) begin
                    pin_bit[i] <= 1'b0;
                    pin_valid[i] <= 1'b0;
                end else begin
                    // The bit is always the positive pin; pin_valid says
                    // whether it counts: enabled, and for a differential
                    // pair only while the two wires disagree.
                    pin_bit[i] <= io_q[i];
                    pin_valid[i] <= en[i] & (~diff | (io_q[i] ^ neg_val));
                end
            end
        end
    endgenerate
endmodule
