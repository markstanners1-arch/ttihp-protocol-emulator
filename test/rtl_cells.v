// RTL simulation only (test/Makefile, not GATES=yes): a behavioural model of the one IHP cell the wrapper instantiates
// by name, so the RTL test runs without the PDK. The gate-level test uses IHP's own cell models instead.
// sg13cmos5l_dlhq_1: D latch, open (Q follows D) while GATE is high, holding while it is low.
`default_nettype none
module sg13cmos5l_dlhq_1 (
    output reg  Q,
    input  wire D,
    input  wire GATE
);
    always @* if (GATE) Q = D;
endmodule
`default_nettype wire
