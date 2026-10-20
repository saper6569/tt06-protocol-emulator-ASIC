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


def bit_set_instruction(index, value):
    return 0x80 | (index << 1) | value


def shift_instruction(index, shift_out=False):
    return 0x40 | (index << 1) | int(shift_out)


@cocotb.test()
async def test_shift_constant_into_register_then_out_to_gpio(dut):
    await reset(dut)

    # Verify both constant shift sources by shifting each value to GPIO zero.
    await issue_instruction(dut, shift_instruction(9))
    await issue_instruction(dut, shift_instruction(0, shift_out=True))
    assert int(dut.gpio_out.value) == 1

    await issue_instruction(dut, shift_instruction(8))
    await issue_instruction(dut, shift_instruction(0, shift_out=True))

    assert int(dut.gpio_write_en.value) == 1
    assert int(dut.gpio_out.value) == 0
    assert int(dut.mem_write_en.value) == 0
    assert int(dut.mem_data_out.value) == 0


@cocotb.test()
async def test_timer_wait_sentinel_and_gpio_wait_encoding(dut):
    await reset(dut)

    # Bit-set indices 0 and 4 configure timer_wait_cycles to 17.
    await issue_instruction(dut, bit_set_instruction(0, 1))
    await issue_instruction(dut, bit_set_instruction(4, 1))
    assert int(dut.timer_wait_cycles.value) == 0x11

    # All non-sentinel wait instructions poll GPIO[2] for the IR[0] value.
    dut.gpio_in.value = 0x04
    await issue_instruction(dut, 0x04)
    assert int(dut.start_timer.value) == 0
    assert int(dut.PC.value) == 3
    assert int(dut.setup_complete.value) == 1

    dut.gpio_in.value = 0
    await step(dut)
    assert int(dut.setup_complete.value) == 0
    assert int(dut.PC.value) == 3

    # The same GPIO address can be polled for a high level when IR[0] is one.
    await issue_instruction(dut, 0x05)
    assert int(dut.PC.value) == 4
    assert int(dut.setup_complete.value) == 1
    dut.gpio_in.value = 0x04
    await step(dut)
    assert int(dut.setup_complete.value) == 0
    assert int(dut.PC.value) == 4

    # Address 31 is outside the configured GPIO range; ignore it and advance.
    await issue_instruction(dut, 0x3E)
    assert int(dut.PC.value) == 5
    assert int(dut.setup_complete.value) == 0

    # Only 00111111 starts a timed wait, using the previously assembled value.
    await issue_instruction(dut, 0x3F)
    assert int(dut.start_timer.value) == 1
    await step(dut)
    assert int(dut.timer_inst.count.value) == 0x11

    for _ in range(20):
        await step(dut)
        if int(dut.state.value) == 0:
            break
    assert int(dut.state.value) == 0
    assert int(dut.PC.value) == 6


@cocotb.test()
async def test_bit_set_writes_gpio_mode_after_timer_bits(dut):
    await reset(dut)

    await issue_instruction(dut, bit_set_instruction(16, 1))
    assert int(dut.gpio_mode.value) == 1

    await issue_instruction(dut, bit_set_instruction(16, 0))
    assert int(dut.gpio_mode.value) == 0


@cocotb.test()
async def test_programming_mode_pauses_wait_instruction(dut):
    await reset(dut)

    dut.gpio_in.value = 0x04
    await issue_instruction(dut, 0x04)  # Wait for GPIO[2] to become low.
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
    await issue_instruction(dut, 0x3F)
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
