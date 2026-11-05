// CRC unit, one per engine (docs/isa.md v0.3, "CRC unit"): a 32-bit register in the right-shifting (reflected) form.
// One step per bit: crc = (crc >> 1) ^ (poly if crc[0] ^ bit else 0). Polynomial and start value come from the host
// registers CRCPOLY and CRCINIT. A 16-bit polynomial and start value with their upper halves zero stay a 16-bit CRC in the
// low half. clr (TIME 5, or a serialiser frame start) reloads the start value and wins over a step in the same clock.
// In 74-series terms: a 32-bit shift register with one XOR per bit under a gated polynomial, like the 74F401 but programmable.

`timescale 1ns/1ps
`default_nettype none

module crc32 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] poly,
    input  wire [31:0] init,
    input  wire        clr,
    input  wire        step,
    input  wire        bit_in,
    output reg  [31:0] crc
);
    wire        fb  = crc[0] ^ bit_in;
    wire [31:0] nxt = (crc >> 1) ^ (fb ? poly : 32'd0);

    always @(posedge clk) begin
        if (!rst_n)    crc <= init;
        else if (clr)  crc <= init;
        else if (step) crc <= nxt;
    end
endmodule
