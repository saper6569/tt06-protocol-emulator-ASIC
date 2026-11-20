# RP2040 host library (`pemu`)

Specification for a C library, for the Raspberry Pi RP2040 (Pico SDK), that lets a programmer drive the protocol-emulator ASIC without knowing its wire protocol. This document is a specification only. It contains no implementation.

The ASIC side of the links is specified in [`spi_rx/SPEC.md`](../spi_rx/SPEC.md) (master → ASIC) and [`spi_tx/SPEC.md`](../spi_tx/SPEC.md) (ASIC → master). Those two documents are the source of truth for the wire protocol. Where this document restates a protocol fact, the ASIC specs win.

Keywords **MUST**, **SHOULD** and **MAY** are used in their RFC 2119 sense.

---

## 1. Goals and non-goals

### Goals

1. A programmer who has never read the RX/TX specs can, in a few lines of application code, reset the ASIC, load an assembled program into one of the four processors, verify it, start it, stream data to it, and receive bytes from it.
2. Program loading is **safe by default**: the library performs the CRC check-and-release handshake itself, retries on failure, and never releases a processor whose program was not confirmed (unless the programmer explicitly asks for a raw, unchecked load).
3. The library owns all timing-critical work (the shared clock, edge phasing, bit serialization). Application code never bit-bangs a pin.
4. Receive-side traffic from the ASIC is never lost because the application was busy, up to documented limits, and any loss is detected and reported, never silent.
5. Small and predictable: statically allocated, no heap use, no blocking in interrupt context, usable from either RP2040 core.

### Non-goals

- Not an assembler. Turning source into machine code is the job of the existing tool in [`assembler/`](../assembler). The library consumes already-assembled bytes (§6.2).
- Not a driver for the processors' GPIO. The ASIC's processors drive their own pins. The library only starts, stops, programs and exchanges data with them.
- No MicroPython or Arduino binding in the first version (§14).
- No support for talking to anything other than this ASIC.

---

## 2. Target platform

| Item | Requirement |
|---|---|
| MCU | RP2040 (RP2350 compatibility SHOULD be kept in mind, but is not required) |
| SDK | Raspberry Pi Pico SDK 1.5 or later, CMake |
| Language | C11 for the library, with headers usable from C++ (`extern "C"`) |
| Peripherals used | One PIO block (up to 2 state machines), DMA (2 channels), GPIO. No dependence on specific core assignment |
| Memory | Flash and RAM budget given in §12 |
| Distribution | A CMake `INTERFACE` or static library target that an application links with, plus an `examples/` directory |

---

## 3. The hardware being driven

A short summary so the rest of this document is self-contained. Details live in the linked RX/TX specs.

### 3.1 Signals

All signals are synchronous to one **shared clock that the RP2040 must supply to the ASIC and keep free-running**.

| Signal | Dir (at RP2040) | Meaning | Edge on which RP2040 acts |
|---|---|---|---|
| `clk` | out | ASIC clock, free-running | – |
| `rst_n` | out | Active-low synchronous reset. Needs `clk` running | – |
| `cs_n` | out | RX frame select, low during a frame | **changes on the falling edge** of `clk` |
| `mosi` | out | RX data, MSB first, 1 bit per clock | **changes on the falling edge** |
| `prog_ok` | out | Program-CRC-matched pulse, ≥ 1 cycle | **changes on the falling edge** |
| `tx_hold` | out | 1 = ASIC must not start a new TX word | any time (registered by the ASIC) |
| `tx_cs_n` | in | TX frame select, low for exactly 11 cycles per word | **sampled on the falling edge** |
| `miso` | in | TX data, MSB first | **sampled on the falling edge** |

That is **8 GPIOs**. The mapping from these signals to physical RP2040 pins MUST be configurable at init (§7) and MUST NOT be hard-coded. `clk`, `cs_n`, `mosi`, `prog_ok` and the two inputs must be allowed in any one contiguous or non-contiguous set the PIO can address (§9.1 states the constraint that applies).

The mapping from these signals to the ASIC package's `ui`/`uo`/`uio` pins is not fixed yet. The current `tt_um_.v` does not instantiate the SPI RX/TX modules (see §15, item 1). The library must not assume a pin table beyond the signal names above.

### 3.2 Facts the library depends on

These are the behaviours the API in §6 is built around. If the RTL changes, update here first.

1. **Four processors**, ids 0–3. Each has its own 256-byte instruction memory (8-bit address, 8-bit instruction).
2. **Command byte** = `{mode[1:0], id[1:0], 4'b0000}`. Modes: RUN `00`, PROGRAM `01`, DATA `10`, IDLE `11`.
3. **Frames** (bytes sent MSB first, `cs_n` low for the whole frame, ≥ 1 cycle of `cs_n` high between frames):
   - RUN / IDLE: 1 byte. Extra bytes are ignored.
   - PROGRAM: command, start address, then instructions. `I0` goes to the start address, `I1` to start+1, and so on. The address wraps 255 → 0.
   - DATA: command, then any number of data bytes. Every bit is forwarded to the processor with a strobe. There is no byte alignment or checking and **no flow control back to the master**.
