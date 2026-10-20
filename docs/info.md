<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The design is a small instruction-driven GPIO processor. It accepts an 8-bit
instruction and address over a serial programming interface, stores instructions
in on-chip memory, and executes them to configure and drive the eight bidirectional
GPIO pins. Instructions can wait for a GPIO level, shift data in or out, set
timer or GPIO-mode bits, and jump to an instruction block.

The serial programming interface uses `ui_in[7]` as program enable and
`ui_in[6]` as data. While program enable is high, shift in the 8-bit address
followed by the 8-bit instruction, most-significant bit first. Lower program
enable to commit the word. Set `ui_in[5]` high to run the processor.

## How to test

Run the Tiny Tapeout integration simulation with `cd test && make -B`.
Run a standalone building-block test with
`cd test && make -f Makefile.units UNIT=processor`. Other available units are
`timer`, `programmer`, `io_port`, `fifo`, and `flip_flop`.

## External hardware

No external hardware is required.
