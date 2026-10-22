#SPI (Mode 0, MSB first) written for the protocol-emulator ISA, checked by running it on processor.v
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly, Timer

SCLK, MOSI, MISO, CS = 0, 1, 2, 3   #pin assignments

# Flat 5-bit instruction encodings.
def shift_in_const(v): return 26 if v else 27
def shift_out(pin):    return 5 + pin
def jump(section):     return 28 + section

#produces 2 instr bytes and adds them to program list
def set_pin(pin, value):
#no set pin instr exists, so push and const and shift it out
    return [shift_in_const(value), shift_out(pin)]

#stops the program safely at the end, makes processor loop on one instr forever
def park(program):
    # Jump to section 1, whose first instruction loops to itself.
    program.append(jump(1))
    while len(program) < 64:
        program.append(jump(1))
    program.append(jump(1))
    return program

def spi_start_program():
    p = []
    p += set_pin(SCLK, 0) #idle: clk low
    p += set_pin(CS, 1) #idle: not selected
    p += set_pin(CS, 0) #select the device: transfer starts
    return park(p)

async def run_memory(dut, program):
    #after each clock edge, return the instruction at the address the processor asks for
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        addr = int(dut.mem_addr_out.value)
        await Timer(1, unit = "ns")     #leave read-only phase before wiring
        dut.mem_data_in.value = program[addr] if addr < len(program) else 0
        
async def start_processor(dut, program):
    cocotb.start_soon(Clock(dut.clk, 20, unit ="ns").start())
    dut.rst_n.value = 0
    dut.programming_mode.value = 0
    dut.gpio_in.value = 0
    dut.mem_data_in.value = 0
    await Timer(20, unit = "ns")
    dut.rst_n.value = 1
    cocotb.start_soon(run_memory(dut, program))
    
    
def pin(dut, signal, p):
    #read one pin's but out of an 8-bit bus like gpio_out
    return(int(getattr(dut, signal).value) >> p) & 1

@cocotb.test()
async def test_spi_start_sequence(dut):
    await start_processor(dut, spi_start_program())
    for _ in range(100):
        await FallingEdge(dut.clk)
    await ReadOnly()
    assert pin(dut, "gpio_write_en", SCLK) == 1, "SCLK should be driven"
    assert pin(dut, "gpio_out", SCLK) == 0, "SCLK should idle low"
    assert pin(dut, "gpio_write_en", CS) == 1, "CS should be driven"
    assert pin(dut, "gpio_out", CS) == 0, "CS should be low (device selected)"
    
def spi_send_program(byte):
    #initial setup
    p = []
    p += set_pin(SCLK, 0)
    p += set_pin(CS, 1)
    p += set_pin(CS, 0)
    
    #load byte into shift reg
    for i in range(8):
        p.append(shift_in_const(byte >> i & 1)) #bit 0 - 7
    
    #send
    for _ in range(8):
        p.append(shift_out(MOSI)) #data bit into MOSI
        p += set_pin(SCLK, 1)
        p += set_pin(SCLK, 0)
    
    p += set_pin(CS, 1)
    return park(p)

@cocotb.test()
async def test_spi_send_byte(dut):
    await start_processor(dut, spi_send_program(0xC1))
    bits = []
    prev_sclk = 0
    
    for _ in range(3000):
        await FallingEdge(dut.clk)
        await ReadOnly()
        sclk = pin(dut, "gpio_out", SCLK)
        cs = pin(dut, "gpio_out", CS)
        if sclk == 1 and prev_sclk == 0 and cs == 0:
            bits.append(pin(dut,"gpio_out", MOSI))
        prev_sclk = sclk
    assert len(bits) == 8, f"expected 8 clk pulses , saw {len(bits)}"
    received = int("".join(map(str,bits)),2)
    assert received == 0xC1, f"device received {received:#04x}, expected 0xc1"