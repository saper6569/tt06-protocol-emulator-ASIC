import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer


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

    # Address 0xA5 followed by instruction 0x3C.
    await send_bits(dut, 0xA53C, 16)

    assert int(dut.address_out.value) == 0xA5
    assert int(dut.instruction_out.value) == 0x3C
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

    await send_bits(dut, 0x1234, 16)
    assert int(dut.address_out.value) == 0x12
    assert int(dut.instruction_out.value) == 0x34
    assert int(dut.write_en.value) == 1


@cocotb.test()
async def test_extra_bits_do_not_corrupt_word(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    dut.program_en.value = 1
    for bit in range(15, -1, -1):
        dut.program_data.value = (0xBEEF >> bit) & 1
        await FallingEdge(dut.clk)
    # The programmer accepts one 16-bit word per enable pulse.
    for bit in (1, 0, 1, 0):
        dut.program_data.value = bit
        await FallingEdge(dut.clk)
    dut.program_en.value = 0
    await FallingEdge(dut.clk)
    await Timer(1, unit="ns")

    assert int(dut.address_out.value) == 0xBE
    assert int(dut.instruction_out.value) == 0xEF
    assert int(dut.write_en.value) == 1
