// Manchester receiver (engine 0 only; private design 8 Nov 2026, docs/isa.md when built). Matches model/engine.py
// _rx_clock exactly; model/cosim.py compares them every clock.
//
// In 74-series terms: two samples of the receive pin per clock (the falling-edge one, from a latch outside the engine
// and two flip-flops here, then the rising-edge one from the engine's synchroniser), an edge detector, a 16-bit
// "half-clocks since the last taken edge" counter and two comparators (RXGAP for 3/4 of a bit, 2 x RXGAP for the end
// of the frame), a 6-bit preamble run counter, a 16-bit shift register with a 4-bit bit counter, a 7-bit word counter,
// and the direction flip-flop with its rules: a keyed change is taken only when idle, and empties the buffer.
//
// Each sample: an edge at least RXGAP half-clocks after the last taken edge is taken as a mid-bit edge (rising = 1,
// falling = 0); 2 x RXGAP half-clocks with none ends the frame. Hunting, a run of 16 alternating bits ended by "11"
// (the Ethernet SFD) locks; raw mode shifts from the first edge.

`timescale 1ns/1ps
`default_nettype none

module receiver (
    input  wire        clk,
    input  wire        rst_n,
    // settings
    input  wire        cfg_raw,         // RXCFG[5]
    input  wire        cfg_both,        // RXCFG[6]
    input  wire        cfg_in_right,    // the engine's in_right: LSB first
    input  wire [15:0] cfg_rxgap,       // RXGAP, half-clocks
    // the receive pin
    input  wire        rise_in,         // the pin at the rising edge of clk, before the chip's glitch filter
    input  wire        fall_in,         // the pin at the last falling edge of clk (latch outside the engine)
    // requests
    input  wire        mode_wr,         // keyed SERCFG write: change the mode to mode_val
    input  wire [1:0]  mode_val,        // 0 transmit, 1 receive, 2 full duplex
    input  wire        arm,             // RXCFG write with the arm bit
    input  wire        start_req,       // MOV ser this clock with the serialiser enabled
    input  wire        ser_busy,
    input  wire        buf_full,        // the buffer holds 64 words (start of the clock)
    // results
    output reg  [1:0]  mode,            // 0 transmit (reset), 1 receive, 2 full duplex
    output reg         refused,
    output reg         wr,              // write wdata into the buffer this clock
    output reg  [15:0] wdata,
    output wire        clear,           // an accepted change or an arm: the engine empties the buffer it concerns
    output reg         ready,           // a frame has ended
    output reg         over,
    output wire        locked,
    output reg  [3:0]  left,            // bits in a partial last word
    output reg  [6:0]  words,
    output wire        idle,
    output wire        accept          // a direction change taken this clock (it also stops the serialiser)
);
    localparam [1:0] IDLE = 2'd0, HUNT = 2'd1, DATA = 2'd2, DONE = 2'd3;
    localparam [5:0] LOCK_RUN = 6'd16;

    reg        f1, f2;                  // falling-edge sample, two rising-edge stages
    reg        r1, r2;                  // rising-edge sample (unfiltered), two stages to match
    reg        armed, lv, last;
    reg [1:0]  st;
    reg [15:0] gap, sh;
    reg [5:0]  run;
    reg [3:0]  bits;

    assign locked = (st == DATA);
    assign idle   = !ser_busy && !(st == HUNT || st == DATA);

    // ---- two samples, one after the other, combinationally (falling-edge one first)
    reg        n_lv, n_last, n_ready, n_over, s, is_edge, take, tb;
    reg [1:0]  n_st;
    reg [15:0] n_gap, n_sh, w;
    reg [5:0]  n_run;
    reg [3:0]  n_bits, n_left;
    reg [6:0]  n_words;
    integer    k;

    always @(*) begin
        n_lv = lv; n_last = last; n_ready = ready; n_over = over; n_st = st; n_gap = gap; n_sh = sh; n_run = run;
        n_bits = bits; n_left = left; n_words = words; wr = 1'b0; wdata = 16'd0;
        s = 1'b0; is_edge = 1'b0; take = 1'b0; tb = 1'b0; w = 16'd0;
        if (mode != 2'd0) begin                                    // receive or full duplex: the receiver listens
            for (k = 0; k < 2; k = k + 1) begin
                s = (k == 0) ? (cfg_both ? f2 : n_lv) : r2;
                is_edge = s ^ n_lv;
                n_lv = s;
                take = 1'b0;
                if (armed && n_st != DONE) begin
                    if (n_gap != 16'hFFFF) n_gap = n_gap + 16'd1;
                    if (n_st == IDLE) begin
                        if (is_edge) begin
                            n_st = cfg_raw ? DATA : HUNT;
                            take = 1'b1;
                        end
                    end else if (is_edge && n_gap >= cfg_rxgap) begin
                        take = 1'b1;
                    end else if ({1'b0, n_gap} >= {cfg_rxgap, 1'b0}) begin
                        // the end of the frame
                        if (n_st == HUNT) begin
                            n_st = IDLE; n_run = 6'd0;
                        end else begin
                            if (n_bits != 4'd0) begin
                                w = cfg_in_right ? (n_sh >> (5'd16 - {1'b0, n_bits})) : (n_sh & ((16'd1 << n_bits) - 16'd1));
                                n_left = n_bits; n_bits = 4'd0;
                                if (buf_full) n_over = 1'b1;
                                else begin wr = 1'b1; wdata = w; if (n_words != 7'd127) n_words = n_words + 7'd1; end
                            end
                            n_ready = 1'b1; n_st = DONE;
                        end
                    end
                    if (take) begin
                        tb = s;
                        n_gap = 16'd0;
                        if (n_st == HUNT) begin
                            if (n_run != 6'd0 && tb == n_last) begin
                                if (n_run >= LOCK_RUN && tb) n_st = DATA;
                                else begin n_run = 6'd1; n_last = tb; end
                            end else begin
                                if (n_run != 6'd63) n_run = n_run + 6'd1;
                                n_last = tb;
                            end
                        end else begin
                            n_sh = cfg_in_right ? {tb, n_sh[15:1]} : {n_sh[14:0], tb};
                            if (n_bits == 4'd15) begin
                                n_bits = 4'd0;
                                if (buf_full) n_over = 1'b1;
                                else begin wr = 1'b1; wdata = n_sh; if (n_words != 7'd127) n_words = n_words + 7'd1; end
                            end else n_bits = n_bits + 4'd1;
                        end
                    end
                end
            end
        end
    end

    // ---- the direction, the arm, the refusals (decided on the state at the start of the clock)
    assign accept = mode_wr && idle;
    wire do_arm = !mode_wr && arm && (mode != 2'd0);
    assign clear = accept || do_arm;

    always @(posedge clk) begin
        if (!rst_n) begin
            mode <= 2'd0; refused <= 1'b0; f1 <= 1'b0; f2 <= 1'b0; r1 <= 1'b0; r2 <= 1'b0; lv <= 1'b0;
            armed <= 1'b0; st <= IDLE; gap <= 16'd0; run <= 6'd0; last <= 1'b0; sh <= 16'd0; bits <= 4'd0;
            words <= 7'd0; left <= 4'd0; ready <= 1'b0; over <= 1'b0;
        end else begin
            f1 <= fall_in; f2 <= f1;
            r1 <= rise_in; r2 <= r1;
            lv <= n_lv;
            if (clear) begin
                armed <= do_arm; st <= IDLE; gap <= 16'd0; run <= 6'd0; last <= 1'b0; sh <= 16'd0; bits <= 4'd0;
                words <= 7'd0; left <= 4'd0; ready <= 1'b0; over <= 1'b0;
            end else begin
                st <= n_st; gap <= n_gap; run <= n_run; last <= n_last; sh <= n_sh; bits <= n_bits;
                words <= n_words; left <= n_left; ready <= n_ready; over <= n_over;
            end
            if (accept) mode <= mode_val;
            if (mode_wr) refused <= !idle;
            else if (do_arm) refused <= 1'b0;
            else if (start_req && mode == 2'd1) refused <= 1'b1;   // receive only: MOV ser refused
        end
    end
endmodule
