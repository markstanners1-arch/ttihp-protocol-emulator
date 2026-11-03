## How it works

Four small programmable engines, each running its own 32-instruction program, one instruction per tick of a
programmable clock divider. Eight instructions: JMP, WAIT (with optional timeout), IN, OUT, PUSH/PULL, MOV, SET,
and TIME, a stopwatch that measures how long a pin takes to change. Programs implement UART, SPI, I2C and others
as firmware. A host (RP2040, ESP32, Raspberry Pi) loads programs, settings and data over an SPI host port.

## How to test

Drive the SPI host port (mode 0, SCK at most clk/8): 16-bit command `[15] read, [14:12] engine, [5:0] register`, then
16-bit words. Load the UART program into engine A, set RUN, push bytes to register 0x26 and watch engine pin 0.

## External hardware

Any microcontroller with SPI as the host. Optional: a UART, I2C or SPI device to talk to.
