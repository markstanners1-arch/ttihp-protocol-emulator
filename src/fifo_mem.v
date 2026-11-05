// TX FIFO memory for engine 0: 64 x 16, one port, reads on the clock (like an SRAM).
//
// Default: built from flip-flops, behaving exactly like IHP's SRAM block. With +define+USE_SRAM it is the real IHP
// block RM_IHPSG13_1P_64x16_c2. Both are checked against the model (model/cosim.py, USE_SRAM=1 for the block).
//
// Each clock: if we, write wdata at addr (read output held); else if re, the word at addr appears on rdata just after
// the clock edge. The FIFO control around it is in src/engine.v (TXDEPTH = 64).

`timescale 1ns/1ps
`default_nettype none

module fifo_mem (
    input  wire        clk,
    input  wire        we,
    input  wire        re,
    input  wire [5:0]  addr,
    input  wire [15:0] wdata,
    output wire [15:0] rdata
);

`ifdef USE_SRAM
    RM_IHPSG13_1P_64x16_c2 sram (
        .A_CLK(clk),
        .A_MEN(1'b1),
        .A_WEN(we),
        .A_REN(re & ~we),
        .A_ADDR(addr),
        .A_DIN(wdata),
        .A_DLY(1'b1),          // must be tied high (IHP)
        .A_DOUT(rdata)
    );
`else
    reg [15:0] mem [0:63];
    reg [15:0] q;
    always @(posedge clk) begin
        if (we)      mem[addr] <= wdata;
        else if (re) q <= mem[addr];
    end
    assign rdata = q;
`endif

endmodule
