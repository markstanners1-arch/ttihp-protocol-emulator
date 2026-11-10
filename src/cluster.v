// One cluster: NENG engines (populated slots, 1 to NSLOT) sharing a pin bank, with their setting registers,
// the pin mux ("lowest engine wins") and this cluster's slice of the host register file.
// The chip (src/chip.v) holds the host port, the input filter and the ID register and instantiates NCLUSTER of these.
// Spec: docs/core_design.md (hierarchy), docs/host_port.md (registers), docs/isa.md (engines).
//
// Host bus in (one cluster's view, already qualified by the chip with this cluster's number):
//   wr      one-clock pulse: write wdata to (eng, addr)
//   pop     one-clock pulse: the word at (eng, addr) has been sent; for the RX FIFO this pops it
//   eng     slot number 0..7; a slot past the last populated one ignores writes and reads 0
//   rdata   the register at (eng, addr), combinational; 0 for registers this cluster does not hold
// Pins: pins_in is the bank as every engine sees it (NPIN numbers); out_val/out_dir are the bank's
// outputs after arbitration between the engines.

`timescale 1ns/1ps
`default_nettype none

module cluster #(
    parameter NENG     = 3,             // engines populated, 1 to NSLOT
    parameter NSLOT    = 4,             // engine slots the cluster is laid out for (the host's engine field spans 8)
    parameter NPIN     = 32,            // pin numbers in the bank (an engine's pin fields are 5 bits)
    parameter TXDEPTH0 = 64,            // engine 0's TX FIFO depth (the serialiser's buffer); engines 1.. have 4
    parameter SER0     = 1,             // 1: engine 0 has the serialiser (0: SERCFG/SERDIV read 0, MOV ser does nothing)
    parameter CRC      = 1              // 1: every engine has a CRC unit (0: CRCPOLY/CRCINIT/CRC read 0)
) (
    input  wire            clk,
    input  wire            rst_n,
    // host register bus
    input  wire            wr,
    input  wire            pop,
    input  wire [2:0]      eng,
    input  wire [5:0]      addr,
    input  wire [15:0]     wdata,
    output reg  [15:0]     rdata,
    // pin bank
    input  wire [NPIN-1:0] pins_in,
    output reg  [NPIN-1:0] out_val,
    output reg  [NPIN-1:0] out_dir,
    output reg             irq,        // some engine's RX FIFO holds data, or engine 0 has received a frame
    // engine 0's receiver: the pin it listens on (the chip latches that pad at the falling edge of clk) and the result
    output wire [4:0]      rx_pin,
    input  wire            rx_fall,
    input  wire            rx_rise
);
    wire eng_ok = (eng < NENG);         // a slot past the last populated engine: writes ignored, reads 0

    // ------------------------------------------------------------ the engines, each slot with its own registers
    // Each slot keeps its setting registers and its read-back mux beside its engine, so the only wires shared
    // between slots are the host bus (strobes, engine number, address, write data) and one 16-bit word back.
    wire [NPIN-1:0] e_out_val [0:NENG-1];
    wire [NPIN-1:0] e_out_dir [0:NENG-1];
    wire [15:0]     slot_rdata [0:NENG-1];
    wire            slot_rx    [0:NENG-1];      // the slot's RX FIFO holds data, or a received frame is ready (IRQ)
    wire [4:0]      slot_rxpin [0:NENG-1];

    genvar g;
    generate
        for (g = 0; g < NENG; g = g + 1) begin : eng_slot
            wire sel = (eng == g);
            wire wr_s = wr && sel;

            // setting registers for this slot
            reg        run;
            reg [15:0] r_clkdiv;
            reg [14:0] r_wrap;
            reg [14:0] r_outcfg;
            reg [13:0] r_misc;
            reg [14:0] r_incfg;
            reg [31:0] r_crcpoly;               // CRCPOLY lo/hi (0x2D, 0x2E)
            reg [31:0] r_crcinit;               // CRCINIT lo/hi (0x2F, 0x30)
            reg [12:0] r_sercfg;                // SERCFG (0x2B), engine 0 only
            reg [15:0] r_serdiv;                // SERDIV (0x2C), engine 0 only
            reg [6:0]  r_rxcfg;                 // RXCFG (0x34) [4:0] pin, [5] raw, [6] both edges; engine 0 only
            reg [15:0] r_rxgap;                 // RXGAP (0x35), half-clocks; engine 0 only
            localparam HAS_SER = (g == 0 && SER0) ? 1 : 0;

            always @(posedge clk) begin
                if (!rst_n) begin
                    run <= 1'b0; r_clkdiv <= 0; r_wrap <= 0; r_outcfg <= 0; r_misc <= 0; r_incfg <= 0;
                    r_crcpoly <= 0; r_crcinit <= 0; r_sercfg <= 0; r_serdiv <= 0;
                    r_rxcfg <= 0; r_rxgap <= 16'd6;     // 6 half-clocks: 10 Mbit/s at 40 MHz
                end else if (wr_s) case (addr)
                    6'h20: run      <= wdata[0];
                    6'h21: r_clkdiv <= wdata;
                    6'h22: r_wrap   <= wdata[14:0];
                    6'h23: r_outcfg <= wdata[14:0];
                    6'h24: r_misc   <= wdata[13:0];
                    6'h25: r_incfg  <= wdata[14:0];
                    6'h2B: if (HAS_SER) r_sercfg <= {wdata[12:9], 2'b00, wdata[6:0]};  // [8:7], the mode, is engine state
                    6'h2C: if (HAS_SER) r_serdiv <= wdata;
                    6'h2D: if (CRC) r_crcpoly[15:0]  <= wdata;
                    6'h2E: if (CRC) r_crcpoly[31:16] <= wdata;
                    6'h2F: if (CRC) r_crcinit[15:0]  <= wdata;
                    6'h30: if (CRC) r_crcinit[31:16] <= wdata;
                    6'h34: if (HAS_SER) r_rxcfg <= wdata[6:0];
                    6'h35: if (HAS_SER) r_rxgap <= wdata;
                    default: ;
                endcase
            end

            wire [15:0] pop_data;
            wire [10:0] txl;
            wire [2:0]  rxl;
            wire [4:0]  e_pc;
            wire        e_busy, e_under;
            wire [31:0] e_crc;
            wire [15:0] x_, y_, osr_, isr_, sw_;
            wire [4:0]  oc_, ic_, dl_;
            wire        swr_;
            wire [15:0] bpop_data, e_rxstat;
            wire        e_bufready, e_rxready;
            wire [1:0]  e_mode;
            wire [10:0] e_rblevel, e_rxwords;
            wire        e_held;
            wire _unused_fdx = &{e_rblevel, e_held, 1'b0};   // for the engine-level tests only
            // the mode changes only on a SERCFG write carrying the key 101 in [15:13]: [8] full duplex, else [7] receive
            wire mode_wr = HAS_SER && wr_s && addr == 6'h2B && wdata[15:13] == 3'b101;
            wire rx_arm  = HAS_SER && wr_s && addr == 6'h34 && wdata[7];
            engine #(.SER(HAS_SER), .TXDEPTH(g == 0 ? TXDEPTH0 : 4), .CRC(CRC)) e (
                .clk(clk), .rst_n(rst_n & run),
                .cfg_clkdiv(r_clkdiv),
                .cfg_start(r_wrap[4:0]), .cfg_wrap_bottom(r_wrap[9:5]), .cfg_wrap_top(r_wrap[14:10]),
                .cfg_out_base(r_outcfg[4:0]), .cfg_out_count(r_outcfg[9:5]), .cfg_set_base(r_outcfg[14:10]),
                .cfg_set_count(r_misc[2:0]), .cfg_side_base(r_misc[7:3]), .cfg_side_count(r_misc[9:8]),
                .cfg_side_opt(r_misc[10]), .cfg_out_right(r_misc[11]), .cfg_in_right(r_misc[12]),
                .cfg_side_dir(r_misc[13]),
                .cfg_in_base(r_incfg[4:0]), .cfg_jmp_pin(r_incfg[9:5]), .cfg_fault_addr(r_incfg[14:10]),
                .cfg_sercfg(HAS_SER ? r_sercfg : 13'd0), .cfg_serdiv(HAS_SER ? r_serdiv : 16'd0),
                .cfg_crcpoly(r_crcpoly), .cfg_crcinit(r_crcinit),
                // program words: only while this engine is stopped
                .imem_we(wr_s && addr[5] == 1'b0 && !run), .imem_addr(addr[4:0]), .imem_wdata(wdata),
                .host_push(wr_s && addr == 6'h26), .host_push_data(wdata),
                .host_pop(pop && sel && addr == 6'h27), .host_pop_data(pop_data),
                .tx_level(txl), .rx_level(rxl),
                .pins_in(pins_in), .out_val(e_out_val[g]), .out_dir(e_out_dir[g]),
                .ser_busy(e_busy), .ser_under(e_under), .crc(e_crc),
                .pc(e_pc), .x(x_), .y(y_), .osr(osr_), .osr_count(oc_), .isr(isr_), .isr_count(ic_),
                .delay(dl_), .sw(sw_), .sw_run(swr_),
                .cfg_rx_pin(r_rxcfg[4:0]), .cfg_rx_raw(r_rxcfg[5]), .cfg_rx_both(r_rxcfg[6]), .cfg_rxgap(r_rxgap),
                .rx_fall(HAS_SER ? rx_fall : 1'b0), .rx_rise(HAS_SER ? rx_rise : 1'b0), .mode_wr(mode_wr),
                .mode_val(wdata[8] ? 2'd2 : {1'b0, wdata[7]}), .rx_arm(rx_arm),
                .host_bpop(pop && sel && ((addr == 6'h26 && e_mode == 2'd1) || addr == 6'h37)), .host_bpop_data(bpop_data),
                .buf_ready(e_bufready), .mode(e_mode), .rb_level(e_rblevel), .rx_held(e_held),
                .rx_ready(e_rxready), .rxstat(e_rxstat), .rx_words(e_rxwords));

            // host reads of this slot: the address picks the word here, the cluster then picks the slot
            reg [15:0] rd;
            always @(*) begin
                case (addr)
                    6'h20: rd = {15'd0, run};
                    6'h21: rd = r_clkdiv;
                    6'h22: rd = {1'b0, r_wrap};
                    6'h23: rd = {1'b0, r_outcfg};
                    6'h24: rd = {2'b0, r_misc};
                    6'h25: rd = {1'b0, r_incfg};
                    6'h26: rd = (e_mode == 2'd1 && e_bufready) ? bpop_data : 16'd0;   // receive mode: the received words
                    6'h27: rd = (rxl != 0) ? pop_data : 16'd0;
                    6'h28: rd = {e_under, e_busy, e_pc, run, 1'b0, rxl, 1'b0,
                                 (txl > 11'd7) ? 3'd7 : txl[2:0]};               // TX level saturating at 7
                    6'h2B: rd = HAS_SER ? {3'd0, r_sercfg[12:9], e_mode[1], e_mode[0], r_sercfg[6:0]} : 16'd0;   // [8:7]: in force
                    6'h2C: rd = HAS_SER ? r_serdiv : 16'd0;
                    6'h2D: rd = r_crcpoly[15:0];
                    6'h2E: rd = r_crcpoly[31:16];
                    6'h2F: rd = r_crcinit[15:0];
                    6'h30: rd = r_crcinit[31:16];
                    6'h31: rd = e_crc[15:0];
                    6'h32: rd = e_crc[31:16];
                    6'h33: rd = {6'd0, e_under, e_busy, 1'b0, (txl > 11'd127) ? 7'd127 : txl[6:0]};   // SERSTAT: level to 127
                    6'h34: rd = HAS_SER ? {9'd0, r_rxcfg} : 16'd0;
                    6'h35: rd = HAS_SER ? r_rxgap : 16'd0;
                    6'h36: rd = e_rxstat;                                         // RXSTAT (0 off engine 0)
                    6'h37: rd = (e_mode != 2'd0 && e_bufready) ? bpop_data : 16'd0;   // RXDATA: receive or full duplex
                    6'h38: rd = {5'd0, txl};                                      // SERLEVEL: the TX level, unsaturated
                    6'h39: rd = {5'd0, e_rxwords};                                // RXWORDS: words received, unsaturated
                    default: rd = 16'd0;
                endcase
            end
            assign slot_rdata[g] = rd;
            assign slot_rx[g]    = (rxl != 0) || e_rxready;
            assign slot_rxpin[g] = HAS_SER ? r_rxcfg[4:0] : 5'd0;
        end
    endgenerate

    assign rx_pin = slot_rxpin[0];

    // ------------------------------------------------------------ host reads: one word from the selected slot
    always @(*) rdata = eng_ok ? slot_rdata[eng] : 16'd0;

    // ------------------------------------------------------------ pin bank: the lowest engine driving a pin wins
    integer m;
    always @(*) begin
        out_dir = {NPIN{1'b0}}; out_val = {NPIN{1'b0}}; irq = 1'b0;
        for (m = NENG - 1; m >= 0; m = m - 1) begin          // highest first, so the lowest has the last word
            out_dir = out_dir | e_out_dir[m];
            out_val = (e_out_dir[m] & e_out_val[m]) | (~e_out_dir[m] & out_val);
            irq     = irq | slot_rx[m];
        end
    end

    // NSLOT is the layout count; the decode above addresses slots by the 3-bit engine field, and slots
    // NENG..NSLOT-1 are unpopulated (absent to the host). An out-of-range NENG fails elaboration:
    generate if (NENG < 1 || NENG > NSLOT) begin : bad_neng
        cluster_NENG_must_be_1_to_NSLOT not_a_module ();
    end endgenerate

endmodule
