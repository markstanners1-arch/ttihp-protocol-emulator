/*
 * Copyright (c) 2026 Mark Stanners
 * SPDX-License-Identifier: Apache-2.0
 *
 * Protocol emulator: four small programmable engines that run UART/SPI/I2C (and more) as firmware, loaded and driven
 * over an SPI host port; engine 0 also sends and receives Manchester frames (10 Mbit/s Ethernet). Full design, models
 * and tests: the ProtocolASIC repository (docs/core_design.md, docs/isa.md, docs/host_port.md).
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
    wire rx_pad, rx_fall;
    protocol_chip #(.NENG(4), .CRC(0)) chip (        // four engines without CRC units, SRAM macro program stores and engine 0 TX FIFO (src/ is a copy of the design repository's)
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(ena), .clk(clk), .rst_n(rst_n), .rx_pad(rx_pad), .rx_fall(rx_fall));

    // engine 0's receive pin held at the falling edge of clk: IHP has no falling-edge flip-flop, so a latch that is open
    // while clk is high and frozen when it falls (the chip then takes it through flip-flops matched to its rising-edge
    // synchroniser). The pin is asynchronous to clk: pnr.sdc sets a false path to the latch input.
    sg13cmos5l_dlhq_1 u_rx_fall (.Q(rx_fall), .D(rx_pad), .GATE(clk));
endmodule
