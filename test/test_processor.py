import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


async def step(dut):
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")


async def reset(dut):
    dut.rst_n.value = 0
    dut.programming_mode.value = 0
    dut.mem_data_in.value = 0
    dut.gpio_in.value = 0

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await step(dut)
    await step(dut)
    dut.rst_n.value = 1
    await Timer(1, unit="ns")


async def issue_instruction(dut, instruction):
    dut.mem_data_in.value = instruction
    await step(dut)  # Fetch request
    await step(dut)  # Capture instruction
    await step(dut)  # Execute instruction


@cocotb.test()
async def test_shift_io_and_constant_sources(dut):
    await reset(dut)

    await issue_instruction(dut, 58)  # Shift 1 into the register.
    await issue_instruction(dut, 17)  # Shift register bit to IO0.
    assert int(dut.gpio_out.value) & 1 == 1
    assert int(dut.gpio_write_en.value) & 1 == 1

    await issue_instruction(dut, 59)  # Shift 0 into the register.
    await issue_instruction(dut, 17)
    assert int(dut.gpio_out.value) & 1 == 0

    dut.gpio_in.value = 0x02
    await issue_instruction(dut, 26)  # Shift IO1 into the register.
    await issue_instruction(dut, 19)  # Shift the bit to IO2.
    assert int(dut.gpio_out.value) & 0x04 == 0x04


@cocotb.test()
async def test_wait_instructions_and_timer_counter(dut):
    await reset(dut)

    # Toggle timer counter bits 0 and 4 to configure a wait of 17 cycles.
    await issue_instruction(dut, 41)
    await issue_instruction(dut, 45)
    assert int(dut.timer_wait_cycles.value) == 0x11

    # Value 3 waits for IO2 to become low.
    dut.gpio_in.value = 0x04
    await issue_instruction(dut, 3)
    assert int(dut.PC.value) == 3
    assert int(dut.setup_complete.value) == 1
    dut.gpio_in.value = 0
    await step(dut)
    assert int(dut.setup_complete.value) == 0
    assert int(dut.PC.value) == 3

    # Value 11 waits for IO2 to become high.
    await issue_instruction(dut, 11)
    assert int(dut.setup_complete.value) == 1
    dut.gpio_in.value = 0x04
    await step(dut)
    assert int(dut.setup_complete.value) == 0
    assert int(dut.PC.value) == 4

    await issue_instruction(dut, 0)  # Wait for the configured timer.
    assert int(dut.start_timer.value) == 1
    await step(dut)
    assert int(dut.timer_inst.count.value) == 0x11

    for _ in range(20):
        await step(dut)
        if int(dut.state.value) == 0:
            break
    assert int(dut.state.value) == 0
    assert int(dut.PC.value) == 5


@cocotb.test()
async def test_io_mode_and_counter_toggle_ranges(dut):
    await reset(dut)

    await issue_instruction(dut, 40)  # Toggle IO7 mode.
    assert int(dut.gpio_mode.value) == 0x80
    await issue_instruction(dut, 40)
    assert int(dut.gpio_mode.value) == 0

    await issue_instruction(dut, 57)  # Toggle timer counter bit 16.
    assert int(dut.timer_wait_cycles.value) == 1 << 16
    await issue_instruction(dut, 57)
    assert int(dut.timer_wait_cycles.value) == 0


@cocotb.test()
async def test_jumps_select_four_equal_memory_sections(dut):
    await reset(dut)

    for section in range(4):
        await issue_instruction(dut, 60 + section)
        assert int(dut.PC.value) == section * 64


@cocotb.test()
async def test_programming_mode_pauses_wait_instruction(dut):
    await reset(dut)

    dut.gpio_in.value = 0x04
    await issue_instruction(dut, 3)  # Wait for GPIO2 to become low.
    assert int(dut.state.value) == 2
    assert int(dut.PC.value) == 1

    dut.programming_mode.value = 1
    dut.gpio_in.value = 0
    for _ in range(5):
        await step(dut)
        assert int(dut.state.value) == 2
        assert int(dut.PC.value) == 1
        assert int(dut.setup_complete.value) == 1

    dut.programming_mode.value = 0
    await step(dut)
    assert int(dut.state.value) == 0
    assert int(dut.PC.value) == 1


@cocotb.test()
async def test_programming_mode_pauses_timer_countdown(dut):
    await reset(dut)
    dut.timer_wait_cycles.value = 5
    await issue_instruction(dut, 0)
    await step(dut)  # Start timer.
    assert int(dut.timer_inst.count.value) == 5

    dut.programming_mode.value = 1
    for _ in range(3):
        await step(dut)
    assert int(dut.timer_inst.count.value) == 5
    assert int(dut.state.value) == 2
    assert int(dut.PC.value) == 1

    dut.programming_mode.value = 0
    for _ in range(8):
        await step(dut)
        if int(dut.state.value) == 0:
            break
    assert int(dut.state.value) == 0
    assert int(dut.PC.value) == 1
