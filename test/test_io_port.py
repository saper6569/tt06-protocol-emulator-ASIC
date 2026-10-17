import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer


@cocotb.test()
async def test_push_pull_drive_and_readback(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 1
    dut.gpio_mode.value = 0x00
    dut.write_en.value = 0xFF
    dut.gpio_out.value = 0xA5
    dut.external_drive_en.value = 0x00
    dut.external_drive.value = 0x00
    await Timer(1, unit="ns")

    assert int(dut.gpio_pad_out.value) == 0xA5
    assert int(dut.gpio_pad_oe.value) == 0xFF
    assert int(dut.gpio.value) == 0xA5
    assert int(dut.gpio_in.value) == 0xA5

    dut.gpio_out.value = 0x5A
    await Timer(1, unit="ns")
    assert int(dut.gpio_pad_out.value) == 0x5A
    assert int(dut.gpio.value) == 0x5A
    assert int(dut.gpio_in.value) == 0x5A


@cocotb.test()
async def test_disabled_outputs_release_pins_and_read_external_values(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 1
    dut.gpio_out.value = 0xFF
    dut.gpio_mode.value = 0x00
    dut.write_en.value = 0x00

    dut.external_drive_en.value = 0xFF
    dut.external_drive.value = 0x96
    await Timer(1, unit="ns")
    assert int(dut.gpio_pad_oe.value) == 0
    assert int(dut.gpio_in.value) == 0x96

    dut.external_drive.value = 0x69
    await Timer(1, unit="ns")
    assert int(dut.gpio_in.value) == 0x69


@cocotb.test()
async def test_open_drain_drives_low_and_releases_high(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 1
    dut.gpio_mode.value = 0xFF
    dut.write_en.value = 0xFF
    dut.gpio_out.value = 0x00
    dut.external_drive_en.value = 0xFF
    dut.external_drive.value = 0xFF
    await Timer(1, unit="ns")

    assert int(dut.gpio_pad_out.value) == 0x00
    assert int(dut.gpio_pad_oe.value) == 0xFF
    assert int(dut.gpio.value) == 0x00
    assert int(dut.gpio_in.value) == 0x00

    dut.gpio_out.value = 0xFF
    await Timer(1, unit="ns")
    assert int(dut.gpio_pad_out.value) == 0x00
    assert int(dut.gpio_pad_oe.value) == 0x00
    assert int(dut.gpio.value) == 0xFF
    assert int(dut.gpio_in.value) == 0xFF


@cocotb.test()
async def test_mixed_pin_modes_and_enables(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 1
    dut.gpio_out.value = 0b10101100
    dut.gpio_mode.value = 0b11110000
    dut.write_en.value = 0b11111111
    dut.external_drive_en.value = 0xFF
    dut.external_drive.value = 0b01010101
    await Timer(1, unit="ns")

    assert int(dut.gpio_pad_out.value) == 0b00001100
    assert int(dut.gpio_pad_oe.value) == 0b01011111
    # Open-drain highs release, open-drain lows drive low; push-pull drives both levels.
    assert int(dut.gpio.value) == 0b00001100
    assert int(dut.gpio_in.value) == 0b00001100

    # Released open-drain pins read the external high level; disable selected
    # push-pull pins so their external values are visible too.
    dut.write_en.value = 0b11110000
    dut.gpio_out.value = 0xFF
    await Timer(1, unit="ns")
    assert int(dut.gpio.value) == 0b01010101
    assert int(dut.gpio_in.value) == 0b01010101