4. **PROGRAM confirmation.** The command byte puts that processor in reset and gives the receiver its memory port. When `cs_n` rises, the ASIC reports a CRC-8 of the frame over TX as the status word `{1, id, crc}`. The master pulses `prog_ok` if the CRC matches its own, which releases **every** processor whose PROGRAM frame has finished (not one whose frame is still in progress). On mismatch the master re-sends and the processor stays held, so a corrupted program never runs.
5. **CRC-8:** polynomial `0x07`, init `0x00`, MSB first, no reflection, no final XOR (CRC-8/SMBUS). Test vector: ASCII `"123456789"` → `0xF4`. The CRC covers every complete byte of the frame: command byte, address byte, instruction bytes.
6. **TX word** = 11 bits `{status, id[1:0], data[7:0]}`. `status = 0`: a data byte from processor `id`. `status = 1`: the CRC report for `id`. One word every 12 cycles at most. Status words always go ahead of processor words.
7. **Reset** is synchronous (needs `clk`). It clears all `enable` and `prog_hold` bits. It does **not** clear instruction memory.
8. **After reset**, the receiver ignores bits until it has seen `cs_n` high once.

---

## 4. Architecture

### 4.1 Layers

```
  application
      │  ┌─────────────────────────────────────────────────────────────┐
      ▼  │ L3  Session API     (pemu.h)      processors, programs, data │
  ┌──────┴─────────────────────────────────────────────────────────────┐
  │ L2  Protocol layer   frame builders, CRC-8, TX word decoder,       │
  │                      status-word matching, retry logic             │
  ├────────────────────────────────────────────────────────────────────┤
  │ L1  Link driver      PIO programs, DMA, ring buffers, IRQ glue     │
  ├────────────────────────────────────────────────────────────────────┤
  │ L0  Pins / clocks    GPIO setup, clk generation, input sync config │
  └────────────────────────────────────────────────────────────────────┘
                         │ 8 wires │
                        ASIC
```

- **L0/L1** are the only layers that touch RP2040 hardware. They SHOULD hide behind a small internal interface so L2 can be compiled and unit-tested on a host PC (§13).
- **L2** is pure logic: given bytes in, produce frames; given bits from the wire, produce decoded words. It MUST be free of SDK calls.
- **L3** is the public, documented API (§6).

### 4.2 Public headers

| Header | Contents |
|---|---|
| `pemu.h` | The session API (§6). The only header most programmers include |
| `pemu_protocol.h` | Constants (commands, modes, word format), CRC function, frame builders. Public so tools and tests can use them |
| `pemu_config.h` | Compile-time options (§7.2) |

### 4.3 Threading and context model

- The library MUST work when called from a single thread on either core.
- The RX-link receive path (decoding TX words from the ASIC) runs from DMA and/or an interrupt. API calls that read received data MUST be safe to call while that path is active. A lock-free single-producer/single-consumer design is preferred over critical sections.
- Public functions MUST document whether they block, and MUST NOT block inside an interrupt handler. Blocking calls take a timeout.
- Calling the API from two cores or threads at once is **not** supported in v1, and the header MUST say so. Data may be *consumed* from the other core only through the dedicated reader functions in §6.6.

---

## 5. Concepts exposed to the programmer

| Concept | Meaning |
|---|---|
| **Link** | The full set of 8 signals to one ASIC. One link object per ASIC. v1 supports one link |
| **Processor** | One of the four cores, addressed by id 0–3 |
| **Program image** | Up to 256 bytes of assembled instructions, with a load address |
| **Run state** | The `enable` bit of a processor: running or idle |
| **Held** | A processor with a loaded-but-unconfirmed program. It cannot run until released |
| **Event** | A received item the application may care about: a data byte from a processor, a CRC report, a framing error, an overflow |

The library keeps a **shadow state** per processor (enable bit, whether a program is pending confirmation, last confirmed CRC). It is advisory only: the ASIC is the real source of truth, and shadow state is rebuilt on `pemu_reset`.

---

## 6. Public API

The API is specified here by name, purpose, inputs, outputs and behaviour. Exact C types are a design choice for the implementer, subject to these rules:

- Every function that can fail returns a status code (§6.9). Output values come back through pointer arguments.
- Processor ids are validated (0–3). Invalid ids return `BAD_ARG`, never crash.
- No function allocates memory.

### 6.1 Lifecycle

