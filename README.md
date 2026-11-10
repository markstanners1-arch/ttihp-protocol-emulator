![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Protocol emulator

Four small programmable engines behind an SPI host port, engine A with a bit-cell serialiser (Manchester or NRZ, up to
10 Mbit/s), for Tiny Tapeout on IHP SG13 CMOS5L (8x4 tiles, 40 MHz).
Each engine runs its own 32-instruction program, one instruction per tick of its own clock divider, on the chip's 19
protocol pins. UART, SPI, I2C, NEC infrared and DALI are programs, not fixed hardware, and the same engines measure
the wire with a stopwatch instruction and a programmable input glitch filter. A host microcontroller loads the programs
and exchanges data through the SPI port. Top module: `tt_um_gosforth_protocol_emu`.

- Datasheet: [docs/info.md](docs/info.md) (instruction set, host port registers, pinout, test results, layout figures)
- Design repository: [github.com/markstanners1-arch/protocol-asic](https://github.com/markstanners1-arch/protocol-asic)
  (Python reference model, random side-by-side tests, whole-chip test, engine programs, FPGA builds, bench records).
  `src/` here is the Verilog this chip is built from.
- Layout viewer: [markstanners1-arch.github.io/ttihp-protocol-emulator](https://markstanners1-arch.github.io/ttihp-protocol-emulator/)

## Run the test

The cocotb test drives the chip only through its pins: it writes and reads back a setting, loads engine A with the
UART transmit program, sends a byte and decodes it from the pin, and checks the chip-wide filter register. It needs
Icarus Verilog and Python.

```sh
cd test
pip install -r requirements.txt
make -B
```

The gate-level version (`make -B GATES=yes`) runs on the hardened netlist; see [test/README.md](test/README.md).

## About Tiny Tapeout

Tiny Tapeout makes it cheaper and easier to get digital and analog designs made on a real chip:
[tinytapeout.com](https://tinytapeout.com).
