import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly


async def reset(dut):
    dut.rst_n.value = 0
    dut.enable.value = 1
    dut.start.value = 0
    dut.wait_cycles.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)


async def cycles_until_done(dut, tick_cycles, wait_cycles):
    done_signal = getattr(dut, f"done_tick_{tick_cycles}")
    await FallingEdge(dut.clk)
    dut.wait_cycles.value = wait_cycles
    dut.start.value = 1
    await ReadOnly()
    assert int(done_signal.value) == 0, "done must be low during start"

    await FallingEdge(dut.clk)
    dut.start.value = 0
    await ReadOnly()
    cycles = 1
    while int(done_signal.value) == 0:
        await FallingEdge(dut.clk)
        await ReadOnly()
        cycles += 1
    return cycles


@cocotb.test()
async def test_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)
    assert int(dut.done_tick_1.value) == 1
    assert int(dut.done_tick_3.value) == 1


@cocotb.test()
async def test_default_and_prescaled_wait_timing(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    for wait_cycles in (0, 1, 3, 63, 1000):
        cycles = await cycles_until_done(dut, 1, wait_cycles)
        assert cycles == wait_cycles + 1, (
            f"20 ns tick WAIT({wait_cycles}): done after {cycles} cycles"
        )

    for wait_cycles in (0, 1, 3, 10):
        cycles = await cycles_until_done(dut, 3, wait_cycles)
        assert cycles == wait_cycles * 3 + 1, (
            f"60 ns tick WAIT({wait_cycles}): done after {cycles} cycles"
        )


@cocotb.test()
async def test_prescaled_count_holds_between_ticks(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)

    await FallingEdge(dut.clk)
    dut.wait_cycles.value = 2
    dut.start.value = 1
    await FallingEdge(dut.clk)
    dut.start.value = 0
    assert int(dut.count_tick_3.value) == 2

    for expected_prescale_count in (2, 2, 1):
        await FallingEdge(dut.clk)
        assert int(dut.count_tick_3.value) == expected_prescale_count
