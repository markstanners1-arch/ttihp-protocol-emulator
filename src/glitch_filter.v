// Input glitch filter (docs/input_filter.md). WIDTH inputs, one shared prescaler and settings.
// A new level must hold for N+1 consecutive filter ticks (one tick every 2^P clocks) to get through.
// Inputs must already be synchronised to clk.

`timescale 1ns/1ps
`default_nettype none

module glitch_filter #(parameter WIDTH = 1) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [3:0]       p,          // prescale: a filter tick every 2^p clocks
    input  wire [3:0]       n,          // length: hold for n+1 ticks
    input  wire [WIDTH-1:0] in,
    output reg  [WIDTH-1:0] out
);
    reg  [14:0] pre;
    wire [14:0] mask = (15'd1 << p) - 15'd1;
    wire        tick = ((pre & mask) == mask);

    reg [3:0] cnt [0:WIDTH-1];

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            pre <= 15'd0;
            out <= {WIDTH{1'b0}};
            for (i = 0; i < WIDTH; i = i + 1) cnt[i] <= 4'd0;
        end else begin
            pre <= pre + 15'd1;
            for (i = 0; i < WIDTH; i = i + 1) begin
                if (in[i] == out[i]) begin
                    cnt[i] <= 4'd0;
                end else if (tick) begin
                    if (cnt[i] == n) begin
                        out[i] <= in[i];
                        cnt[i] <= 4'd0;
                    end else begin
                        cnt[i] <= cnt[i] + 4'd1;
                    end
                end
            end
        end
    end
endmodule
