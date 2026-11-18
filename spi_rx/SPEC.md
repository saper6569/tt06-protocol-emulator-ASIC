# Receive link (master → ASIC)

| File | Contents |
|---|---|
| [rtl/spi_rx_serial.v](rtl/spi_rx_serial.v) | Input registers, bit counter, shift register: pins → bits and bytes |
| [rtl/spi_rx_dispatch.v](rtl/spi_rx_dispatch.v) | Frame state machine: ENABLE registers, memory writes, DATA bits, PROGRAM CRC and hold |
| [rtl/spi_rx_top.v](rtl/spi_rx_top.v) | The two above, with the interface below |

The CRC report goes back to the master over the transmit link, [`spi_tx`](../spi_tx/SPEC.md).

## 1. Protocol

### Signals

| Signal | Dir (at ASIC) | Description |
|---|---|---|
| `clk` | in | Board clock, supplied by the master. Free-running. |
| `rst_n` | in | Active-low reset, synchronous to `clk` |
| `cs_n` | in | Frame select, active low. Driven on the falling edge of `clk`. |
| `mosi` | in | Data, MSB first, one bit per clock. Driven on the falling edge of `clk`. |
| `prog_ok` | in | Master's confirmation that a PROGRAM CRC matched. Driven on the falling edge, high for at least 1 cycle. |

The receiver samples `cs_n`, `mosi` and `prog_ok` into flip-flops on the rising edge, with no logic in front of them. A bit is valid only in a cycle where `cs_n` is sampled low. A frame is a run of such cycles, and it is always a whole number of bytes.

### Command byte

The first byte of every frame:

8 bits per entry, which are displayed as 2 hex values bellow.

| Bits | 7:6 | 5:4 | 3:0 |
|---|---|---|---|
| Field | mode | processor ID | reserved: sent as 0, ignored |

| Mode | Code | id 0 | id 1 | id 2 | id 3 | Bytes after the command | Action |
|---|---|---|---|---|---|---|---|
| RUN | 00 | `00` | `10` | `20` | `30` | none (any are ignored) | `enable[id] = 1` |
| PROGRAM | 01 | `40` | `50` | `60` | `70` | start address, then instructions | hold processor `id` in reset, write `mem[id][addr + k] = Ik`, report CRC, release on `prog_ok` |
| DATA | 10 | `80` | `90` | `A0` | `B0` | data bytes until `cs_n` goes high | each bit goes to processor `id` with a strobe |
| IDLE | 11 | `C0` | `D0` | `E0` | `F0` | none (any are ignored) | `enable[id] = 0` |

### Frame formats

```
CMD = {mode, id, 4'b0000}
RUN / IDLE : [CMD]
PROGRAM    : [CMD] [ADDR] [I0] [I1] [I2] ...      I0 -> ADDR, I1 -> ADDR+1, ... (255 wraps to 0)
DATA       : [CMD] [D0] [D1] ... [Dn]
```

### PROGRAM and confirmation

1. The command byte sets `prog_hold[id]`. Processor `id` is held in reset and its instruction-memory port belongs to the receiver.
2. Each instruction byte is written as it arrives. Nothing else in the memory is touched: no clear, no reads.
3. When `cs_n` goes high, the receiver reports the CRC-8 of every complete byte of the frame (command, address and instructions) over the TX link as a status word `{1, id, crc}`.
4. The master compares it with its own CRC:
   - **Match:** pulse `prog_ok`. Every processor whose PROGRAM frame has finished is released, and restarts from address 0 (running if its `enable` bit is 1).
   - **Mismatch:** send the PROGRAM frame again. The processor stays held the whole time, so a corrupted program never runs.

`prog_ok` never releases a processor whose PROGRAM frame is still in progress. A RUN for a held processor sets its `enable` bit; it starts when it's released.

**CRC-8:** polynomial `x⁸ + x² + x + 1` (`0x07`), initial value `0x00`, MSB first, no reflection, no final XOR. This is the common CRC-8/SMBUS. Check value: CRC of ASCII `"123456789"` = `0xF4`.

### Example frames (hex, sent left to right, each byte MSB first)

| Example | Frame(s) | Result |
|---|---|---|
| RUN processor 0 | `00` | `enable[0] = 1` |
| IDLE processor 0 | `C0` | `enable[0] = 0` |
| PROGRAM processor 2: 0x10 ← A5, 0x11 ← 3C | `60 10 A5 3C` | TX status word `{1, 2, 1A}`, then the master pulses `prog_ok` |
| DATA to processor 1: B4, 0F | `90 B4 0F` | 16 bits on `data_bit`, `data_valid[1]` |
| Back to back: PROGRAM p3 0x20 ← 77, then RUN p3 | `70 20 77`, `cs_n` high for 1 cycle, `30` | p3 runs after `prog_ok` |
| PROGRAM cut inside an instruction byte | `40 55` + 4 bits | no write; CRC of `40 55` reported |

