// IHP SRAM macro RM_IHPSG13_1P_1024x16_c2_bm_bist (engine 0's 1024-word buffer) as seen by the two builds of this repo.
//
// Simulation (cocotb RTL test and gate-level test, COCOTB_SIM defined): a behavioural array, one port, read data
// registered on A_CLK (appears the clock after the address); writes follow the bit mask A_BM (fifo_mem.v ties it to all
// ones) and, like IHP's model, also show the written word on A_DOUT. The test port (A_BIST_*) is tied off by fifo_mem.v.
// The real block's own model (IHP's RM_IHPSG13_1P_1024x16_c2_bm_bist.v with -DFUNCTIONAL) is what the design
// repository's cosim runs against the Python model; this file only has to agree with it for what fifo_mem.v uses.
//
// Synthesis and layout: an empty black box, so yosys keeps the instance and LibreLane places the macro from its LEF
// (src/config.json, MACROS). A_DLY must be tied 1 (IHP datasheet); fifo_mem.v does that.

`default_nettype none

`ifdef COCOTB_SIM
module RM_IHPSG13_1P_1024x16_c2_bm_bist (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire [9:0]  A_ADDR,
    input  wire [15:0] A_DIN,
    input  wire        A_DLY,
    output reg  [15:0] A_DOUT,
    input  wire [15:0] A_BM,
    input  wire        A_BIST_CLK,
    input  wire        A_BIST_EN,
    input  wire        A_BIST_MEN,
    input  wire        A_BIST_WEN,
    input  wire        A_BIST_REN,
    input  wire [9:0]  A_BIST_ADDR,
    input  wire [15:0] A_BIST_DIN,
    input  wire [15:0] A_BIST_BM
);
    reg [15:0] mem [0:1023];
    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1) mem[i] = 16'd0;
        A_DOUT = 16'd0;
    end
    always @(posedge A_CLK) begin
        if (A_MEN && A_WEN) begin
            mem[A_ADDR] <= (mem[A_ADDR] & ~A_BM) | (A_DIN & A_BM);
            A_DOUT      <= (mem[A_ADDR] & ~A_BM) | (A_DIN & A_BM);
        end else if (A_MEN && A_REN) A_DOUT <= mem[A_ADDR];
    end
    wire _tied = &{A_DLY, A_BIST_CLK, A_BIST_EN, A_BIST_MEN, A_BIST_WEN, A_BIST_REN, A_BIST_ADDR, A_BIST_DIN, A_BIST_BM, 1'b0};
endmodule
`else
(* blackbox *)
module RM_IHPSG13_1P_1024x16_c2_bm_bist (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire [9:0]  A_ADDR,
    input  wire [15:0] A_DIN,
    input  wire        A_DLY,
    output wire [15:0] A_DOUT,
    input  wire [15:0] A_BM,
    input  wire        A_BIST_CLK,
    input  wire        A_BIST_EN,
    input  wire        A_BIST_MEN,
    input  wire        A_BIST_WEN,
    input  wire        A_BIST_REN,
    input  wire [9:0]  A_BIST_ADDR,
    input  wire [15:0] A_BIST_DIN,
    input  wire [15:0] A_BIST_BM
);
endmodule
`endif

`default_nettype wire
