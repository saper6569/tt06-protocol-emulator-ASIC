# Instruction encoder

Build the encoder with `make`. It emits the flat 5-bit instruction encoding
used by `src/processor.v`. With the default 11-bit timer counter, the map is:

| Value(s) | Instruction |
|----------|-------------|
| 0 | `wait timer` |
| 1–4 | `wait io0` through `wait io3` |
| 5–8 | `shift io0` through `shift io3` |
| 9–12 | `toggle io_mode io0` through `toggle io_mode io3` |
| 13 | `toggle wait_for_value` |
| 14 | `toggle shift_dir` |
| 15–25 | `toggle counter bit0` through `toggle counter bit10` |
| 26 | `shift 1` |
| 27 | `shift 0` |
| 28–31 | `jump 0` through `jump 3` |

The assembler reads one instruction per line and writes the corresponding
decimal value to standard output (or the `-o` file):

```text
wait timer
wait io2
shift io0
toggle io_mode io3
toggle wait_for_value
toggle shift_dir
toggle counter bit10
shift 1
shift 0
jump 3
```

Comments start with `#` or `;`. IO, counter-bit, and jump indices are
zero-based. Use `--counter-bits N` to match a non-default `COUNTER_BITS`
configuration; this shifts the constant-shift and jump values upward or
downward. The default 11-bit counter fills all 32 instruction values exactly.
Smaller counter widths leave unused values above the shifted jump range.
There is no NOP instruction; use a jump to the intended program section for a
terminal loop/park.
