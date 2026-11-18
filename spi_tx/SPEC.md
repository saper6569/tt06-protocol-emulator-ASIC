# Transmit link (ASIC → master)

The return path for the receive link in [`spi_rx`](../spi_rx/SPEC.md). Each of the four processors pushes bytes into its own FIFO, and the receive link reports PROGRAM CRCs. Everything goes to the master over one serial link.

| File | Contents |
|---|---|
| [rtl/spi_tx_top.v](rtl/spi_tx_top.v) | Four processor FIFOs + status FIFO + arbiter + serializer; the interface below |
| [rtl/tx_rr_arbiter.v](rtl/tx_rr_arbiter.v) | Round robin among non-empty FIFOs, with a priority group |
| [rtl/spi_tx_serial.v](rtl/spi_tx_serial.v) | Shifts one word out per frame |
| [../src/fifo.v](../src/fifo.v) | The FIFO used for each processor and for status words (existing module) |

```
processor 0 --push--> fifo 0 --+
processor 1 --push--> fifo 1 --+--> tx_rr_arbiter --+
processor 2 --push--> fifo 2 --+   (priority, RR)   +--> spi_tx_serial --> tx_cs_n, miso --> master
processor 3 --push--> fifo 3 --+                    |
spi_rx CRC report ---> status fifo (always first) --+          tx_hold <-- master
```

## 1. Link

| Signal | Dir (at ASIC) | Description |
|---|---|---|
| `clk` | in | The same board clock as the receive link |
| `tx_cs_n` | out | Frame select, active low. Low for exactly 11 cycles per word. |
| `miso` | out | Word bits, MSB first, one per clock |
| `tx_hold` | in | From the master: 1 = don't start a new word. Registered on entry. |

- The ASIC changes `tx_cs_n` and `miso` on the **rising** edge of `clk`. The master samples both on the **falling** edge, which gives half a cycle of margin either way.
- A frame is one 11-bit word:

  | Bits | 10 | 9:8 | 7:0 |
  |---|---|---|---|
  | Field | status | processor id (0–3) | data |

  - `status = 0`: `data` is a byte from processor `id`.
  - `status = 1`: `data` is the CRC-8 of the PROGRAM frame just received for processor `id`. The master answers with `prog_ok` on the receive link.
- Between frames `tx_cs_n` is high for at least one cycle. With words waiting it's exactly one cycle, so the link carries one word every **12 clocks**.
- **`tx_hold`:** while the master holds it high (as sampled by the ASIC), no new word starts. A word already being sent always finishes. Words wait in the FIFOs, so a long hold fills them and the processors see `tx_full`.

Examples:

| Word | Binary | Hex (11 bits) |
|---|---|---|
| processor 0, byte `11` | `0_00_0001_0001` | `011` |
| processor 1, byte `A1` | `0_01_1010_0001` | `1A1` |
| CRC `1A` for a PROGRAM frame to processor 2 | `1_10_0001_1010` | `61A` |

## 2. Interface (`spi_tx_top`)

| Signal | Dir | Description |
|---|---|---|
| `tx_push[3:0]` | in | Bit `i`: processor `i` pushes `tx_data[8*i +: 8]` on this rising edge |
| `tx_data[31:0]` | in | One byte per processor, packed: processor `i` uses bits `8*i+7 : 8*i` |
| `tx_full[3:0]` | out | Bit `i`: processor `i`'s FIFO is full. A push while full is ignored, so the processor must wait. |
| `tx_priority[3:0]` | in | Bit `i`: processor `i` is high priority (§3) |
| `status_valid`, `status_id[1:0]`, `status_data[7:0]` | in | From `spi_rx_top`'s `crc_valid`, `crc_id`, `crc_value` |
| `FIFO_SIZE` | param | Bytes buffered per processor (default 4) |
| `STATUS_SIZE` | param | Status words buffered (default 2) |

## 3. Order of words

1. **A waiting status word always goes next**, ahead of any processor data. It still waits for a word already in progress.
2. **Otherwise the arbiter picks a processor FIFO:**
   - If any processor with `tx_priority` set has data, only those are considered. Otherwise all non-empty FIFOs are.
   - Within the candidates it's round robin. The search starts after the processor sent last, in the order `last+1, last+2, last+3, last`, wrapping 3 → 0. Empty FIFOs are skipped.
   - After reset `last = 3`, so processor 0 goes first. Status words don't use up a processor's turn.

