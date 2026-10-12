import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

async def reset(dut):
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.wait_cycles.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)
    
@cocotb.test()
async def test_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit ="ns").start())
    await reset(dut)
    assert dut.done.value == 1, "done should be high after reset (timer idle at 0)"