| Function | Purpose | Behaviour |
|---|---|---|
| `pemu_init` | Bring up the link | Takes a configuration object (§7). Claims a PIO block and DMA channels, sets pin directions and **idle levels** (`cs_n` = 1, `mosi` = 0, `prog_ok` = 0, `rst_n` = 0, `tx_hold` = 0), starts `clk`, and starts the receive path. Does **not** release reset. Returns an error if resources are unavailable |
| `pemu_reset` | Reset the ASIC and the library's shadow state | Holds `rst_n` low for at least the configured number of `clk` cycles (default 16, §7), releases it, then holds `cs_n` high for at least the post-reset settle count (default 4 cycles) so the ASIC's receiver is armed. Discards pending received data and clears all shadow state. All processors end up idle with no program pending. Instruction memory contents are untouched |
| `pemu_deinit` | Tear down | Stops `clk`, releases PIO and DMA, sets pins to inputs. After this, `pemu_init` must work again |
| `pemu_set_clock` | Change the ASIC clock | See §9.2. MAY be called only while no transfer is in flight; returns `BUSY` otherwise |

Order of use: `pemu_init` → `pemu_reset` → everything else.

### 6.2 Program image

| Function | Purpose | Behaviour |
|---|---|---|
| `pemu_image_from_bytes` | Wrap raw bytes | Takes a pointer, a length (1–256) and a load address (0–255). Does not copy; the bytes must outlive any load that uses it |
| `pemu_image_from_text` *(optional, phase 2)* | Parse the text format used by [`fpga/instructions.txt`](../fpga/instructions.txt) | One 8-bit binary instruction per line, `//` comments, `@hex` sets the load address. Needs a defined behavior for gaps (the FPGA tool fills with `00000000`). Not required for v1 |

Rules:

- A single image MUST NOT exceed 256 bytes. Longer input returns `BAD_ARG`.
- Because the hardware address wraps 255 → 0, `address + length > 256` would silently wrap. By default the library MUST reject it with `BAD_ARG`. A flag on the call MAY allow wrapping deliberately.
- An image with gaps (several `@` sections) is loaded as several PROGRAM frames in one session (§6.3). The library MUST NOT send the gap contents.

The assembler's output format is not specified in this repo's documents. Confirm it (§15, item 5) before deciding what a "raw bytes" source looks like. The library works on bytes regardless.

### 6.3 Program loading (the safe path)

| Function | Purpose | Behaviour |
|---|---|---|
| `pemu_program` | Load, verify and optionally start a processor | See sequence below. Blocking, with a timeout |
| `pemu_program_unchecked` | Load without waiting for the CRC | Sends the PROGRAM frame and returns. The processor stays held. **Nothing releases it** until the application later calls `pemu_confirm` (below) or `pemu_reset`. Provided for advanced use and for tests |
| `pemu_confirm` | Pulse `prog_ok` | Pulses `prog_ok` for the configured number of cycles. This releases **every** processor whose PROGRAM frame has finished, not only one. Documented as such |

Sequence for `pemu_program` (processor `id`, image `img`, option `start`):

1. If any other PROGRAM frame is still in flight, wait for it, since `prog_ok` is global (§3.2 item 4, and the multi-processor note in §6.4).
2. Build the PROGRAM frame: command byte for `id`, start address, instruction bytes. Compute the expected CRC-8 over exactly those bytes.
3. Send the frame, with `cs_n` low for the whole frame and at least one idle cycle after it.
4. Wait for the status word for `id` (status bit = 1) from the TX path, up to the timeout.
5. If the CRC matches: pulse `prog_ok`. If `start` was requested, make sure the processor's enable bit is set by sending a RUN frame (before or after the pulse; a RUN for a held processor takes effect on release, see §3.2).
6. If the CRC does not match: go back to step 2, up to `max_retries` times (default 3). After that return `CRC_MISMATCH` and leave the processor **held**. Do **not** pulse `prog_ok`.
7. If no status word arrives within the timeout: return `TIMEOUT`. Do not pulse `prog_ok`. The processor remains held.

Rules:

- `pemu_program` MUST NOT pulse `prog_ok` unless the CRC for **that** frame matched.
- A stale status word (from an earlier frame or another id) MUST NOT satisfy the wait. Match on `status = 1` **and** `id`. Because two PROGRAM frames may be confirmed in the same `prog_ok`, handle ordering carefully (§6.4).
- If the image has several sections (§6.2), each section is sent and CRC-checked as its own frame, and `prog_ok` is pulsed once after all sections for that processor match.
- After a successful `pemu_program`, the shadow state records the confirmed CRC and clears "pending".
- The status FIFO in the ASIC holds only 2 reports (§7 of the TX spec). The library MUST NOT send a third PROGRAM frame while two reports are unread, and MUST NOT assert `tx_hold` across more than two PROGRAM frames.

### 6.4 Programming several processors

| Function | Purpose | Behaviour |
|---|---|---|
| `pemu_program_many` | Load N images to N processors, then confirm once | Sends all PROGRAM frames, collects every CRC report, and compares each. Pulses `prog_ok` **once**, only if all matched. Reports a per-processor result. On any mismatch, re-sends only the bad frame(s) and re-checks before pulsing. Mirrors ASIC design note 5 (RX spec §5) |

