/*
 * Copyright (c) 2026 Mark Stanners
 * SPDX-License-Identifier: Apache-2.0
 *
 * Protocol emulator: three small programmable engines that run UART/SPI/I2C (and more) as firmware,
 * loaded and driven over an SPI host port. Full design, models and tests:
 * the ProtocolASIC repository (docs/core_design.md, docs/isa.md, docs/host_port.md).
 */

`default_nettype none

module tt_um_gosforth_protocol_emu (
    input  wire [7:0] ui_in,    // [0] CS, [1] SCK, [2] MOSI (host port); [7:3] engine inputs 15-19
    output wire [7:0] uo_out,   // [0] MISO, [1] IRQ; [7:2] engine outputs 8-13
    input  wire [7:0] uio_in,   // engine pins 0-7 (in)
    output wire [7:0] uio_out,  // engine pins 0-7 (out)
    output wire [7:0] uio_oe,   // engine pins 0-7 (direction)
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    protocol_chip chip (                    // three engines (chip.v's default; four did not place on the 6x4 tile, 3 Nov 2026)
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(ena), .clk(clk), .rst_n(rst_n));
endmodule
