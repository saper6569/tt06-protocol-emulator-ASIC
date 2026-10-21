<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The design is a small instruction-driven GPIO processor. It accepts a 6-bit
instruction and an 8-bit address over a serial programming interface, stores
instructions in on-chip memory, and executes them to configure and drive the
eight bidirectional GPIO pins. Each instruction is one flat 6-bit value; there
is no opcode/operand split.

The serial programming interface uses `ui_in[7]` as program enable and
`ui_in[6]` as data. While program enable is high, shift in the 8-bit address
followed by the 6-bit instruction, most-significant bit first (14 bits total).
Lower program enable to commit the word. Set `ui_in[5]` high to run the processor.

### Instruction map

| Value(s) | Instruction |
|----------|-------------|
| 0 | Wait for the timer |
| 1–8 | Wait for IO0–IO7 to be low |
| 9–16 | Wait for IO0–IO7 to be high |
| 17–24 | Shift a register bit to IO0–IO7 |
| 25–32 | Shift IO0–IO7 into the register |
| 33–40 | Toggle the IO0–IO7 mode bit |
| 41–57 | Toggle timer wait-counter bit 0–16 |
| 58 | Shift 1 into the register |
| 59 | Shift 0 into the register |
| 60–63 | Jump to one of four equal memory sections |

Jump values 60, 61, 62, and 63 target the first address of sections 0, 1, 2,
and 3 respectively. The section size is the instruction-memory size divided by
four.

## How to test

Run the Tiny Tapeout integration simulation with `cd test && make -B`.
Run a standalone building-block test with
`cd test && make -f Makefile.units UNIT=processor`. Other available units are
`timer`, `programmer`, `io_port`, `fifo`, and `flip_flop`.

## External hardware

No external hardware is required.
