## How it works

The design is a small instruction-driven GPIO processor. It accepts a
configurable-width address and a flat instruction over a serial programming
interface, stores instructions in on-chip memory, and executes them using four
GPIO pins (IO0–IO3).
There is no opcode/operand split. The top-level `INSTRUCTION_WIDTH` parameter
is propagated to the programmer, instruction memory, and processor.
`INSTRUCTION_MEMORY_ADDR_WIDTH` sets the number of address bits; a value of
*n* provides `2^n` instructions (128 words by default). The instruction width
is 5 bits.

The serial interface uses `ui_in[7]` as program enable and `ui_in[6]` as data.
While program enable is high, shift in an
`INSTRUCTION_MEMORY_ADDR_WIDTH`-bit address followed by the 5-bit instruction,
most-significant bit first (`INSTRUCTION_MEMORY_ADDR_WIDTH + 5` bits total).
Lower program enable to commit the word.
Set `ui_in[5]` high to run the processor.

### Instruction map

| Value(s) | Instruction |
|----------|-------------|
| 0 | Wait for the programmed timer duration |
| 1–4 | Wait for IO0–IO3 to equal `wait_for_value` |
| 5–8 | Shift register to/from IO0–IO3 according to `shift_dir` |
| 9–12 | Toggle the IO0–IO3 mode bit |
| 13 | Toggle `wait_for_value` |
| 14 | Toggle `shift_dir` |
| 15–25 | Toggle timer counter bit 0–10 |
| 26 | Shift 1 into the register |
| 27 | Shift 0 into the register |
| 28–31 | Jump to one of four equal memory sections |

Reset sets `wait_for_value` and `shift_dir` to zero. With `shift_dir=0`, values
5–8 shift the register's least-significant bit out to the selected IO; with
`shift_dir=1`, the selected IO value shifts into the register. Jump values
28–31 select sections 0–3, each one quarter of the configured memory. Their
start addresses are 0, 32, 64, and 96 in the default 128-word instruction
memory.

### Timer parameters

The timer has a parameterized `COUNTER_BITS` width (11 by default),
`CLK_PERIOD_NS` (20 by default), and `TICK_CYCLES` (1 by default). One tick
lasts `TICK_CYCLES * CLK_PERIOD_NS` ns. Counter bit *b* represents
`2^b * TICK_CYCLES * CLK_PERIOD_NS` ns. The minimum nonzero wait is
`TICK_CYCLES * CLK_PERIOD_NS` ns; the maximum wait is
`(2^COUNTER_BITS - 1) * TICK_CYCLES * CLK_PERIOD_NS` ns. The prescaler uses a
clock-enable and does not create a derived clock. The 5-bit ISA reserves one
counter-toggle value per counter bit, starting at 15; the constant-shift and
jump bases follow that range. With the default 11-bit counter, the map covers
all values 0–31 exactly. The assembler's `--counter-bits N` option must match
the configured counter width. Smaller counter widths move the constant-shift
and jump ranges down, leaving unused values at the top of the 5-bit space.

### Migration from the previous encoding

| Previous instruction | Previous value(s) | New instruction/value(s) |
|----------------------|-------------------|--------------------------|
| Wait timer | 0 | Wait timer, 0 (unchanged) |
| Wait for low on IO0–IO3 | 1–4 | Wait for configured level, 1–4 (unchanged after reset) |
| Wait for low on IO4–IO7 | 5–8 | Removed; only four IO pins are supported |
| Wait for high on IO0–IO3 | 9–12 | Toggle `wait_for_value` with 13, then wait on the same IO with 1–4 respectively |
| Wait for high on IO4–IO7 | 13–16 | Removed; only four IO pins are supported |
| Shift register to IO0–IO3 | 17–20 | Shift direction defaults to output; values 5–8 |
| Shift register to IO4–IO7 | 21–24 | Removed; only four IO pins are supported |
| Shift IO0–IO3 into register | 25–28 | Toggle `shift_dir` with 14, then use values 5–8 |
| Shift IO4–IO7 into register | 29–32 | Removed; only four IO pins are supported |
| Toggle IO0–IO3 mode | 33–36 | Values 9–12 |
| Toggle IO4–IO7 mode | 37–40 | Removed; only four IO pins are supported |
| Toggle counter bit 0–10 | 41–51 | Values 15–25 |
| Toggle counter bit 11–16 | 52–57 | Removed; the counter is 11 bits |
| Shift 1 into register | 58 | 26 |
| Shift 0 into register | 59 | 27 |
| Jump to section 0–3 | 60–63 | Values 28–31 |

The previous encoding had no NOP value. Any program padding or terminal NOP
behavior must now use an explicit jump to the desired section.

### Testing

Run the Tiny Tapeout integration simulation with `cd test && make -B`.
Run a standalone building-block test with
`cd test && make -f Makefile.units UNIT=processor`. Other available units are
`timer`, `programmer`, `io_port`, `fifo`, and `flip_flop`.

## External hardware

No external hardware is required.
