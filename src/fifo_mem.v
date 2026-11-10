// TX FIFO memory for engine 0: DEPTH x 16 (64, or 1024 on the Tiny Tapeout chip), one port, reads on the clock
// (like an SRAM).
//
// Default: built from flip-flops (block RAM on the FPGAs), behaving exactly like IHP's SRAM block. With +define+USE_SRAM
// it is the real IHP block: RM_IHPSG13_1P_64x16_c2, or RM_IHPSG13_1P_1024x16_c2_bm_bist (write mask all ones, its test
// port unused). Both are checked against the model (model/cosim.py, USE_SRAM=1 for the blocks).
//
// Each clock: if we, write wdata at addr (read output held); else if re, the word at addr appears on rdata just after
// the clock edge. The FIFO control around it is in src/engine.v (TXDEPTH = 64 or 1024).

`timescale 1ns/1ps
`default_nettype none

module fifo_mem #(
    parameter DEPTH = 64,                // 64 or 1024
    parameter AW    = (DEPTH == 1024) ? 10 : 6
) (
    input  wire          clk,
    input  wire          we,
    input  wire          re,
    input  wire [AW-1:0] addr,
    input  wire [15:0]   wdata,
    output wire [15:0]   rdata
);

`ifdef USE_SRAM
    generate if (DEPTH == 1024) begin : ram1k
        RM_IHPSG13_1P_1024x16_c2_bm_bist sram (
            .A_CLK(clk),
            .A_MEN(1'b1),
            .A_WEN(we),
            .A_REN(re & ~we),
            .A_ADDR(addr),
            .A_DIN(wdata),
            .A_DLY(1'b1),          // must be tied high (IHP)
            .A_DOUT(rdata),
            .A_BM(16'hFFFF),       // write every bit
            .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
            .A_BIST_ADDR(10'd0), .A_BIST_DIN(16'd0), .A_BIST_BM(16'd0)
        );
    end else begin : ram64
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
    end endgenerate
`else
    reg [15:0] mem [0:DEPTH-1];
    reg [15:0] q;
    always @(posedge clk) begin
        if (we)      mem[addr] <= wdata;
        else if (re) q <= mem[addr];
    end
    assign rdata = q;
`endif

endmodule