Rationale: since `prog_ok` is global, pulsing after only some frames matched would release a processor whose program was not yet checked. `pemu_program_many` is the safe form. Calling `pemu_program` repeatedly is also safe because each call completes its own check and pulse before the next frame starts (step 1 above).

### 6.5 Run control

| Function | Purpose | Behaviour |
|---|---|---|
| `pemu_run` | Start a processor | Sends the 1-byte RUN frame. If the processor is held, it starts when released |
| `pemu_idle` | Stop a processor | Sends the 1-byte IDLE frame |
| `pemu_run_mask` / `pemu_idle_mask` | Several at once | Takes a 4-bit mask. Sends one frame per set bit, back to back, with the minimum gap. Documented as **not simultaneous**: processors start a few cycles apart |
| `pemu_get_state` | Read the library's shadow state | Returns enable bit, pending-confirmation flag and last confirmed CRC for a processor. Does not touch the wire |

Neither run command returns an acknowledgement, as the ASIC has none. The functions return when the frame has been fully clocked out.

### 6.6 Data to the processors

| Function | Purpose | Behaviour |
|---|---|---|
| `pemu_send_data` | Stream bytes to a processor | Sends one DATA frame: command, then the bytes. Blocking until clocked out, or non-blocking with a completion callback/flag (see below) |
| `pemu_send_data_async` | Non-blocking variant | Queues the buffer for DMA and returns at once. Returns `BUSY` if the transmit queue is full. The buffer must stay valid until completion |

Rules:

- The ASIC has **no backpressure** on this path: bits go to the processor as they arrive, one per clock, whether or not the processor is ready. The API documentation MUST state this prominently. The programmer is responsible for pacing, for example by sending in small frames and using TX data from the processor as an acknowledgement.
- Frame length is limited only by the caller's buffer. Very long frames hold `cs_n` low for a long time and block all other commands. The library SHOULD offer a configurable maximum frame length (default 256 bytes) and return `BAD_ARG` above it.
- Zero-length data is `BAD_ARG`.
- A DATA frame is a whole number of bytes. The library MUST NOT offer a way to send a partial byte.

### 6.7 Receiving from the processors

The ASIC returns 11-bit words continuously whenever any processor has a byte and `tx_hold` is low. The receive path decodes them in the background.

| Function | Purpose | Behaviour |
|---|---|---|
| `pemu_read` | Read bytes from one processor | Takes id, buffer, max length, timeout. Returns how many bytes were copied. Non-blocking when timeout is zero. Bytes arrive in the order the ASIC sent them for that processor |
| `pemu_available` | Bytes waiting | Per processor. Constant time |
| `pemu_read_any` | Read the next byte from whichever processor sent it | Returns the id and the byte. Preserves the wire order across processors |
| `pemu_flush_rx` | Discard buffered data | Per processor or all |
| `pemu_set_rx_callback` *(optional)* | Notify on data | A function called from the library's deferred context (not from the raw interrupt) when new bytes arrive. Runs on whichever core initialised the library |

Rules:

- Per-processor receive buffers have a compile-time size (§7.2), default 256 bytes each.
- Status words (`status = 1`) are **never** delivered through `pemu_read`. They go to the program-confirmation logic (§6.3). A status word with no waiting `pemu_program` call is recorded as an event (§6.8) and its CRC is kept for `pemu_get_state`.
- Reading MUST be safe while the receive path is running (§4.3).

### 6.8 Events, errors and diagnostics

| Function | Purpose | Behaviour |
|---|---|---|
| `pemu_get_stats` | Counters | See the table below. Counters saturate, they do not wrap silently |
| `pemu_clear_stats` | Reset the counters | |
| `pemu_get_last_error` | Most recent asynchronous error | For errors that happen in the background (overflow, framing) and have no call to return to |

Required counters:

| Counter | Meaning |
|---|---|
| `rx_words` | Words decoded from the TX link, by kind |
| `rx_framing_errors` | `tx_cs_n` low-time was not exactly 11 cycles, or a word started mid-way |
| `rx_overflows` | A received byte was dropped because a per-processor buffer or DMA buffer was full |
| `status_unmatched` | CRC report with no program waiting |
| `crc_retries` | Number of PROGRAM re-sends |
| `crc_failures` | Programs that ran out of retries |
| `tx_frames` | Frames sent (by mode) |
| `hold_assertions` | Times the library asserted `tx_hold` for flow control |

Overflow and framing errors MUST be reported, never ignored. They also set the "last error" so a program that only polls `pemu_read` can still discover that data was lost.

### 6.9 Status codes

A small, documented enumeration. Minimum set:

| Code | Meaning |
|---|---|
| `OK` | Success |
| `BAD_ARG` | Invalid id, length, address, null pointer, or address wrap |
| `BUSY` | Another transfer is in flight, or a queue is full |
| `TIMEOUT` | No CRC report or no data within the timeout |
| `CRC_MISMATCH` | Retries exhausted; the processor is left held |
| `NOT_READY` | `pemu_init` or `pemu_reset` has not been done |
| `RESOURCE` | No free PIO state machine, DMA channel or similar |
| `OVERFLOW` | Receive data was lost (also visible in stats) |
| `LINK_ERROR` | Framing error or an impossible word was seen |

