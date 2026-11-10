// One protocol engine, built from docs/isa.md (v0.3).
// Checked against the Python model (model/engine.py) every system clock by model/cosim.py.
//
// In 74-series terms: a 16-bit clock divider, a 5-bit program counter, two 16-bit
// loadable down-counters (X, Y), two 16-bit shift registers (OSR out, ISR in) with bit counters,
// a 5-bit delay counter, a 16-bit stopwatch, a TX FIFO (TXDEPTH words; at 64 or 1024 a one-port
// memory, src/fifo_mem.v, behind a head register) and a 4-word RX FIFO, a 2-flip-flop
// synchroniser on every input, a 32 x 16 program memory, a 32-bit CRC unit (src/crc32.v), and with SER = 1 the
// bit-cell serialiser (src/serialiser.v) that owns out_base while it sends. One instruction per engine tick.

`timescale 1ns/1ps
`default_nettype none

module engine #(
    parameter SER     = 0,              // 1: this engine has the serialiser (engine 0)
    parameter TXDEPTH = 4,              // TX FIFO depth, a power of two (with the serialiser 64, or 1024 on the ASIC)
    parameter CRC     = 1               // 1: the CRC unit is built; 0: crc reads 0 (IN source 7 reads zeros, TIME 5 does nothing)
) (
    input  wire        clk,
    input  wire        rst_n,

    // configuration (set by the host, held steady while running)
    input  wire [15:0] cfg_clkdiv,
    input  wire [4:0]  cfg_start,
    input  wire [4:0]  cfg_wrap_bottom,
    input  wire [4:0]  cfg_wrap_top,
    input  wire [4:0]  cfg_out_base,
    input  wire [4:0]  cfg_out_count,     // 0-16
    input  wire [4:0]  cfg_set_base,
    input  wire [2:0]  cfg_set_count,     // 0-5
    input  wire [4:0]  cfg_side_base,
    input  wire [1:0]  cfg_side_count,    // 0-2
    input  wire        cfg_side_opt,
    input  wire        cfg_side_dir,      // side-set writes pin directions, not levels
    input  wire [4:0]  cfg_in_base,
    input  wire [4:0]  cfg_jmp_pin,
    input  wire        cfg_out_right,
    input  wire        cfg_in_right,
    input  wire [4:0]  cfg_fault_addr,
    input  wire [12:0] cfg_sercfg,        // SERCFG: [0] en, [1] Manchester, [2] differential, [3] end marker, [4] CRC append,
                                          //         [5] complement, [6] CRC watches SER, [12:10] CRC skip words (SER = 1 only)
    input  wire [15:0] cfg_serdiv,        // half-bit period minus 1 (SER = 1 only)
    input  wire [31:0] cfg_crcpoly,
    input  wire [31:0] cfg_crcinit,

    // program memory write port
    input  wire        imem_we,
    input  wire [4:0]  imem_addr,
    input  wire [15:0] imem_wdata,

    // host side of the FIFOs
    input  wire        host_push,
    input  wire [15:0] host_push_data,
    input  wire        host_pop,
    output wire [15:0] host_pop_data,     // head of the RX FIFO
    output wire [10:0] tx_level,
    output wire [2:0]  rx_level,

    // pins
    input  wire [31:0] pins_in,
    output wire [31:0] out_val,           // the levels on the pins (the serialiser's on its pins while it sends)
    output reg  [31:0] out_dir,

    // serialiser and CRC unit, for the host registers
    output wire        ser_busy,
    output wire        ser_under,
    output wire [31:0] crc,

    // receiver (SER = 1 only): settings, the falling-edge sample of the receive pin, the host's requests, the status
    input  wire [4:0]  cfg_rx_pin,        // RXCFG[4:0]
    input  wire        cfg_rx_raw,        // RXCFG[5]
    input  wire        cfg_rx_both,       // RXCFG[6]
    input  wire [15:0] cfg_rxgap,
    input  wire        rx_fall,           // the receive pin at the last falling edge of clk (a latch outside)
    input  wire        rx_rise,           // the receive pin at the rising edge, before the chip's glitch filter
    input  wire        mode_wr,           // keyed SERCFG write: mode = mode_val
    input  wire [1:0]  mode_val,          // 0 transmit, 1 receive, 2 full duplex
    input  wire        rx_arm,            // RXCFG write with the arm bit
    input  wire        host_bpop,         // host read of a received word (0x26 in receive mode, 0x37 in either)
    output wire [15:0] host_bpop_data,    // the buffer's head word
    output wire        buf_ready,         // ... and it is valid (a buffer read takes it this clock)
    output wire [1:0]  mode,              // engine 0's mode (0 transmit, 1 receive, 2 full duplex)
    output wire [10:0] rb_level,          // full duplex: words in the receive ring (for testing)
    output wire [10:0] rx_words,          // words received this frame, unsaturated (host register 0x39)
    output wire        rx_held,           // full duplex: a received word waits for the memory port (for testing)
    output wire        rx_ready,
    output wire [15:0] rxstat,

    // engine state, visible for testing
    output reg  [4:0]  pc,
    output reg  [15:0] x,
    output reg  [15:0] y,
    output reg  [15:0] osr,
    output reg  [4:0]  osr_count,
    output reg  [15:0] isr,
    output reg  [4:0]  isr_count,
    output reg  [4:0]  delay,
    output reg  [15:0] sw,
    output reg         sw_run
);

    // ------------------------------------------------------------------ helpers
    function [31:0] rotl32(input [31:0] v, input [4:0] s);
        rotl32 = (v << s) | (v >> (6'd32 - {1'b0, s}));
    endfunction

    function [31:0] rotr32(input [31:0] v, input [4:0] s);
        rotr32 = (v >> s) | (v << (6'd32 - {1'b0, s}));
    endfunction

    // write `count` bits of `data` into `r`, starting at pin `base` (wrapping at 32)
    function [31:0] wr_bits(input [31:0] r, input [4:0] base, input [4:0] count, input [15:0] data);
        reg [31:0] m;
        begin
            m = rotl32((32'd1 << count) - 32'd1, base);
            wr_bits = (r & ~m) | (rotl32({16'd0, data}, base) & m);
        end
    endfunction

    function [15:0] bitrev16(input [15:0] v);
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1) bitrev16[i] = v[15 - i];
        end
    endfunction

    // ------------------------------------------------------------------ storage
    // Program memory reads on the clock (SRAM-style, see docs/isa.md): every clock it is given the
    // address of the instruction needed next (n_pc), so that word is ready for the next step.
    // While in reset it reads `start`. Programs are written only while the engine is held in reset.
    wire [15:0] imem_rdata;
    reg  [4:0]  n_pc;          // next program counter (from the logic below)
    wire [4:0]  imem_raddr = !rst_n ? cfg_start : n_pc;
    prog_mem imem (
        .clk(clk), .we(imem_we), .re(1'b1),
        .addr(imem_we ? imem_addr : imem_raddr),
        .wdata(imem_wdata), .rdata(imem_rdata));

    reg [31:0] sync1, sync2;        // 2 flip-flop synchroniser
    reg [15:0] div;                 // clock divider
    wire       tick = (div == 16'd0);

    // TX FIFO address width = clog2(TXDEPTH), written out because Xilinx XST 14.7 rejects $clog2 in a localparam
    localparam TAW = (TXDEPTH <= 2) ? 1 : (TXDEPTH <= 4) ? 2 : (TXDEPTH <= 8) ? 3 : (TXDEPTH <= 16) ? 4 :
                     (TXDEPTH <= 32) ? 5 : (TXDEPTH <= 64) ? 6 : (TXDEPTH <= 128) ? 7 : (TXDEPTH <= 256) ? 8 :
                     (TXDEPTH <= 512) ? 9 : 10;
    // Full duplex: the buffer as two rings, FT transmit words then FR receive words (16 + 48 of 64; 512 + 512 of 1024).
    // FTW = log2(FT): the transmit ring's pointers wrap in FTW bits.
    localparam FT  = (TXDEPTH == 64) ? 16 : TXDEPTH / 2;
    localparam FR  = TXDEPTH - FT;
    localparam FTW = (FT <= 2) ? 1 : (FT <= 4) ? 2 : (FT <= 8) ? 3 : (FT <= 16) ? 4 : (FT <= 32) ? 5 : (FT <= 64) ? 6 :
                     (FT <= 128) ? 7 : (FT <= 256) ? 8 : 9;
    localparam FRL = FR - 1;
    localparam RXW = 2 * TXDEPTH - 1;           // the receiver's word count saturates here
    localparam [10:0]    FT_N  = FT;
    localparam [10:0]    FR_N  = FR;
    localparam [10:0]    FRL_N = FRL;
    localparam [10:0]    TXD_N = TXDEPTH;
    localparam [10:0]    RXW_N = RXW;
    localparam [TAW-1:0] FT_A  = FT_N[TAW-1:0];   // the receive ring's first memory word
    localparam [TAW-1:0] FR_L  = FRL_N[TAW-1:0];  // ... and its last offset
    // TX FIFO: host -> engine (and the serialiser). tx_cnt counts every word in it; tx_head is the word PULL and the
    // serialiser take, valid while tx_ready (docs/isa.md, "Host and FIFO timing").
    reg [TAW-1:0] tx_rd, tx_wr;
    reg [10:0]    tx_cnt;          // 11 bits whatever the depth (the host's SERLEVEL)
    wire [15:0] tx_head;
    wire        tx_ready;
    reg [15:0] rxm [0:3];           // RX FIFO: engine -> host
    reg [1:0]  rx_rd, rx_wr;
    reg [2:0]  rx_cnt;
    reg [31:0] oval;                // the program's pin levels (OUT, SET, MOV pins, side-set)
    reg        tx_pop_eng;          // PULL takes the head this clock (from the logic below)
    wire       ser_pop;             // the serialiser takes the head this clock

    wire   rx_only       = (mode == 2'd1);  // receive: the program and the host are kept out of the buffer
    wire   fdx           = (mode == 2'd2);  // full duplex: the buffer is two rings, FT transmit + FR receive
    wire   tx_full       = fdx ? (tx_cnt == FT_N) : (tx_cnt == TXD_N);
    assign tx_level      = tx_cnt;
    assign rx_level      = rx_cnt;
    assign host_pop_data = rxm[rx_rd];
    wire   host_push_ok  = host_push && !tx_full && !rx_only;      // the host cannot fill the buffer in receive mode
    wire   host_pop_ok   = host_pop  && (rx_cnt != 3'd0);
    wire   bpop_ok       = host_bpop && rx_only && tx_ready;       // receive: the host reads a received word
    wire   tx_pop        = tx_pop_eng | ser_pop | bpop_ok;
    wire        rb_ready;               // full duplex: the receive ring's head word is valid
    wire [15:0] rb_head;
    wire        rb_pop  = host_bpop && fdx && rb_ready;            // full duplex: the host reads a received word
    wire        rcv_wr;                 // the receiver writes a word (receive: into the buffer; full duplex: the hold)
    wire [15:0] rcv_wdata;
    wire        rcv_accept;             // a mode change taken this clock
    wire        rcv_clear;              // an accepted mode change or an arm
    wire        rcv_full;               // the receiver's word would not fit
    assign host_bpop_data = fdx ? rb_head : tx_head;
    assign buf_ready      = fdx ? rb_ready : tx_ready;

    generate if (TXDEPTH >= 64) begin : tx_mem
        // One-port memory (src/fifo_mem.v: flip-flops, or the IHP block with USE_SRAM) behind a head register.
        // A host push writes the memory. On a clock with no push, if the head is empty or taken this clock and the
        // memory holds a word not yet read, that word is read: it is the head from the next clock. tx_hv = head valid.
        // The head is captured into hold on the clock after a read, so it never relies on the memory output holding.
        // Full duplex (fdx): two rings in the one memory, words 0 to FT-1 transmit and FT up receive, each with its own
        // pointers, count and head register; a received word waits in a one-word hold until the port is free. The port's
        // turns: the host's push, then the held word, then the transmit head's refill, then the receive head's refill.
        reg         tx_hv, rd_last;
        reg  [15:0] hold;
        reg  [TAW-1:0] rb_rd, rb_wr;        // receive ring: offsets 0 to FR-1 (memory words FT up)
        reg  [10:0]    rb_cnt;              // ... and its count
        reg         rb_hv, rbd_last;
        reg  [15:0] rbhold;
        reg         hw_v;                   // the hold register: a received word waiting for the port
        reg  [15:0] hw_d;
        wire [15:0] mq;
        wire [10:0] unread   = tx_cnt - {10'd0, tx_hv};
        wire [10:0] unread_r = rb_cnt - {10'd0, rb_hv};
        wire        hold_free = fdx && hw_v && !host_push_ok;
        wire        busy_f    = host_push_ok || hold_free;
        wire        want_t    = (!tx_hv || tx_pop) && (unread != 11'd0);
        wire        want_r    = (!rb_hv || rb_pop) && (unread_r != 11'd0);
        wire        wt = rst_n && (host_push_ok || (!fdx && rcv_wr));   // a write into the transmit ring (or the one buffer)
        wire        we = fdx ? (rst_n && busy_f) : wt;
        wire        re_t = rst_n && (fdx ? (!busy_f && want_t) : (!we && want_t));
        wire        re_r = rst_n && fdx && !busy_f && !want_t && want_r;
        wire [TAW-1:0] tx_wr_a = fdx ? {{(TAW-FTW){1'b0}}, tx_wr[FTW-1:0]} : tx_wr;
        wire [TAW-1:0] tx_rd_a = fdx ? {{(TAW-FTW){1'b0}}, tx_rd[FTW-1:0]} : tx_rd;
        wire [TAW-1:0] addr = host_push_ok ? tx_wr_a : hold_free ? (FT_A + rb_wr) : (!fdx && rcv_wr) ? tx_wr_a :
                              re_t ? tx_rd_a : (FT_A + rb_rd);
        fifo_mem #(.DEPTH(TXDEPTH)) txmem (.clk(clk), .we(we), .re(re_t || re_r), .addr(addr),
                        .wdata(host_push_ok ? host_push_data : fdx ? hw_d : rcv_wdata), .rdata(mq));
        assign tx_head  = rd_last ? mq : hold;
        assign tx_ready = tx_hv;
        assign rb_head  = rbd_last ? mq : rbhold;
        assign rb_ready = rb_hv;
        assign rb_level = rb_cnt;
        assign rx_held  = hw_v;
        assign rcv_full = fdx ? ((rb_cnt + {10'd0, hw_v} >= FR_N) || (hw_v && !hold_free)) : tx_full;
        wire   arm_only = rcv_clear && !rcv_accept;
        always @(posedge clk) begin
            if (!rst_n || rcv_accept || (arm_only && rx_only)) begin
                tx_rd <= 0; tx_wr <= 0; tx_cnt <= 0; tx_hv <= 1'b0; rd_last <= 1'b0;
            end else begin
                if (wt) tx_wr <= fdx ? {{(TAW-FTW){1'b0}}, tx_wr[FTW-1:0] + 1'b1} : tx_wr + 1'b1;
                if (re_t) tx_rd <= fdx ? {{(TAW-FTW){1'b0}}, tx_rd[FTW-1:0] + 1'b1} : tx_rd + 1'b1;
                tx_cnt  <= tx_cnt + {10'd0, wt} - {10'd0, tx_pop};
                tx_hv   <= re_t ? 1'b1 : (tx_pop ? 1'b0 : tx_hv);
                rd_last <= re_t;
            end
            if (rd_last) hold <= mq;
            if (!rst_n || rcv_accept || (arm_only && fdx)) begin
                rb_rd <= {TAW{1'b0}}; rb_wr <= {TAW{1'b0}}; rb_cnt <= 11'd0; rb_hv <= 1'b0; rbd_last <= 1'b0; hw_v <= 1'b0;
            end else begin
                if (hold_free) rb_wr <= (rb_wr == FR_L) ? {TAW{1'b0}} : rb_wr + 1'b1;
                if (re_r) rb_rd <= (rb_rd == FR_L) ? {TAW{1'b0}} : rb_rd + 1'b1;
                rb_cnt   <= rb_cnt + {10'd0, hold_free} - {10'd0, rb_pop};
                rb_hv    <= re_r ? 1'b1 : (rb_pop ? 1'b0 : rb_hv);
                rbd_last <= re_r;
                hw_v     <= (fdx && rcv_wr) ? 1'b1 : (hold_free ? 1'b0 : hw_v);
            end
            if (fdx && rcv_wr) hw_d <= rcv_wdata;
            if (rbd_last) rbhold <= mq;
        end
    end else begin : tx_ff
        // Flip-flop FIFO: a pushed word is visible from the next clock.
        reg [15:0] txm [0:TXDEPTH-1];
        assign rb_head = 16'd0; assign rb_ready = 1'b0; assign rb_level = 11'd0; assign rx_held = 1'b0;
        assign rcv_full = tx_full;
        assign tx_head  = txm[tx_rd];
        assign tx_ready = (tx_cnt != 11'd0);
        always @(posedge clk) begin
            if (!rst_n) begin
                tx_rd <= 0; tx_wr <= 0; tx_cnt <= 0;
            end else begin
                if (host_push_ok) begin txm[tx_wr] <= host_push_data; tx_wr <= tx_wr + 1'b1; end
                if (tx_pop) tx_rd <= tx_rd + 1'b1;
                tx_cnt <= tx_cnt + {10'd0, host_push_ok} - {10'd0, tx_pop};
            end
        end
    end endgenerate
    wire [3:0] tx_sat4   = (tx_level > 11'd15) ? 4'd15 : tx_level[3:0];   // MOV status: the level, saturating at 15

    // ---- the serialiser (SER = 1) and the CRC unit
    reg         ser_start;          // MOV ser this clock
    reg  [15:0] ser_count;
    reg         crc_clr_time;       // TIME 5 this clock
    reg         in_step;            // an IN this clock: the CRC unit (IN mode) takes its first bit
    reg         in_bit;
    wire        ser_crc_clr, ser_crc_step, ser_crc_bit, ser_own, ser_line;
    wire        crc_ser_mode = SER ? cfg_sercfg[6] : 1'b0;
    generate if (SER) begin : with_ser
        serialiser u_ser (
            .clk(clk), .rst_n(rst_n),
            .cfg_en(cfg_sercfg[0]), .cfg_manch(cfg_sercfg[1]), .cfg_endm(cfg_sercfg[3]), .cfg_crcap(cfg_sercfg[4]),
            .cfg_crccpl(cfg_sercfg[5]), .cfg_skip(cfg_sercfg[12:10]), .cfg_pre(cfg_sercfg[9]), .cfg_serdiv(cfg_serdiv), .cfg_out_right(cfg_out_right),
            .start(rcv_accept || (ser_start && !rx_only)),             // receive mode: MOV ser refused; a mode
            .start_count(rcv_accept ? 16'd0 : ser_count),              // change stops the serialiser (count 0)
            .tx_cnt(tx_level), .tx_full(tx_full), .tx_ready(tx_ready), .tx_head(tx_head), .tx_pop(ser_pop),
            .crc(crc), .crc_clr(ser_crc_clr), .crc_step(ser_crc_step), .crc_bit(ser_crc_bit),
            .busy(ser_busy), .under(ser_under), .own(ser_own), .line(ser_line));
        // the serialiser's pins: out_base, and out_base + 1 with the inverse in differential mode
        wire [31:0] m0 = 32'd1 << cfg_out_base;
        wire [31:0] m1 = 32'd1 << (cfg_out_base + 5'd1);
        wire [31:0] with0 = (oval & ~m0) | (ser_line ? m0 : 32'd0);
        wire [31:0] with1 = cfg_sercfg[2] ? ((with0 & ~m1) | (ser_line ? 32'd0 : m1)) : with0;
        assign out_val = ser_own ? with1 : oval;
    end else begin : no_ser
        assign ser_pop = 1'b0; assign ser_crc_clr = 1'b0; assign ser_crc_step = 1'b0; assign ser_crc_bit = 1'b0;
        assign ser_own = 1'b0; assign ser_line = 1'b0; assign ser_busy = 1'b0; assign ser_under = 1'b0;
        assign out_val = oval;
        wire _unused_ser = &{ser_start, ser_count, cfg_sercfg, cfg_serdiv, 1'b0};
    end endgenerate
    generate if (CRC) begin : with_crc
        crc32 u_crc (
            .clk(clk), .rst_n(rst_n), .poly(cfg_crcpoly), .init(cfg_crcinit),
            .clr(crc_clr_time | ser_crc_clr),
            .step(crc_ser_mode ? ser_crc_step : in_step), .bit_in(crc_ser_mode ? ser_crc_bit : in_bit),
            .crc(crc));
    end else begin : no_crc
        assign crc = 32'd0;
        wire _unused_crc = &{cfg_crcpoly, cfg_crcinit, crc_clr_time, ser_crc_clr, crc_ser_mode, ser_crc_step, in_step,
                             ser_crc_bit, in_bit, 1'b0};
    end endgenerate
    // ---- the receiver (engine 0, with the 64- or 1024-word buffer)
    generate if (SER && TXDEPTH >= 64) begin : with_rx
        wire        r_over, r_locked, r_refused, r_idle;
        wire [3:0]  r_left;
        wire [10:0] r_words;
        receiver #(.WMAX(RXW_N)) u_rx (
            .clk(clk), .rst_n(rst_n),
            .cfg_raw(cfg_rx_raw), .cfg_both(cfg_rx_both), .cfg_in_right(cfg_in_right), .cfg_rxgap(cfg_rxgap),
            .rise_in(rx_rise), .fall_in(rx_fall),
            .mode_wr(mode_wr), .mode_val(mode_val), .arm(rx_arm), .start_req(ser_start && cfg_sercfg[0]),
            .ser_busy(ser_busy), .buf_full(rcv_full),
            .mode(mode), .refused(r_refused), .wr(rcv_wr), .wdata(rcv_wdata), .clear(rcv_clear),
            .ready(rx_ready), .over(r_over), .locked(r_locked), .left(r_left), .words(r_words), .idle(r_idle),
            .accept(rcv_accept));
        assign rxstat = {mode != 2'd0, (r_words > 11'd127) ? 7'd127 : r_words[6:0], r_left, r_refused, r_locked, r_over,
                         rx_ready};                               // the word count saturating at 127 (exact: rx_words)
        assign rx_words = r_words;
        wire _unused_rx = &{r_idle, 1'b0};
    end else begin : no_rx
        assign mode = 2'd0; assign rx_ready = 1'b0; assign rxstat = 16'd0; assign rx_words = 11'd0;
        assign rcv_wr = 1'b0; assign rcv_wdata = 16'd0; assign rcv_clear = 1'b0; assign rcv_accept = 1'b0;
        wire _unused_rx = &{cfg_rx_pin, cfg_rx_raw, cfg_rx_both, cfg_rxgap, rx_fall, rx_rise, mode_wr, mode_val, rx_arm, 1'b0};
    end endgenerate
    // what WAIT sees: the pins, except index 24 on the serialiser's engine = busy, 25 = a received frame is ready
    wire [31:0] wait_src = SER ? {sync2[31:26], rx_ready, ser_busy, sync2[23:0]} : sync2;

    // ------------------------------------------------------------------ working values for one step
    // (combinational: every one is assigned at the top of the always @(*) block)
    reg [15:0] instr;
    reg [2:0]  op;
    reg [4:0]  mid;
    reg [7:0]  a;
    reg [2:0]  dbits;
    reg [4:0]  dly, sval_full, pidx;
    reg        sen, stall, do_jump, take;
    reg [4:0]  jaddr, n;
    reg [5:0]  sum6;
    reg [15:0] data, v, msk;
    reg [16:0] m17;
    reg [31:0] t32;
    // shared hardware: one pin reader, one shifter, one pin writer (one instruction per step)
    reg [15:0] pins_rd;             // 16 pins from in_base
    reg [15:0] in_data;             // IN source, masked to n bits
    reg [31:0] sh_in, sh_out;       // the one 32-bit right shifter
    reg [4:0]  sh_amt;
    reg        pw_en, pw_dir;       // pin write: enable, 0 = levels / 1 = directions
    reg [4:0]  pw_base, pw_count;
    reg [15:0] pw_data;
    reg [31:0] pw_m, pw_d;
    reg        rx_push_eng;
    reg [15:0] rx_push_data;
    // next state
    reg [4:0]  n_osr_count, n_isr_count, n_delay;
    reg [15:0] n_x, n_y, n_osr, n_isr, n_sw;
    reg        n_sw_run;
    reg [31:0] n_out_val, n_out_dir;

    // ------------------------------------------------------------------ next-state logic (one step)
    always @(*) begin
        // ---- defaults: nothing changes
        n_pc = pc; n_x = x; n_y = y;
        n_osr = osr; n_osr_count = osr_count;
        n_isr = isr; n_isr_count = isr_count;
        n_delay = delay; n_sw = sw; n_sw_run = sw_run;
        n_out_val = oval; n_out_dir = out_dir;
        tx_pop_eng = 0; rx_push_eng = 0; rx_push_data = 0;
        ser_start = 0; ser_count = 0; crc_clr_time = 0; in_step = 0; in_bit = 0;
        instr = imem_rdata;     // the word at pc, read on the last clock
        op = instr[15:13]; mid = instr[12:8]; a = instr[7:0];
        dbits = 3'd5 - {1'b0, cfg_side_count} - {2'b0, cfg_side_opt};
        dly = mid & ((5'd1 << dbits) - 5'd1);
        sval_full = (mid >> dbits) & ((5'd1 << cfg_side_count) - 5'd1);
        sen = (cfg_side_count != 2'd0) && (!cfg_side_opt || mid[4]);
        stall = 0; do_jump = 0; jaddr = 0; take = 0;
        n = (a[3:0] == 4'd0) ? 5'd16 : {1'b0, a[3:0]};
        m17 = (17'd1 << n) - 17'd1;
        msk = m17[15:0];
        data = 0; v = 0; t32 = 0; sum6 = 0; pidx = 0;
        pw_en = 0; pw_dir = 0; pw_base = 0; pw_count = 0; pw_data = 0; pw_m = 0; pw_d = 0;

        // shared pin reader (IN pins and MOV pins)
        t32 = rotr32(sync2, cfg_in_base);
        pins_rd = t32[15:0];

        // shared shifter, set up for IN or OUT (whichever is executing; ignored otherwise)
        // IN  right: {data, isr} >> n          IN  left: ({isr,0} >> (16-n)) | data
        // OUT right: {0, osr} >> n             OUT left: {osr,0} >> (16-n): low = new osr, high = data
        case (a[7:5])
            3'd0: in_data = pins_rd;
            3'd1: in_data = x;
            3'd2: in_data = y;
            3'd4: in_data = isr;
            3'd5: in_data = osr;
            3'd6: in_data = (tick && sw_run && sw != 16'hFFFF) ? sw + 16'd1 : sw;   // = n_sw
            3'd7: in_data = crc[15:0];
            default: in_data = 16'd0;
        endcase
        in_data = in_data & msk;
        in_bit = cfg_in_right ? in_data[0] : in_data[n - 5'd1];   // the first bit shifted in
        if (op == 3'd2) begin
            sh_in  = cfg_in_right ? {in_data, isr} : {isr, 16'd0};
            sh_amt = cfg_in_right ? n : 5'd16 - n;
        end else begin
            sh_in  = cfg_out_right ? {16'd0, osr} : {osr, 16'd0};
            sh_amt = cfg_out_right ? n : 5'd16 - n;
        end
        sh_out = sh_in >> sh_amt;

        if (tick) begin
            if (sw_run) n_sw = (sw == 16'hFFFF) ? sw : sw + 16'd1;

            if (delay != 5'd0) begin
                n_delay = delay - 5'd1;
            end else begin
                case (op)
                3'd0: begin                                         // JMP
                    case (a[7:5])
                        3'd0: take = 1'b1;
                        3'd1: take = (x == 16'd0);
                        3'd2: begin take = (x != 16'd0); n_x = x - 16'd1; end
                        3'd3: take = (y == 16'd0);
                        3'd4: begin take = (y != 16'd0); n_y = y - 16'd1; end
                        3'd5: take = (x != y);
                        3'd6: take = sync2[cfg_jmp_pin];
                        default: take = (osr_count < 5'd16);
                    endcase
                    if (take) begin do_jump = 1'b1; jaddr = a[4:0]; end
                end
                3'd1: begin                                         // WAIT
                    pidx = a[5] ? (cfg_in_base + a[4:0]) : a[4:0];
                    if (wait_src[pidx] != a[7]) begin
                        if (a[6] && y == 16'd0) begin
                            do_jump = 1'b1; jaddr = cfg_fault_addr;
                        end else begin
                            if (a[6]) n_y = y - 16'd1;
                            stall = 1'b1;
                        end
                    end
                end
                3'd2: begin                                         // IN
                    in_step = 1'b1;
                    n_isr = cfg_in_right ? sh_out[15:0] : (sh_out[15:0] | in_data);
                    sum6 = {1'b0, isr_count} + {1'b0, n};
                    n_isr_count = (sum6 > 6'd16) ? 5'd16 : sum6[4:0];
                end
                3'd3: begin                                         // OUT
                    n_osr = sh_out[15:0];
                    data  = (cfg_out_right ? osr : sh_out[31:16]) & msk;
                    sum6 = {1'b0, osr_count} + {1'b0, n};
                    n_osr_count = (sum6 > 6'd16) ? 5'd16 : sum6[4:0];
                    case (a[7:5])
                        3'd0: begin pw_en = 1'b1; pw_base = cfg_out_base; pw_count = n; pw_data = data; end
                        3'd1: n_x = data;
                        3'd2: n_y = data;
                        3'd4: begin pw_en = 1'b1; pw_dir = 1'b1; pw_base = cfg_out_base; pw_count = n; pw_data = data; end
                        3'd5: begin do_jump = 1'b1; jaddr = data[4:0]; end
                        3'd6: begin n_isr = data; n_isr_count = n; end
                        default: ;
                    endcase
                end
                3'd4: begin                                         // PUSH / PULL
                    if (!a[7]) begin
                        if (a[6] && isr_count < 5'd16) begin
                        end else if (rx_cnt == 3'd4) begin
                            stall = a[5];
                        end else begin
                            rx_push_eng = 1'b1; rx_push_data = isr;
                            n_isr = 0; n_isr_count = 0;
                        end
                    end else begin
                        if (a[6] && osr_count < 5'd16) begin
                        end else if (!tx_ready || ser_busy || rx_only) begin   // serialiser busy or receive mode: not the program's
                            if (a[5]) stall = 1'b1;
                            else begin n_osr = x; n_osr_count = 0; end
                        end else begin
                            tx_pop_eng = 1'b1;
                            n_osr = tx_head; n_osr_count = 0;
                        end
                    end
                end
                3'd5: begin                                         // MOV
                    case (a[2:0])
                        3'd0: v = pins_rd;
                        3'd1: v = x;
                        3'd2: v = y;
                        3'd3: v = 16'd0;
                        3'd4: v = n_sw;
                        3'd5: v = {6'd0, ser_under, ser_busy, 1'b0, rx_cnt, tx_sat4};
                        3'd6: v = isr;
                        default: v = osr;
                    endcase
                    if (a[4:3] == 2'd1)      v = ~v;
                    else if (a[4:3] == 2'd2) v = bitrev16(v);
                    case (a[7:5])
                        3'd0: begin pw_en = 1'b1; pw_base = cfg_out_base; pw_count = cfg_out_count; pw_data = v; end
                        3'd1: n_x = v;
                        3'd2: n_y = v;
                        3'd3: begin ser_start = 1'b1; ser_count = v; end          // mov ser (engine 0 only)
                        3'd5: begin do_jump = 1'b1; jaddr = v[4:0]; end
                        3'd6: begin n_isr = v; n_isr_count = 0; end
                        3'd7: begin n_osr = v; n_osr_count = 0; end
                        default: ;
                    endcase
                end
                3'd6: begin                                         // SET
                    case (a[7:5])
                        3'd0: begin pw_en = 1'b1; pw_base = cfg_set_base; pw_count = {2'b0, cfg_set_count}; pw_data = {11'd0, a[4:0]}; end
                        3'd1: n_x = {11'd0, a[4:0]};
                        3'd2: n_y = {11'd0, a[4:0]};
                        3'd4: begin pw_en = 1'b1; pw_dir = 1'b1; pw_base = cfg_set_base; pw_count = {2'b0, cfg_set_count}; pw_data = {11'd0, a[4:0]}; end
                        default: ;
                    endcase
                end
                default: begin                                      // TIME
                    case (a[7:5])
                        3'd0: begin n_sw = 16'd0; n_sw_run = 1'b1; end
                        3'd1: n_sw_run = 1'b0;
                        3'd2: n_x = n_sw;
                        3'd3: n_y = n_sw;
                        3'd4: begin n_isr = n_sw; n_isr_count = 5'd16; end
                        3'd5: crc_clr_time = 1'b1;                              // time crc reset
                        default: ;
                    endcase
                end
                endcase

                // the one shared pin writer
                pw_m = rotl32((32'd1 << pw_count) - 32'd1, pw_base);
                pw_d = rotl32({16'd0, pw_data}, pw_base);
                if (pw_en && !pw_dir) n_out_val = (oval & ~pw_m) | (pw_d & pw_m);
                if (pw_en &&  pw_dir) n_out_dir = (out_dir & ~pw_m) | (pw_d & pw_m);

                // side-set: on every executed step, stalled or not; wins over the instruction
                if (sen && cfg_side_dir)
                    n_out_dir = wr_bits(n_out_dir, cfg_side_base, {3'b0, cfg_side_count}, {11'd0, sval_full});
                else if (sen)
                    n_out_val = wr_bits(n_out_val, cfg_side_base, {3'b0, cfg_side_count}, {11'd0, sval_full});

                if (!stall) begin
                    n_delay = dly;
                    n_pc = do_jump ? jaddr : ((pc == cfg_wrap_top) ? cfg_wrap_bottom : pc + 5'd1);
                end
            end
        end
    end

    // ------------------------------------------------------------------ flip-flops
    always @(posedge clk) begin
        if (!rst_n) begin
            pc <= cfg_start;
            x <= 0; y <= 0;
            osr <= 0; osr_count <= 5'd16;
            isr <= 0; isr_count <= 0;
            delay <= 0; sw <= 0; sw_run <= 0;
            oval <= 0; out_dir <= 0;
            div <= 0; sync1 <= 0; sync2 <= 0;
            rx_rd <= 0; rx_wr <= 0; rx_cnt <= 0;
        end else begin
            // ---- registers
            pc <= n_pc; x <= n_x; y <= n_y;
            osr <= n_osr; osr_count <= n_osr_count;
            isr <= n_isr; isr_count <= n_isr_count;
            delay <= n_delay; sw <= n_sw; sw_run <= n_sw_run;
            oval <= n_out_val; out_dir <= n_out_dir;
            div <= tick ? cfg_clkdiv : div - 16'd1;
            sync2 <= sync1; sync1 <= pins_in;

            // ---- RX FIFO (host and engine can act in the same clock; the TX FIFO is above)
            if (rx_push_eng)  begin rxm[rx_wr] <= rx_push_data; rx_wr <= rx_wr + 2'd1; end
            if (host_pop_ok)  rx_rd <= rx_rd + 2'd1;
            rx_cnt <= rx_cnt + {2'b0, rx_push_eng} - {2'b0, host_pop_ok};
        end
    end

endmodule
