# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


@cocotb.test()
async def test_serial_program_and_run(dut):
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    assert int(dut.uo_out.value) == 0

    # Program address 0 with a wait-for-low instruction on GPIO 0.
    word = 0x0000
    dut.ui_in.value = 0x80
    for bit in range(15, -1, -1):
        dut.ui_in.value = 0x80 | ((word >> bit) & 1) << 6
        await RisingEdge(dut.clk)
    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 3)

    # Run the programmed instruction and verify the program counter advances.
    dut.ui_in.value = 0x20
    await ClockCycles(dut.clk, 3)
    assert int(dut.uo_out.value) == 1
