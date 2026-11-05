// IHP SRAM macro RM_IHPSG13_1P_64x16_c2 as seen by the two builds of this repo.
//
// Simulation (cocotb RTL test and gate-level test, COCOTB_SIM defined): a behavioural array with the macro's
// timing, one port, read data registered on A_CLK (appears the clock after the address). The real block's
// own model (IHP's RM_IHPSG13_1P_64x16_c2.v with -DFUNCTIONAL) is what the design repository's cosim runs
// against the Python model; this file only has to agree with it, and does for everything prog_mem.v uses.
//
// Synthesis and layout: an empty black box, so yosys keeps the instance and LibreLane places the macro from
// its LEF (src/config.json, MACROS). A_DLY must be tied 1 (IHP datasheet); prog_mem.v does that.

`default_nettype none

`ifdef COCOTB_SIM
module RM_IHPSG13_1P_64x16_c2 (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire [5:0]  A_ADDR,
    input  wire [15:0] A_DIN,
    input  wire        A_DLY,
    output reg  [15:0] A_DOUT
);
    reg [15:0] mem [0:63];
    integer i;
    initial begin
        for (i = 0; i < 64; i = i + 1) mem[i] = 16'd0;
        A_DOUT = 16'd0;
    end
    always @(posedge A_CLK) begin
        if (A_MEN && A_WEN) mem[A_ADDR] <= A_DIN;
        if (A_MEN && A_REN) A_DOUT <= mem[A_ADDR];
    end
    wire _tied = A_DLY;
endmodule
`else
(* blackbox *)
module RM_IHPSG13_1P_64x16_c2 (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire [5:0]  A_ADDR,
    input  wire [15:0] A_DIN,
    input  wire        A_DLY,
    output wire [15:0] A_DOUT
);
endmodule
`endif

`default_nettype wire
