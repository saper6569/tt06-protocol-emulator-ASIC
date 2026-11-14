import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly, Timer
from test_processor_spi import spi_send_program, spi_start_program, pin, SCLK, MOSI, MISO, CS
from test_processor import step

async def reset_chip(dut):
    # start clock; drive ALL inputs (ui_in, uio_in, ena); rst_n low, then high
    dut.rst_n.value = 0
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.ena.value = 1
    
    cocotb.start_soon(Clock(dut.clk, 10, unit = "ns").start())
    await step(dut)
    await step(dut)
    dut.rst_n.value = 1
    await Timer(1, unit = "ns")
    
    
@cocotb.test()
async def test_reset_state(dut):
    # after reset: uio_oe == 0 (no pin driven)
    await reset_chip(dut)
    await FallingEdge(dut.clk)
    await ReadOnly()
    assert dut.uio_oe.value == 0, f"expected value is 0, actual value is {dut.uio_oe.value}"

async def load_program(dut, program):
    # for each (addr, instr): 16 bits on ui_in[6] with ui_in[7] high, then ui_in[7] low
    for addr, instr in enumerate(program):
        word = (addr << 8) | instr  #Packs address and instr together to make 16-bit word
        
        for i in range(15, -1, -1): #loop sets MSB first for word
            await FallingEdge(dut.clk)
            bit = (word >> i) & 1 #puts 1 bit onto the programmer data wire
            dut.ui_in.value = (1 << 7) | (bit << 6) #sets the enable and bit value are 1
            
        await FallingEdge(dut.clk)
        dut.ui_in.value = 0 #enable drops: programmer writes word
        
        await FallingEdge(dut.clk)
        await FallingEdge(dut.clk)  #gap between next word
            

async def run_program(dut, program):
    # reset_chip, load_program, then ui_in[5] = 1
    await reset_chip(dut)
    await load_program(dut, program)
    await FallingEdge(dut.clk)
    dut.ui_in.value = (1 << 5)
    
async def send_and_capture(dut,byte):
     # Plays the SPI device: records MOSI on each SCLK rising edge while CS is low.
    await run_program(dut, spi_send_program(byte))
    bits = []
    prev_sclk = 0
    for _ in range(3000):
        await FallingEdge(dut.clk)
        await ReadOnly()
        sclk = pin(dut, "uio_out", SCLK)
        cs = pin(dut, "uio_out", CS)
        if sclk == 1 and prev_sclk == 0 and cs == 0:
            bits.append(pin(dut, "uio_out", MOSI))
        prev_sclk = sclk
    return bits

@cocotb.test()
async def test_spi_start_sequence(dut):
    # same checks as the processor version, but on uio_oe / uio_out
    await run_program(dut,spi_start_program())
    for _ in range(100):
        await FallingEdge(dut.clk) 
    await ReadOnly()
    assert pin(dut, "uio_oe", SCLK) == 1, "SCLK should be driven"
    assert pin(dut, "uio_oe", CS) == 1, "CS should be driven"
    assert pin(dut, "uio_out", SCLK) == 0, "SCLK should be low"
    assert pin(dut, "uio_out", CS) == 0, "CS should be low"

@cocotb.test()
async def test_spi_send_c1(dut):
    bits = await send_and_capture(dut, 0xC1)
    assert len(bits) == 8, f"expected 8 SCLK pulses, saw {len(bits)}"
    received = int("".join(map(str, bits)), 2)
    assert received == 0xC1, f"device received {received:#04x}, expected 0xc1"
    
@cocotb.test()
async def test_spi_send_a5(dut):
    bits = await send_and_capture(dut, 0xA5)
    assert len(bits) == 8, f"expected 8 SCLK pulses, saw {len(bits)}"
    received = int("".join(map(str, bits)), 2)
    assert received == 0xA5, f"device received {received:#04x}, expected 0xa5"
