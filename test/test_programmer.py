import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

ADDRESS_WIDTH = 8
INSTRUCTION_WIDTH = 6
WORD_WIDTH = ADDRESS_WIDTH + INSTRUCTION_WIDTH


async def reset(dut):
    dut.rst_n.value = 0
    dut.program_data.value = 0
    dut.program_en.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)


async def send_bits(dut, value, width):
    dut.program_en.value = 1
    for bit in range(width - 1, -1, -1):
        dut.program_data.value = (value >> bit) & 1
        await FallingEdge(dut.clk)
    dut.program_en.value = 0
    await FallingEdge(dut.clk)
    await Timer(1, unit="ns")


@cocotb.test()
async def test_programs_address_and_instruction_msb_first(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    # Address 0xA5 followed by instruction 0x2C.
    word = (0xA5 << INSTRUCTION_WIDTH) | 0x2C
    await send_bits(dut, word, WORD_WIDTH)

    assert int(dut.address_out.value) == 0xA5
    assert int(dut.instruction_out.value) == 0x2C
    assert int(dut.write_en.value) == 1
    await FallingEdge(dut.clk)
    assert int(dut.write_en.value) == 0


@cocotb.test()
async def test_incomplete_word_is_discarded(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    await send_bits(dut, 0xA53, 12)
    assert int(dut.write_en.value) == 0
    assert int(dut.address_out.value) == 0
    assert int(dut.instruction_out.value) == 0

    word = (0x12 << INSTRUCTION_WIDTH) | 0x34
    await send_bits(dut, word, WORD_WIDTH)
    assert int(dut.address_out.value) == 0x12
    assert int(dut.instruction_out.value) == 0x34
    assert int(dut.write_en.value) == 1


@cocotb.test()
async def test_extra_bits_do_not_corrupt_word(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    dut.program_en.value = 1
    word = (0xBE << INSTRUCTION_WIDTH) | 0x2F
    for bit in range(WORD_WIDTH - 1, -1, -1):
        dut.program_data.value = (word >> bit) & 1
        await FallingEdge(dut.clk)
    # The programmer accepts one 14-bit word per enable pulse.
    for bit in (1, 0, 1, 0):
        dut.program_data.value = bit
        await FallingEdge(dut.clk)
    dut.program_en.value = 0
    await FallingEdge(dut.clk)
    await Timer(1, unit="ns")

    assert int(dut.address_out.value) == 0xBE
    assert int(dut.instruction_out.value) == 0x2F
    assert int(dut.write_en.value) == 1