## 2. Timing diagrams

How to read them: each column is one rising edge of `clk`, numbered from 0. The `cs_n` and `mosi` rows show the value **sampled** at that edge (the master set it on the falling edge just before). Every output row shows the value **just after** that edge.

Because the inputs are registered first, every action happens **one edge after** the edge that samples the bit causing it. These diagrams were taken from simulation.

### RUN processor 0 (`00`), then IDLE processor 0 (`C0`), back to back

```
edge        0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19
cs_n        1  0  0  0  0  0  0  0  0  1  0  0  0  0  0  0  0  0  1  1
mosi        .  0  0  0  0  0  0  0  0  .  1  1  0  0  0  0  0  0  .  .
enable[0]   0  0  0  0  0  0  0  0  0  1  1  1  1  1  1  1  1  1  0  0
```

The 8th bit of `00` is sampled on edge 8, so `enable[0]` rises on edge 9. The 8th bit of `C0` is sampled on edge 17, so it falls on edge 18. One cycle of `cs_n` high (edge 9) is enough between frames.

### PROGRAM processor 2 (`60 10 A5 3C`), CRC report and confirmation

```
edges       1..8   9..16   17..24   25..32   33     34    36..46            47..   N     N+1
cs_n        0      0       0        0        1      1     1                 1      1     1
byte        60     10      A5       3C       .      .     .                 .      .     .
prog_hold   0      4 (from edge 9) ........................................................ 0
mem_we      0      0       0        4 @25    4 @33  0     0                 0
mem_addr    .      .       .        10 @25   11     11
mem_wdata   .      .       .        A5 @25   3C     3C
crc_valid   0      0       0        0        0      1     0                 0
tx_cs_n     1      1       1        1        1      1     0 (11 bits)       1
miso                                                      1 10 0001_1010    = {status 1, id 2, CRC 1A}
prog_ok                                                                            1 (sampled at N)
```

- **Edge 9:** `prog_hold[2]` rises, one edge after the command byte's 8th bit (edge 8).
- **Edge 25:** writes `mem[0x10] = A5`. The byte's last bit was sampled on edge 24.
- **Edge 33:** writes `mem[0x11] = 3C`, the auto-incremented address. Each write strobe is high for one cycle, with `mem_addr` and `mem_wdata` stable alongside it.
- **Edge 33** also samples `cs_n` high, so `crc_valid` pulses on edge 34.
- **Edges 36–46:** the status word goes out on TX, 11 bits: `1`, `10`, `0001_1010`.
- **Edge N:** `prog_ok` is sampled high, so `prog_hold[2]` drops on edge N+1. Processor 2 restarts from address 0.

### DATA to processor 1 (`90 B4 0F`)

```
edge        8   9  10 11 12 13 14 15 16 17  18 19 20 21 22 23 24 25  26
cs_n        0   0  0  0  0  0  0  0  0  0   0  0  0  0  0  0  0  1   1
mosi        0   1  0  1  1  0  1  0  0  0   0  0  0  1  1  1  1  .   .
data_bit    .   .  1  0  1  1  0  1  0  0   0  0  0  0  1  1  1  1   1 (held)
data_valid  0   0  2  2  2  2  2  2  2  2   2  2  2  2  2  2  2  2   0     (2 = 4'b0010, processor 1)
```

The command byte's last bit is sampled on edge 8. Each data bit sampled on edge `n` appears on `data_bit`, with `data_valid[1]` high, on edge `n+1`.

## 3. State machines

### Serial receiver (`spi_rx_serial`)

Registers: `mosi_q`, `cs_n_q` (input registers, not reset), `bit_cnt[2:0]`, `shift[6:0]`, `armed`.

| Condition at rising edge | Action |
|---|---|
| always | `mosi_q = mosi`, `cs_n_q = cs_n` |
| `rst_n` low | `bit_cnt = 0`, `armed = 0` |
| `cs_n_q` high | `bit_cnt = 0`, `armed = 1` |
| `cs_n_q` low and `armed` | shift `mosi_q` into `shift`, `bit_cnt++` (wraps 7 → 0) |
| `cs_n_q` low and not `armed` | nothing (reset was released mid-frame; wait for `cs_n` high) |

Combinational outputs, for the bit in `mosi_q`:
- `bit_valid = armed & ~cs_n_q`
- `byte_valid = bit_valid & (bit_cnt == 7)`
- `byte_data = {shift, mosi_q}`

The input registers aren't reset on purpose. During reset they keep following the pins, so right after reset `cs_n_q` shows the real `cs_n`, and a frame already in progress isn't mistaken for a new one.

### Dispatcher (`spi_rx_dispatch`)

States: `S_CMD`, `S_ADDR`, `S_INSTR`, `S_DATA`, `S_SKIP`. Extra registers: `id[1:0]`, `waddr[7:0]`, `crc[7:0]`, `prog_ok_q`, plus the output registers.