Every code MUST have a human-readable string through a `pemu_strerror` function, usable without the SDK's printf support.

### 6.10 Flow control of the TX link

| Function | Purpose | Behaviour |
|---|---|---|
| `pemu_tx_hold` | Assert or release `tx_hold` | Manual control. A word already in progress still finishes, so allow up to 11 more cycles of output after asserting |
| (automatic) | High/low watermark control | If enabled in the configuration (§7), the library asserts `tx_hold` when its receive buffering passes the high watermark, and releases it below the low watermark. Off by default |

Cautions the documentation MUST include:

- Holding TX fills the processors' 4-deep FIFOs and then `tx_full`. A processor that receives a protocol it cannot pause will lose data. Automatic flow control is only suitable when every processor producing TX data can wait.
- The ASIC's status FIFO holds only 2 CRC reports. Do not leave `tx_hold` asserted while sending more than two PROGRAM frames. The library enforces this inside `pemu_program` by releasing `tx_hold` for the duration of a program load.

---

## 7. Configuration

### 7.1 Runtime configuration (passed to `pemu_init`)

| Field | Meaning | Default |
|---|---|---|
| pins | GPIO number for each of the 8 signals (§3.1) | none, required |
| pio / state machine hints | Which PIO block to use, or "any" | any |
| dma hints | DMA channels to use, or "claim any" | claim any |
| asic clock frequency | Hz (§9.2) | 10 MHz |
| reset cycles | `clk` cycles `rst_n` is held low | 16 |
| post-reset settle cycles | `cs_n` high cycles after reset before the first frame | 4 |
| inter-frame gap cycles | `cs_n` high cycles between frames (≥ 1) | 2 |
| `prog_ok` pulse width | cycles | 2 |
| program timeout | wait for a CRC report | 50 ms |
| program max retries | | 3 |
| auto flow control | off / on, and the watermarks | off |
| sample phase trim | extra delay in sys-clock cycles for the input sampling (§9.3) | 0 |

### 7.2 Compile-time configuration (`pemu_config.h`)

| Option | Meaning | Default |
|---|---|---|
| per-processor receive buffer size | bytes, power of two | 256 |
| DMA receive buffer size | words | 512 |
| maximum DATA frame length | bytes | 256 |
| enable statistics | on/off, to save RAM | on |
| debug logging hook | optional callback for the PIO/DMA layer | off |

All sizes are `#define`s overridable from CMake.

---

## 8. Protocol layer details

These are requirements on L2, written so they can be checked by unit tests (§13).

### 8.1 Frame builders

For each mode, a function that writes the exact byte sequence into a caller-provided buffer and returns its length:

| Frame | Bytes |
|---|---|
| RUN id | 1 byte: `0x00 | (id << 4)` |
| IDLE id | 1 byte: `0xC0 | (id << 4)` |
| PROGRAM id, addr, n instructions | `0x40 | (id << 4)`, addr, I0 … I(n-1) → n + 2 bytes |
| DATA id, n bytes | `0x80 | (id << 4)`, D0 … D(n-1) → n + 1 bytes |

Reserved low nibble MUST always be sent as 0.

Reference values (from the RX spec): RUN p0 = `00`; IDLE p0 = `C0`; PROGRAM p2 `0x10←A5, 0x11←3C` = `60 10 A5 3C`; DATA p1 `B4 0F` = `90 B4 0F`.

### 8.2 CRC

- `crc8(data, length, initial)` implementing the polynomial and parameters in §3.2.
- MUST be incremental (the initial value argument) so a frame can be checksummed as it is built.
- MUST pass the `"123456789"` → `0xF4` test vector, and the RX spec example: `60 10 A5 3C` → `0x1A`.
- Table-driven (256 entries) is acceptable. Bitwise is acceptable. Pick by the size budget in §12.

### 8.3 TX word decoder

Input: the raw 11-bit values captured by L1. Output: a kind (data / status), id and 8-bit payload.

- Bit 10 = status, bits 9:8 = id, bits 7:0 = data.
- Reference: processor 1, byte `A1` → word `0x1A1`; CRC `1A` for processor 2 → `0x61A`.
- The decoder MUST NOT assume which ids exist beyond 0–3.

### 8.4 Retry and matching logic

- Exactly one outstanding PROGRAM frame per processor at a time.
- A CRC report matches only if status = 1, the id equals the frame's id, **and** it arrived after that frame's last byte was clocked out. A report that arrived earlier (a leftover) is discarded and counted.
- On mismatch, the frame is re-sent in full, including the command and address bytes.

---

## 9. Link driver details

### 9.1 PIO

