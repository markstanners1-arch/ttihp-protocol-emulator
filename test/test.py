# SPDX-FileCopyrightText: © 2026 Mark Stanners
# SPDX-License-Identifier: Apache-2.0
#
# Drives the chip only through its pins, as a real host would (SPI host port on ui_in[2:0] / uo_out[0]):
#   1. write a setting and read it back
#   2. load engine A with the UART transmit program, start it, send 'U' through its FIFO
#   3. decode the serial line on engine pin 0 (uio[0]) and check the byte
# Runs on the RTL and, in the gate-level test, on the final netlist.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

HALF = 8                     # SCK half period in chip clocks (SPI must be <= clk/8)

# programs/uart_tx.asm, assembled by model/asm.py
UART_TX = [0xD881, 0x9FA0, 0xD727, 0x6001, 0x0643]


class Host:
    def __init__(self, dut):
        self.dut = dut
        self.ui = 0b001                       # CS high, SCK low, MOSI low

    def _set(self, cs=None, sck=None, mosi=None):
        if cs is not None:   self.ui = (self.ui & ~1) | cs
        if sck is not None:  self.ui = (self.ui & ~2) | (sck << 1)
        if mosi is not None: self.ui = (self.ui & ~4) | (mosi << 2)
        self.dut.ui_in.value = self.ui

    async def _bit(self, b):
        self._set(mosi=b)
        await ClockCycles(self.dut.clk, HALF)
        self._set(sck=1)
        r = int(self.dut.uo_out.value) & 1
        await ClockCycles(self.dut.clk, HALF)
        self._set(sck=0)
        return r

    async def transfer(self, cmd, words):
        self._set(cs=0)
        await ClockCycles(self.dut.clk, HALF)
        for i in range(15, -1, -1):                      # 16-bit command: [15] read, [14:12] engine, [5:0] register
            await self._bit((cmd >> i) & 1)
        got = []
        for w in words:
            g = 0
            for i in range(15, -1, -1):
                g |= await self._bit((w >> i) & 1) << i
            got.append(g)
        await ClockCycles(self.dut.clk, HALF)
        self._set(cs=1)
        await ClockCycles(self.dut.clk, 2 * HALF)
        return got

    async def write(self, eng, reg, *words):
        await self.transfer((eng << 12) | reg, list(words))

    async def read(self, eng, reg, n=1):
        return await self.transfer(0x8000 | (eng << 12) | reg, [0] * n)


@cocotb.test()
async def test_project(dut):
    clock = Clock(dut.clk, 20, unit="ns")     # 50 MHz
    cocotb.start_soon(clock.start())
    dut.ena.value = 1
    dut.ui_in.value = 0b001
    dut.uio_in.value = 0xFF                   # pull-ups on the two-way pins
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)
    host = Host(dut)

    # 1. a setting written and read back
    await host.write(0, 0x21, 0x1234)
    (v,) = await host.read(0, 0x21)
    dut._log.info(f"CLKDIV read back 0x{v:04X}")
    assert v == 0x1234

    # 2. engine A: UART transmitter, one bit = 8 engine ticks, clkdiv 0 -> 8 chip clocks per bit
    await host.write(0, 0x00, *(UART_TX + [0] * (32 - len(UART_TX))))
    await host.write(0, 0x21, 0)                                  # CLKDIV
    await host.write(0, 0x22, 0 | (1 << 5) | (4 << 10))           # start 0, wrap 1..4
    await host.write(0, 0x23, 1 << 5)                             # out_base 0, out_count 1, set_base 0
    await host.write(0, 0x24, 1 | (1 << 8) | (1 << 10) | (1 << 11))   # set_count 1, side 1 opt, out_right
    await host.write(0, 0x20, 1)                                  # RUN
    (st,) = await host.read(0, 0x28)
    assert (st >> 8) & 1 == 1, f"engine A not running (STATUS 0x{st:04X})"
    await ClockCycles(dut.clk, 20)
    assert int(dut.uio_oe.value) & 1 == 1, "engine pin 0 not driven"
    assert int(dut.uio_out.value) & 1 == 1, "UART line not idling high"

    # 3. send 'U' and decode it from the pin. The receiver starts listening BEFORE the byte is pushed
    #    (the engine starts sending within a few clocks, before the SPI write has even finished).
    def line():
        return int(dut.uio_out.value) & 1

    async def receive():
        for _ in range(4000):
            await ClockCycles(dut.clk, 1)
            if line() == 0:
                break
        else:
            return None
        await ClockCycles(dut.clk, 4)             # middle of the start bit
        if line() != 0:
            return None
        b = 0
        for i in range(8):
            await ClockCycles(dut.clk, 8)
            b |= line() << i
        await ClockCycles(dut.clk, 8)
        return b if line() == 1 else None          # stop bit must be high

    rx = cocotb.start_soon(receive())
    await host.write(0, 0x26, ord("U"))
    byte = await rx
    assert byte is not None, "no valid frame seen"
    dut._log.info(f"engine A sent 0x{byte:02X}")
    assert byte == ord("U")

    # 4. the input glitch filter register (chip-wide, 0x29) reads back
    await host.write(0, 0x29, 0x2F)
    (f,) = await host.read(1, 0x29)
    assert f == 0x2F, f"FILTER read back 0x{f:04X}"
