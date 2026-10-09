import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

async def reset(dut):
	dut.rst_n.value = 0
	dut.push.value = 0 
	dut.pop.value = 0
	dut.data_in.value = 0

	await RisingEdge(dut.clk)
	await RisingEdge(dut.clk)
	
	dut.rst_n.value = 1
	await RisingEdge(dut.clk)

async def push(dut, value):
	dut.data_in.value = value
	dut.push.value = 1

	await RisingEdge(dut.clk)

	dut.push.value = 0

async def pop(dut):
	value = int(dut.data_out.value)
	
	dut.pop.value = 1
	await RisingEdge(dut.clk)
	await FallingEdge(dut.clk)
	dut.pop.value = 0

	return value

@cocotb.test()
async def test_dut(dut):
	cocotb.start_soon(
		Clock(dut.clk, 10, unit="ns").start()
	)

	await reset(dut)

	#starts empty
	assert dut.empty.value == 1
	assert dut.full.value == 0

	#push 3
	await push(dut, 0x11)
	await push(dut, 0x22)
	await push(dut, 0x33)

	assert dut.empty.value == 0
	
	#pop 3
	assert await pop(dut) == 0x11
	assert await pop(dut) == 0x22
	assert await pop(dut) == 0x33

	assert dut.empty.value == 1
	
	#push full
	await push(dut, 0xAA)
	dut._log.info(f"after AA: count={dut.dut.count.value} full={dut.full.value}")

	await push(dut, 0xBB)
	dut._log.info(f"after BB: count={dut.dut.count.value} full={dut.full.value}")

	await push(dut, 0xCC)
	dut._log.info(f"after CC: count={dut.dut.count.value} full={dut.full.value}")

	await push(dut, 0x0D)
	dut._log.info(f"after 0D: count={dut.dut.count.value} full={dut.full.value}")	
	assert dut.full.value == 1

	#check for pops
	assert await pop(dut) == 0xAA
	assert await pop(dut) == 0xBB
	assert await pop(dut) == 0xCC
	assert await pop(dut) == 0x0D

	assert dut.empty.value == 1



