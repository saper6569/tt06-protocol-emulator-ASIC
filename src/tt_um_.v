/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_example (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // All output pins must be assigned. If not used, assign to 0.
  assign uo_out  = ui_in + uio_in;  // Example: ou_out is the sum of ui_in and uio_in
  assign uio_out = 0;
  assign uio_oe  = 0;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, clk, rst_n, 1'b0};




  // Interface controls & inputs
  wire program_data;
  wire program_en;

  // Interconnect wires between programmer and instruction_memory
  wire [7:0] program_address;
  wire [7:0] program_instruction;
  wire program_write_en;

  // Memory read output
  wire [7:0] instruction_data;

  programmer #(
      .INSTRUCTION_WIDTH(8),
      .ADDRESS_WIDTH(8)
  ) programmer_inst (
      .clk(clk),
      .rst_n(rst_n),

      .program_data(program_data),
      .program_en(program_en),

      .address_out(program_address),
      .instruction_out(program_instruction),

      .write_en(program_write_en)
  );


  instruction_memory #(
      .ADDR_WIDTH(8),
      .DATA_WIDTH(8)
  ) instruction_memory_inst (
      .clk(clk),

      .w_en(program_write_en),
      .data_in(program_instruction),
      .addr(program_address),

      .data(instruction_data)
  );
    
endmodule
