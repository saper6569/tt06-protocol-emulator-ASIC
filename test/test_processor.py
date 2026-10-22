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

    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await step(dut)
    await step(dut)
    dut.rst_n.value = 1
    await Timer(1, unit="ns")


async def issue_instruction(dut, instruction):
    dut.mem_data_in.value = instruction
    await step(dut)  # Fetch request
    await step(dut)  # Capture instruction
    await step(dut)  # Execute instruction


async def wait_for_fetch(dut, limit=40):
    for _ in range(limit):
        if int(dut.state.value) == 0:
            return
        await step(dut)
    assert int(dut.state.value) == 0, "instruction did not complete"


@cocotb.test()
async def test_all_instruction_range_boundaries(dut):
    await reset(dut)

    # 0: wait timer.
    await issue_instruction(dut, 0)
    await wait_for_fetch(dut)
    assert int(dut.PC.value) == 1

    # 1 and 4: first and last wait-for IO values (default level is low).
    for instruction, io_index in ((1, 0), (4, 3)):
        dut.gpio_in.value = 1 << io_index
        await issue_instruction(dut, instruction)
        assert int(dut.setup_complete.value) == 1
        dut.gpio_in.value = 0
        await step(dut)
        assert int(dut.state.value) == 0

    # 5 and 8: first and last shift output values.
    await issue_instruction(dut, 26)  # Shift 1 into the register.
    await issue_instruction(dut, 5)
    assert int(dut.gpio_out.value) & 0x1
    assert int(dut.gpio_write_en.value) & 0x1
    await issue_instruction(dut, 26)
    await issue_instruction(dut, 8)
    assert int(dut.gpio_out.value) & 0x8
    assert int(dut.gpio_write_en.value) & 0x8

    # 9 and 12: first and last IO-mode toggles.
    await issue_instruction(dut, 9)
    await issue_instruction(dut, 12)
    assert int(dut.gpio_mode.value) == 0x9

    # 13 toggles the level used by wait-for.
    await issue_instruction(dut, 13)
    assert int(dut.wait_for_value.value) == 1
    dut.gpio_in.value = 0
    await issue_instruction(dut, 1)
    assert int(dut.setup_complete.value) == 1
    dut.gpio_in.value = 1
    await step(dut)
    assert int(dut.state.value) == 0

    # 14 toggles shift direction; in this direction the selected IO shifts in.
    await issue_instruction(dut, 14)
    dut.gpio_in.value = 0x4
    await issue_instruction(dut, 7)
    assert int(dut.shift_reg.value) & 1
    await issue_instruction(dut, 14)

    # 15 and 25: first and last counter-bit toggles.
    await issue_instruction(dut, 15)
    await issue_instruction(dut, 25)
    assert int(dut.timer_wait_cycles.value) == (1 | (1 << 10))

    # 26 and 27: shift constants into the register.
    await issue_instruction(dut, 27)
    assert int(dut.shift_reg.value) & 1 == 0
    await issue_instruction(dut, 26)
    assert int(dut.shift_reg.value) & 1 == 1

    # 28 and 31: first and last jump targets.
    await issue_instruction(dut, 28)
    assert int(dut.PC.value) == 0
    await issue_instruction(dut, 31)
    assert int(dut.PC.value) == 96


@cocotb.test()
async def test_wait_for_io_and_counter_toggles(dut):
    await reset(dut)

    # Toggle counter bits 0 and 4 to configure a wait of 17 ticks.
    await issue_instruction(dut, 15)
    await issue_instruction(dut, 19)
    assert int(dut.timer_wait_cycles.value) == 0x11

    # IO2 waits for its low level.
    dut.gpio_in.value = 0x04
    await issue_instruction(dut, 3)
    assert int(dut.PC.value) == 3
    assert int(dut.setup_complete.value) == 1
    dut.gpio_in.value = 0
    await step(dut)
    assert int(dut.setup_complete.value) == 0
    assert int(dut.PC.value) == 3

    # Toggle the desired level high, then wait for IO2 to become high.
    await issue_instruction(dut, 13)
    await issue_instruction(dut, 3)
    assert int(dut.setup_complete.value) == 1
    dut.gpio_in.value = 0x04
    await step(dut)
    assert int(dut.setup_complete.value) == 0
    assert int(dut.PC.value) == 5

    # Timer instruction waits for the configured duration.
    await issue_instruction(dut, 0)
    await wait_for_fetch(dut)
    assert int(dut.PC.value) == 6


@cocotb.test()
async def test_jumps_select_four_equal_memory_sections(dut):
    await reset(dut)

    for section in range(4):
        await issue_instruction(dut, 28 + section)
        assert int(dut.PC.value) == section * 32


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
    for _ in range(10):
        await step(dut)
        if int(dut.state.value) == 0:
            break
    assert int(dut.state.value) == 0
    assert int(dut.PC.value) == 1