The ASIC's clock is shared with the link, which makes cycle-exact phase relationships the main technical risk (§10, §15 item 3). The PIO is the right tool.

Requirements on the PIO design:

1. **`clk` is generated by the PIO** (side-set), not by a separate PWM or clock peripheral, so that `clk` and the data pins can never drift in phase relative to each other.
2. **Outputs change on the falling edge of `clk`:** `cs_n`, `mosi` and `prog_ok` are driven in the same PIO instruction slot as the clock's falling transition.
3. **Inputs are sampled on the falling edge of `clk`:** `tx_cs_n` and `miso` are read with the clock's falling transition, with the delay trim from §9.3.
4. **`clk` keeps running when no transfer is queued.** The PIO must run an idle loop that toggles `clk` and outputs the idle levels (`cs_n` = 1, `mosi` = 0, `prog_ok` = 0), rather than stalling. A stalled clock freezes the ASIC and stops the TX link.
5. **Output and input paths are full duplex.** An RX frame can be being sent while a TX word arrives. The design must not serialise them.
6. **The PIO needs a way to convey "cycle data" to and from the CPU.** The recommended model is a *cycle stream*: each ASIC clock cycle consumes a few output bits (`cs_n`, `mosi`, `prog_ok`) and produces two input bits (`tx_cs_n`, `miso`). Many cycles are packed into each 32-bit FIFO word. The PIO has no knowledge of frames, commands or words; all framing is done in software on the packed streams (L2). This keeps the PIO tiny and makes everything testable on the host.
   - Alternative designs (PIO-side frame logic, a state machine per link direction) are permitted as long as the requirements in this section hold. Document the choice and why.
7. **Pin mapping is configurable.** PIO has restrictions on which pins can be driven by `set`, `out`, side-set and read by `in`. The configuration check MUST reject a pin assignment the chosen design cannot implement, with a clear error, rather than producing a wrong wave.
8. **Cycle accuracy under DMA starvation.** If the output FIFO runs empty the PIO MUST fall back to the idle levels (§9.1 item 4) and flag the underrun, never repeat stale data. A frame that is cut mid-way by underrun MUST be detectable by software (`LINK_ERROR`), because the ASIC would otherwise see a truncated frame.

### 9.2 Clock frequency

- `pemu_init` and `pemu_set_clock` take the ASIC clock in Hz.
- The library derives the PIO clock divider from the system clock and the number of PIO instructions per ASIC clock cycle. If the exact frequency is not achievable, the achieved value MUST be reported back (`pemu_get_clock`).
- **Default:** 10 MHz, chosen to be conservative. The ASIC's maximum frequency has not been characterised (the project metadata currently gives `clock_hz: 0`). The library MUST allow higher settings and MUST NOT silently clamp. A documented upper bound derived from the PIO design is acceptable, enforced with `BAD_ARG`.
- The 50 MHz figures in the TX spec §6 are the ASIC's design target, not a promise about what an RP2040 can generate. The documentation of the achievable throughput on RP2040 is a deliverable (§11).
- Changing the clock while the ASIC is running is allowed, but the clock edges around the change must not produce a runt pulse. If glitch-free changes are not possible, require `pemu_reset` afterwards.

### 9.3 Input timing

RP2040 GPIO inputs normally pass through a two-flop synchroniser, adding about two system-clock cycles of latency. At higher ASIC clock rates this can push the real sampling point past the data's valid window.

- The PIO MUST be able to bypass the input synchroniser for `tx_cs_n` and `miso`. This is safe here because those signals are synchronous to the RP2040's own `clk` output. The documentation must say so.
- The configuration field *sample phase trim* adds a whole number of system-clock cycles of delay before sampling, to compensate for board delay (cable, level shifters). Default 0.
- A **self-test** is required (§6.1, `pemu_reset` or a separate function, see §13): a documented procedure to find a working trim, for example by looping a known pattern back, or by reading the CRC of a known PROGRAM frame at increasing trim values until the result is stable. At least describe the procedure in the docs even if it is not automated in v1.

### 9.4 DMA

- One DMA channel feeds the output FIFO from a software-built stream. One drains the input FIFO into a ring buffer. Both are paced by the PIO's DREQ signals.
- The receive ring buffer is processed by a background task or by an interrupt on a half-full/full threshold. The decoder (§8.3) then fans the words out to per-processor queues (§6.7) and the program-confirmation logic.
- Ring wrap-around and "writer overtook reader" MUST be detected (overflow counter).

---

## 10. Timing contract and performance

The API must document these numbers. Exact values depend on the implementation, and the measured ones go into the docs.

