import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

async def reset(dut):
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    dut.t.value = 0
    
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")

async def toggle(dut):
    await FallingEdge(dut.clk)
    dut.t.value = 1
    await RisingEdge(dut.clk)

    await Timer(1, unit="ns")
    dut.t.value = 0

@cocotb.test()
async def testToggle(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    assert dut.q.value == 0
    await toggle(dut)

    assert dut.q.value == 1
    await toggle(dut)

    assert dut.q.value == 0