| Situation | Send order |
|---|---|
| no priority, all four have 2 bytes | 0, 1, 2, 3, 0, 1, 2, 3 |
| no priority, only 1 and 3 have data | 1, 3, 1, 3 |
| `tx_priority = 0100`, all four have 2 bytes | 2, 2, then 0/1/3 round robin |
| a PROGRAM frame ends while processor 0 has bytes queued | the CRC word goes right after the current word |

A high-priority processor that never runs out of data starves the others. Only mark a processor whose average rate is well below the link rate, but which can't wait (for example Ethernet receive).

## 4. Timing

Columns are rising edges. Each output row is the value just after that edge; the master samples it on the falling edge that follows. Two words are waiting: processor 0 byte `11`, then processor 1 byte `A1`.

```
edge       0  1  2  3  4  5  6  7  8  9  10 11 12 13 14 15 16 17 18 19 20 21 22 23
tx_cs_n    0  0  0  0  0  0  0  0  0  0  0  1  0  0  0  0  0  0  0  0  0  0  0  1
miso       0  0  0  0  0  0  1  0  0  0  1  .  0  0  1  1  0  1  0  0  0  0  1  .
bit        s  i1 i0 d7 d6 d5 d4 d3 d2 d1 d0 .  s  i1 i0 d7 d6 d5 d4 d3 d2 d1 d0 .
word       {0, 0, 11} = 0_00_0001_0001         {0, 1, A1} = 0_01_1010_0001
```

- On edge 0 the link is free (`tx_cs_n` high before it), so the word is taken, its FIFO is popped, and its MSB goes out.
- Edges 1–10 send the other 10 bits.
- On edge 11 `tx_cs_n` goes high for one cycle, the gap. On edge 12 the next word starts.

The CRC status word for a PROGRAM frame starts about 3 edges after the receive link samples `cs_n` high, if the TX link is idle. See the `spi_rx` timing diagram.

## 5. Serializer (`spi_tx_serial`, `WIDTH = 11`)

Registers: `tx_cs_n`, `miso`, `shift[WIDTH-2:0]`, `remaining`.

| Condition at rising edge | Action |
|---|---|
| `rst_n` low | `tx_cs_n = 1`, `remaining = 0` |
| `tx_cs_n` high, `word_valid` | take the word: `tx_cs_n = 0`, `miso = word[WIDTH-1]`, `shift = rest`, `remaining = WIDTH-1` |
| `tx_cs_n` high, no word | stay idle |
| `tx_cs_n` low, `remaining > 0` | `miso = shift` MSB, shift left, `remaining--` |
| `tx_cs_n` low, `remaining = 0` | `tx_cs_n = 1` (end of frame, one-cycle gap) |

`word_ready = tx_cs_n`: the link is free exactly when the frame pin is high. In `spi_tx_top`, `word_valid = !tx_hold_q && (status waiting || any processor FIFO non-empty)`.

## 6. Rates at 50 MHz

| | Rate |
|---|---|
| Words per second | 50 MHz ÷ 12 = 4.17 M words/s |
| Payload, all processors together | 4.17 MB/s (33.3 Mbit/s) |
| Per processor, all four sending flat out | about 1.04 MB/s each |
| One processor alone, or with `tx_priority` | up to 4.17 MB/s |

The status bit costs one clock per word compared with a 10-bit format (4.55 MB/s). Status words are rare, one per PROGRAM frame, so they take almost no bandwidth.

## 7. Design notes

1. **Separate TX pins.** The receive link has no return path, so the ASIC drives its own `tx_cs_n` and `miso`, and the master can pause it with `tx_hold`. That's 2 outputs and 1 input.
2. **Back-pressure.** `tx_full` goes back to each processor. It only works when the processor controls the timing. A processor receiving a protocol it can't pause (UART receive, SPI target, USB, Ethernet) loses bytes if its FIFO fills. Use `tx_priority` for it, and don't hold the link for long.
3. **Status FIFO.** Normally at most one status word is waiting: PROGRAM frames end at least 17 clocks apart, and a status word waits at most one word time (12 clocks). The second slot covers a master that holds `tx_hold` across two PROGRAM frames. A third CRC report while both slots are full and the link is held would be dropped. The master avoids this by releasing `tx_hold` before sending more PROGRAM frames.
4. **Rising-edge outputs.** All ASIC logic stays on one edge. The master samples on the falling edge.
5. **Not connected yet.** The processor has no byte-output port, and `spi_tx_top` and `spi_rx_top` aren't instantiated in `tt_um_.v`. Wire `spi_rx_top.crc_*` to `spi_tx_top.status_*`.
