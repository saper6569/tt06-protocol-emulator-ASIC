import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly

async def reset(dut):
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.wait_cycles.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)
    
async def cycles_until_done(dut, k):
    await FallingEdge(dut.clk)
    dut.wait_cycles.value = k
    dut.start.value = 1
    await ReadOnly()
    assert dut.done.value == 0, "done must be low during start cycle"
    
    await FallingEdge(dut.clk)
    dut.start.value = 0
    await ReadOnly()
    cycles = 1
    while dut.done.value == 0:
        await FallingEdge(dut.clk)
        await ReadOnly()
        cycles += 1
    return cycles

    
@cocotb.test()
async def test_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit ="ns").start())
    await reset(dut)
    assert dut.done.value == 1, "done should be high after reset (timer idle at 0)"
    
@cocotb.test()
async def test_wait_timing(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit = "ns").start())
    await reset(dut)
    for k in [0,1, 3, 63, 1000]:
        cycles = await cycles_until_done(dut, k)
        assert cycles == k+1, f"WAIT({k}): done after {cycles} cycles, expect {k+1}"
        
@cocotb.test()
async def test_stays_done(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit ="ns").start())
    await reset(dut)
    await cycles_until_done(dut, 3)
    for i in range(5):
        await FallingEdge(dut.clk)
        await ReadOnly()
        assert dut.done.value == 1, f"done dropped {i + 1} cycles after wait if finished"
