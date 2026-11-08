// Bit-cell serialiser (engine 0 only; docs/isa.md v0.3, "Serialiser"). Matches model/engine.py _ser_clock exactly.
//
// In 74-series terms: a 16-bit shift register loaded from the engine's TX FIFO, a half-bit divider (a down-counter that
// reloads from SERDIV), a half-bit flip-flop, a 5-bit bit counter, a 16-bit word counter, a 3-bit skip counter for the
// CRC, and an encoder mux (NRZ, or Manchester: first half the inverse of the bit, second half the bit). It is started by
// MOV ser (start, start_count words; 0 stops it), waits until the FIFO holds the whole count (or is full), pulls the
// words itself one per 16 bit-times, then optionally the CRC register (32 bits, optionally complemented, same bit order)
// and the end marker (the line high for 6 half-bits), then goes idle. If the FIFO has no head word ready when the next word is due the
// line goes idle at once and `under` is set until the next start. While `own` is high the engine puts `line` on
// out_base (and its inverse on out_base + 1 in differential mode) instead of the program's level.
//
// Timing: each half-bit is serdiv + 1 clocks. FIFO decisions use the state at the start of the clock (tx_cnt, tx_full,
// tx_ready).

`timescale 1ns/1ps
`default_nettype none

module serialiser (
    input  wire        clk,
    input  wire        rst_n,
    // settings (SERCFG bits, SERDIV, and the engine's out_right)
    input  wire        cfg_en,
    input  wire        cfg_manch,
    input  wire        cfg_endm,
    input  wire        cfg_crcap,
    input  wire        cfg_crccpl,
    input  wire [2:0]  cfg_skip,
    input  wire        cfg_pre,         // SERCFG[9]: hardware preamble (seven 0x55 and the SFD, LSB first)
    input  wire [15:0] cfg_serdiv,
    input  wire        cfg_out_right,
    // from the engine: MOV ser this clock
    input  wire        start,
    input  wire [15:0] start_count,
    // the TX FIFO
    input  wire [6:0]  tx_cnt,
    input  wire        tx_full,
    input  wire        tx_ready,      // the head word is ready (engine 0: see docs/isa.md, Host and FIFO timing)
    input  wire [15:0] tx_head,
    output reg         tx_pop,
    // the CRC unit
    input  wire [31:0] crc,
    output reg         crc_clr,
    output reg         crc_step,
    output reg         crc_bit,
    // state
    output reg         busy,
    output reg         under,
    output wire        own,
    output wire        line
);
    localparam [1:0] FILL = 2'd0, DATA = 2'd1, CRC = 2'd2, END = 2'd3;
    localparam [4:0] END_HALF_BITS = 5'd6;

    reg [1:0]  phase;
    reg [15:0] words, sh, divc;
    reg [4:0]  bitn;
    reg        half, wskip;
    reg [2:0]  skip;
    reg [6:0]  pre;                     // preamble bits still to send before the first word's bits

    // next state
    reg [1:0]  n_phase;
    reg [15:0] n_words, n_sh, n_divc;
    reg [4:0]  n_bitn;
    reg        n_half, n_wskip, n_busy, n_under;
    reg [2:0]  n_skip;
    reg [6:0]  n_pre;
    reg        first;
    reg        do_load;

    wire        cur_bit  = cfg_out_right ? sh[0] : sh[15];
    wire        next_bit = cfg_out_right ? sh[1] : sh[14];
    wire [15:0] next_sh  = cfg_out_right ? {1'b0, sh[15:1]} : {sh[14:0], 1'b0};
    wire        load_bit = cfg_out_right ? tx_head[0] : tx_head[15];

    always @(*) begin
        n_phase = phase; n_words = words; n_sh = sh; n_divc = divc; n_bitn = bitn;
        n_half = half; n_wskip = wskip; n_busy = busy; n_under = under; n_skip = skip; n_pre = pre; first = 1'b0;
        tx_pop = 1'b0; crc_clr = 1'b0; crc_step = 1'b0; crc_bit = 1'b0; do_load = 1'b0;
        if (cfg_en) begin
            if (start) begin                                        // MOV ser: restart with the new count; 0 stops
                if (start_count == 16'd0) begin
                    n_busy = 1'b0; n_phase = FILL;
                end else begin
                    n_busy = 1'b1; n_under = 1'b0; n_phase = FILL;
                    n_words = start_count; n_skip = cfg_skip; crc_clr = 1'b1;
                end
            end else if (busy) begin
                if (phase == FILL) begin                            // waiting for the whole frame to be in the FIFO
                    if (({9'd0, tx_cnt} >= words || tx_full) && tx_ready) begin do_load = 1'b1; first = 1'b1; end
                end else if (divc != 16'd0) begin                   // inside a half-bit
                    n_divc = divc - 16'd1;
                end else begin                                      // a half-bit boundary
                    n_divc = cfg_serdiv;
                    if (phase == END) begin
                        if (bitn < END_HALF_BITS - 5'd1) n_bitn = bitn + 5'd1;
                        else n_busy = 1'b0;
                    end else if (!half) begin
                        n_half = 1'b1;
                    end else begin                                  // a bit boundary
                        n_half = 1'b0;
                        if (phase == DATA && pre != 7'd0) begin    // a preamble bit has ended
                            n_pre = pre - 7'd1;
                            if (pre == 7'd1) begin crc_step = !wskip; crc_bit = cur_bit; end   // the first word's first bit
                        end else if (phase == DATA) begin
                            if (bitn < 5'd15) begin
                                n_bitn = bitn + 5'd1; n_sh = next_sh;
                                crc_step = !wskip; crc_bit = next_bit;
                            end else if (words != 16'd0) begin      // the word is done: the next one
                                if (tx_ready) do_load = 1'b1;
                                else begin n_busy = 1'b0; n_under = 1'b1; end
                            end else if (cfg_crcap) begin
                                n_phase = CRC; n_bitn = 5'd0;
                            end else if (cfg_endm) begin
                                n_phase = END; n_bitn = 5'd0;
                            end else n_busy = 1'b0;
                        end else begin                              // CRC phase
                            if (bitn < 5'd31) n_bitn = bitn + 5'd1;
                            else if (cfg_endm) begin n_phase = END; n_bitn = 5'd0; end
                            else n_busy = 1'b0;
                        end
                    end
                end
                if (do_load) begin                                  // pull the next word, start its first bit
                    tx_pop = 1'b1; n_sh = tx_head; n_words = words - 16'd1;
                    n_bitn = 5'd0; n_half = 1'b0; n_divc = cfg_serdiv; n_phase = DATA;
                    n_wskip = (skip != 3'd0);
                    if (skip != 3'd0) n_skip = skip - 3'd1;
                    crc_step = (skip == 3'd0) && !(first && cfg_pre); crc_bit = load_bit;
                    if (first) n_pre = cfg_pre ? 7'd64 : 7'd0;    // set afresh for every frame
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0; under <= 1'b0; phase <= FILL; words <= 16'd0; sh <= 16'd0; divc <= 16'd0;
            bitn <= 5'd0; half <= 1'b0; wskip <= 1'b0; skip <= 3'd0; pre <= 7'd0;
        end else begin
            busy <= n_busy; under <= n_under; phase <= n_phase; words <= n_words; sh <= n_sh; divc <= n_divc;
            bitn <= n_bitn; half <= n_half; wskip <= n_wskip; skip <= n_skip; pre <= n_pre;
        end
    end

    // the encoded level
    wire [4:0] crc_idx = cfg_out_right ? bitn : 5'd31 - bitn;
    wire       crc_b   = crc[crc_idx] ^ cfg_crccpl;
    wire       pre_bit = (pre == 7'd1) || !pre[0];                     // 1 0 1 0 ... 1 1
    wire       raw     = (phase == DATA) ? ((pre != 7'd0) ? pre_bit : cur_bit) : crc_b;
    assign line = (phase == END) ? 1'b1 : (cfg_manch ? (half ? raw : ~raw) : raw);
    assign own  = busy && (phase != FILL);
endmodule