| Quantity | Requirement |
|---|---|
| Clock output accuracy | Within the PIO divider granularity; reported by `pemu_get_clock` |
| Clock jitter | Not specified in v1 (PIO-generated, so equal to the system clock jitter) |
| Gap between consecutive RX frames | Configurable ≥ 1 cycle; default 2 |
| Latency, last bit of a `pemu_run` frame to `enable` high at the ASIC | ≈ 1 ASIC cycle after the frame's last sampled bit (RX spec §2) |
| Time for a `pemu_program` of a 64-byte image | Documented, for the default clock. Must include the 3-cycle report delay, one TX word (12 cycles), and CPU time |
| TX throughput capability | The receive path MUST keep up with the link's maximum rate **at the configured clock** (1 word per 12 cycles) for at least 1 second without loss, with the application reading concurrently. If it cannot at a given clock, documentation states the highest clock that works and `pemu_init` warns |
| Receive latency, wire to `pemu_read` | Documented worst case |
| CPU load | Documented for idle, and at full TX rate. The PIO + DMA design should leave most of one core free |

---

## 11. Documentation deliverables

1. **README** with a 10-line quick start: wiring table, include, init, reset, program, run, read.
2. **API reference** generated from the headers (Doxygen-style comments are expected on every public function).
3. **Wiring guide**: signal-to-RP2040-pin table, level-shifting notes (§16), and the clock requirement ("the RP2040 supplies the ASIC clock; do not connect another oscillator").
4. **Behaviour notes** page that states, in plain language:
   - run/idle have no acknowledgement;
   - DATA has no backpressure;
   - `prog_ok` is global;
   - TX hold can overflow processor FIFOs;
   - the CRC proves the frame was received correctly, not that the memory write succeeded or the program is correct.
5. **Throughput and timing table** measured on real hardware once available.
6. **Troubleshooting**: ASIC shows no response (check clock, reset length, `cs_n` idle level, sample trim); CRC always mismatches (phase trim, wiring, endianness); data lost (overflow stats).

---

## 12. Resource budget (targets)

| Resource | Target |
|---|---|
| Flash | ≤ 8 KB for L1–L3, excluding the SDK |
| RAM | ≤ 4 KB with default buffers (4 × 256-byte processor buffers dominate); overridable |
| PIO instruction slots | ≤ 16 of the 32 in a block (leaves room for another program) |
| PIO state machines | ≤ 2 |
| DMA channels | 2 |
| Interrupts | 1 (DMA/PIO IRQ) |

If the cycle-stream design exceeds these, document the actual numbers and the reason.

---

## 13. Testing requirements

### 13.1 Host-side unit tests (no hardware, run in CI)

L2 compiled on a PC with a test runner. MUST cover:

- CRC-8 vectors: `"123456789"` → `0xF4`; `60 10 A5 3C` → `0x1A`; empty message → `0x00`; a single-bit-flip changes the CRC for every bit position of a 258-byte message.
- Frame builders: every row of §8.1 for every id, including maximum-length PROGRAM (256 instructions) and rejection of 257.
- Address-wrap rule: `address + length > 256` is rejected unless the flag is set.
- TX word decoder: the two reference words plus all 2048 possible values decode without error and re-encode to themselves.
- Retry logic against a **fake link**: mismatch once then match → success, one retry counted; mismatch always → `CRC_MISMATCH` and no `prog_ok` pulse issued; timeout → `TIMEOUT`, no pulse; stale status word ignored; wrong id ignored.
- `pemu_program_many`: one bad frame among four → only that frame is re-sent, `prog_ok` is pulsed once after all match, never before.

### 13.2 Simulation tests (no RP2040)

The repo already has an RTL test suite (see `test/`). A co-simulation or a trace replay SHOULD feed the library's generated cycle stream into the ASIC RTL and decode the ASIC's TX output with the library's decoder, checking:

- A full program-verify-run sequence ends with the processor enabled and released.
- A deliberately corrupted frame (a flipped bit in the stream) yields a CRC mismatch and the processor remains held.
- TX words from all four processors, with and without priority, arrive intact and are attributed to the right id.

### 13.3 Hardware-in-the-loop tests (RP2040 + ASIC or FPGA build)

- Reset, program, verify, run on each of the four processors.
- 1,000 repeated program/verify cycles with random images and zero CRC failures at the default clock.
- Sustained TX at the maximum link rate for ≥ 10 s: `rx_overflows = 0`, `rx_framing_errors = 0`, byte counts per processor exact.
- `tx_hold` behaviour: asserting mid-stream stops new words within 12 cycles; releasing resumes without losing or duplicating any word.
- Clock sweep: find and record the highest clock with all of the above passing.
- Unplug or hold the ASIC in reset: all blocking calls return `TIMEOUT`, none hang.

The FPGA build in [`fpga/`](../fpga) is an acceptable stand-in for the ASIC until silicon exists.

---

## 14. Phasing

| Phase | Scope |
|---|---|
| **v1** | Everything marked required above: init/reset, `pemu_program`/`program_many`/`confirm`, run/idle, DATA send, background receive with per-processor buffers, stats, host-side tests, one example per feature |
| **v1.1** | `pemu_image_from_text`, async DATA send, receive callback, automatic flow control, clock-trim self-test routine |
| **v2** | Second link (two ASICs), RP2350 support, MicroPython bindings, a command-line tool on the host that loads a program over USB-serial through the Pico |