`mem_we`, `data_valid` and `crc_valid` default to 0 on every edge, which makes them one-cycle strobes.

| State | Condition | Next state | Action |
|---|---|---|---|
| any | `rst_n` low | `S_CMD` | all outputs 0, including `enable` and `prog_hold` |
| any | `prog_ok_q` | (unchanged) | `prog_hold = 0`, except the processor of a PROGRAM frame in progress |
| `S_ADDR`/`S_INSTR` | `!bit_valid` (frame ended) | `S_CMD` | `crc_valid = 1` (report `{id, crc}`); `prog_hold` stays |
| other | `!bit_valid` | `S_CMD` | none (`enable` and `prog_hold` kept) |
| `S_CMD` | `byte_valid`, RUN | `S_SKIP` | `id = cmd_id`, `enable[cmd_id] = 1` |
| `S_CMD` | `byte_valid`, IDLE | `S_SKIP` | `id = cmd_id`, `enable[cmd_id] = 0` |
| `S_CMD` | `byte_valid`, PROGRAM | `S_ADDR` | `id = cmd_id`, `prog_hold[cmd_id] = 1`, `crc = CRC(byte)` |
| `S_CMD` | `byte_valid`, DATA | `S_DATA` | `id = cmd_id` |
| `S_ADDR` | `byte_valid` | `S_INSTR` | `waddr = byte`, update `crc` |
| `S_INSTR` | `byte_valid` | `S_INSTR` | `mem_addr = waddr`, `mem_wdata = byte`, `mem_we[id] = 1`, `waddr++`, update `crc` |
| `S_DATA` | `bit_valid` | `S_DATA` | `data_bit = mosi_q`, `data_valid[id] = 1` |
| `S_SKIP` | `bit_valid` | `S_SKIP` | none: extra bytes ignored |

```
           !bit_valid from any state (PROGRAM: report CRC)
   +----------------------------------------------------+
   v                                                    |
 S_CMD --RUN/IDLE byte--> S_SKIP                        |
   |  --PROGRAM byte----> S_ADDR --byte--> S_INSTR --+  |
   |                                         ^       | byte: write, addr + 1
   |                                         +-------+  |
   +----DATA byte-------> S_DATA (every bit -> data_bit / data_valid[id])
```

A frame shorter than 8 bits never raises `byte_valid`, so it never leaves `S_CMD`. A partial last byte never raises `byte_valid`, so it is neither written nor included in the CRC.

## 4. Instruction memory (SRAM macro)

The receiver is designed for one single-port SRAM macro per processor, such as an OpenRAM 1RW macro:

- **Port ownership.** While `prog_hold[i]` is high, processor `i` is in reset and the receiver owns its SRAM port: address `mem_addr`, data in `mem_wdata`, write `mem_we[i]`. Otherwise the processor owns the port for fetches. Mux on `prog_hold[i]`. It covers the whole frame and the wait for `prog_ok`, and the processor never fetches during that time.
- **One write per cycle.** `mem_we[i]`, `mem_addr` and `mem_wdata` are registers that change only on the rising edge and stay stable for the whole cycle. The SRAM samples them on the next rising edge.
- **No bulk clear and no reads.** The receiver only ever writes the addresses it is sent. Old contents elsewhere stay: compiled code runs consecutive addresses and jumps, so stale code is never reached.
- **Polarity.** OpenRAM macros use active-low `csb`/`web`, which the integration inverts. For example `web = ~mem_we[i]` while the receiver owns the port.

## 5. Design notes

1. **One cycle of latency.** The inputs are registered so the only half-cycle path is pin → flop. As a result every action happens one edge after the sampling edge (§2). The original spec said "in the cycle the last bit is sampled"; this is a deliberate change.
2. **Synchronous reset.** It needs `clk` running. To make it asynchronous, change each `always @(posedge clk)` with a reset to `always @(posedge clk or negedge rst_n)`. The input registers have no reset either way.
3. **Reset released mid-frame.** The receiver ignores bits until it has seen `cs_n` high once (`armed`).
4. **Shared `mem_addr` / `mem_wdata` / `data_bit`.** These are only meaningful while a `mem_we` or `data_valid` bit is high.
5. **`prog_ok` is global.** It releases every processor whose PROGRAM frame has finished. To check several programs, program them all, check every CRC, then pulse `prog_ok` once. If any CRC is wrong, re-send that frame before pulsing.
6. **If `prog_ok` is never pulsed,** a programmed processor stays in reset. Reset also releases all holds (with `enable` cleared).
7. **CRC timing.** The status word reaches the TX link about 3 cycles after `cs_n` goes high. It can be delayed by one TX word already in progress, or by `tx_hold`.
8. **DATA frames aren't checked.** Bits stream out as they arrive, so no check is possible before they're used.
9. **Holding a processor in reset** resets its GPIO outputs too. An external bus it was driving may see that during programming. That needs handling on the processor side.