---

## 15. Open questions (must be resolved before implementation)

These are things that either the repo does not yet define, or that the ASIC team must decide, and which change the library.

1. **ASIC pin mapping.** `tt_um_.v` and `info.yaml` still describe the older single-processor top level (`ui[7:5]` programming pins). The new RX/TX modules are not yet instantiated, and which `ui`/`uo`/`uio` pins carry `clk`, `rst_n`, `cs_n`, `mosi`, `prog_ok`, `tx_hold`, `tx_cs_n` and `miso` is undefined. Tiny Tapeout supplies `clk` and `rst_n` on dedicated pins, so the RP2040 would drive those through the board's mux. Confirm this works for the target board.
2. **Processor byte output.** The TX spec notes the processor has no byte-output port yet. Until the ISA defines how a processor pushes a byte, the receive half of the library can only be tested with synthetic words.
3. **Achievable clock and sampling margin.** Maximum ASIC clock and the RP2040 PIO timing budget are unknown. The default 10 MHz is a guess to be replaced by measurement.
4. **`tx_priority` source.** `spi_tx_top` takes a per-processor `tx_priority` input. Nothing says who controls it (a fixed strap, a processor register, a master command). If it is meant to be set by the master, the RX protocol needs a way to carry it, and the library needs an API.
5. **Assembler output format.** The repo's assembler ([`assembler/`](../assembler)) and the FPGA text format ([`fpga/instructions.txt`](../fpga/instructions.txt)) are different. Which one is the library's input? If the assembler emits a binary or hex file, add an offline conversion script to the toolchain and define the `.bin` layout (address-ordered, 256-byte padded?).
6. **Behaviour of an interrupted PROGRAM frame.** Per the RX spec, a frame cut inside a byte writes nothing for that byte and reports the CRC of the complete bytes. Decide whether the library should treat such a report as a retry condition (recommended) and state this.
7. **Gap handling when programming sparse images.** The FPGA tool pads unlisted addresses with `00000000`. Should the library also fill gaps, or leave existing memory alone as the RX spec does? Default proposed: leave alone.
8. **Reset and the processor GPIO side-effects.** RX spec note 9: holding a processor in reset resets its GPIO outputs. The library cannot fix this, but documentation should state that a program load will glitch the processor's pins.
9. **Error recovery when the ASIC reports a CRC for a frame the library did not send.** Most likely line noise on `cs_n`. Proposal: count it (`status_unmatched`) and ignore it, but this needs to be confirmed against the hardware's behaviour.

---

## 16. Electrical and board notes (for the wiring guide)

- RP2040 GPIOs are 3.3 V. Confirm the ASIC board's I/O voltage and add level shifting if it differs. Level shifters add delay and affect §9.3.
- `rst_n` should have a defined level while the RP2040 boots. Recommend a pull-down so the ASIC stays in reset until `pemu_init`.
- Keep `clk` short and away from the data lines. The clock is the one edge-critical signal.
- A common ground between the boards is mandatory.
- Series damping resistors (≈ 33 Ω) on `clk` are recommended in the wiring guide.

---

## 17. Suggested repository layout

```
rp2040_lib/
├── SPEC.md                 this document
├── README.md               quick start (deliverable)
├── CMakeLists.txt          library target
├── include/pemu/
│   ├── pemu.h              public session API
│   ├── pemu_protocol.h     constants, CRC, frame builders
│   └── pemu_config.h       compile-time options
├── src/
│   ├── pemu_session.c      L3
│   ├── pemu_protocol.c     L2 (no SDK includes)
│   ├── pemu_link.c         L1: DMA, ring buffers, IRQ
│   ├── pemu_pins.c         L0
│   └── pemu_link.pio       PIO program(s)
├── examples/
│   ├── blink/              load and run a small program, read a byte back
│   ├── multi_program/      program four processors with pemu_program_many
│   ├── data_stream/        send a DATA frame, receive replies
│   └── throughput/         sustained TX rate test, prints stats
└── test/
    ├── host/               L2 unit tests (§13.1)
    ├── sim/                RTL co-simulation (§13.2)
    └── hil/                hardware tests (§13.3)
```

---

## 18. Acceptance checklist for v1

- [ ] All functions in §6 marked required exist, are documented, and return the codes in §6.9.
- [ ] `pemu_program` never pulses `prog_ok` without a matching CRC (tested with the fake link and in simulation).
- [ ] `clk` never stops while the library is initialised, even during underrun.
- [ ] Data loss is always visible in stats and last-error.
- [ ] Host-side tests (§13.1) pass in CI.
- [ ] Program-verify-run works on all four processors on hardware or FPGA.
- [ ] Maximum working clock and measured throughput recorded in the docs.
- [ ] No heap use; no blocking calls in interrupt context.
- [ ] §15 open questions each have a recorded answer or an explicit deferral.
