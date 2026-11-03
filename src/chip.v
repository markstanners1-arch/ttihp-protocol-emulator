// The whole chip: SPI host port + NENG engines (3 on the ASIC, decided 3 Nov 2026: four do not place on the 6x4 tile;
// the MachXO3L kit fits 2, the Cyclone IV board 3) + their setting registers + pin wiring.
// Tiny Tapeout pin interface. Spec: docs/host_port.md (host side), docs/isa.md (engines).

`timescale 1ns/1ps
`default_nettype none

module protocol_chip #(
    parameter NENG = 3                  // engines, 1 to 8 (the host's engine field is 3 bits)
) (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    localparam [3:0] NENG4 = NENG;      // for the ID register

    // ------------------------------------------------------------ host port
    wire        h_wr, h_rd, h_pop, miso;
    wire [2:0]  h_eng;
    wire [5:0]  h_addr;
    wire [15:0] h_wdata;
    reg  [15:0] h_rdata;

    host_spi host (
        .clk(clk), .rst_n(rst_n),
        .cs_n(ui_in[0]), .sck(ui_in[1]), .mosi(ui_in[2]), .miso(miso),
        .wr(h_wr), .rd(h_rd), .pop(h_pop), .eng(h_eng), .addr(h_addr),
        .wdata(h_wdata), .rdata(h_rdata));

    wire eng_ok = (h_eng < NENG);       // an engine number past the last: writes ignored, reads 0

    // ------------------------------------------------------------ setting registers, one set per engine
    reg        run      [0:NENG-1];
    reg [15:0] r_clkdiv [0:NENG-1];
    reg [14:0] r_wrap   [0:NENG-1];
    reg [14:0] r_outcfg [0:NENG-1];
    reg [13:0] r_misc   [0:NENG-1];
    reg [14:0] r_incfg  [0:NENG-1];
    reg [7:0]  r_filter;            // chip-wide input glitch filter: [3:0] N, [7:4] P (docs/input_filter.md)

    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (k = 0; k < NENG; k = k + 1) begin
                run[k] <= 1'b0; r_clkdiv[k] <= 0; r_wrap[k] <= 0; r_outcfg[k] <= 0; r_misc[k] <= 0; r_incfg[k] <= 0;
            end
            r_filter <= 8'd0;
        end else if (h_wr) begin
            if (h_addr == 6'h29) r_filter <= h_wdata[7:0];           // chip-wide, whatever the engine field says
            else if (eng_ok) case (h_addr)
                6'h20: run[h_eng]      <= h_wdata[0];
                6'h21: r_clkdiv[h_eng] <= h_wdata;
                6'h22: r_wrap[h_eng]   <= h_wdata[14:0];
                6'h23: r_outcfg[h_eng] <= h_wdata[14:0];
                6'h24: r_misc[h_eng]   <= h_wdata[13:0];
                6'h25: r_incfg[h_eng]  <= h_wdata[14:0];
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------ pins as the engines see them (32 numbers)
    wire [31:0] e_out_val [0:NENG-1];
    wire [31:0] e_out_dir [0:NENG-1];
    // every engine input: 2 flip-flop synchroniser, then the glitch filter (one shared setting)
    reg  [12:0] in_s1, in_s2;
    always @(posedge clk) begin
        in_s1 <= {ui_in[7:3], uio_in};
        in_s2 <= in_s1;
    end
    wire [12:0] in_f;
    glitch_filter #(.WIDTH(13)) filt (.clk(clk), .rst_n(rst_n), .p(r_filter[7:4]), .n(r_filter[3:0]),
                                      .in(in_s2), .out(in_f));
    wire [31:0] pins_in = {12'd0, in_f[12:8], 7'd0, in_f[7:0]};   // 0-7 uio, 15-19 ui_in[3..7]

    // ------------------------------------------------------------ the engines
    wire [15:0] pop_data [0:NENG-1];
    wire [2:0]  txl [0:NENG-1], rxl [0:NENG-1];
    wire [4:0]  e_pc [0:NENG-1];

    genvar g;
    generate
        for (g = 0; g < NENG; g = g + 1) begin : eng
            wire sel = (h_eng == g);
            wire [15:0] x_, y_, osr_, isr_, sw_;
            wire [4:0]  oc_, ic_, dl_;
            wire        swr_;
            engine e (
                .clk(clk), .rst_n(rst_n & run[g]),
                .cfg_clkdiv(r_clkdiv[g]),
                .cfg_start(r_wrap[g][4:0]), .cfg_wrap_bottom(r_wrap[g][9:5]), .cfg_wrap_top(r_wrap[g][14:10]),
                .cfg_out_base(r_outcfg[g][4:0]), .cfg_out_count(r_outcfg[g][9:5]), .cfg_set_base(r_outcfg[g][14:10]),
                .cfg_set_count(r_misc[g][2:0]), .cfg_side_base(r_misc[g][7:3]), .cfg_side_count(r_misc[g][9:8]),
                .cfg_side_opt(r_misc[g][10]), .cfg_out_right(r_misc[g][11]), .cfg_in_right(r_misc[g][12]),
                .cfg_side_dir(r_misc[g][13]),
                .cfg_in_base(r_incfg[g][4:0]), .cfg_jmp_pin(r_incfg[g][9:5]), .cfg_fault_addr(r_incfg[g][14:10]),
                // program words: only while this engine is stopped
                .imem_we(h_wr && sel && h_addr[5] == 1'b0 && !run[g]), .imem_addr(h_addr[4:0]), .imem_wdata(h_wdata),
                .host_push(h_wr && sel && h_addr == 6'h26), .host_push_data(h_wdata),
                .host_pop(h_pop && sel && h_addr == 6'h27), .host_pop_data(pop_data[g]),
                .tx_level(txl[g]), .rx_level(rxl[g]),
                .pins_in(pins_in), .out_val(e_out_val[g]), .out_dir(e_out_dir[g]),
                .pc(e_pc[g]), .x(x_), .y(y_), .osr(osr_), .osr_count(oc_), .isr(isr_), .isr_count(ic_),
                .delay(dl_), .sw(sw_), .sw_run(swr_));
        end
    endgenerate

    // ------------------------------------------------------------ host reads
    reg [15:0] eng_rdata;               // the selected engine's registers (only used when eng_ok)
    always @(*) begin
        case (h_addr)
            6'h20: eng_rdata = {15'd0, run[h_eng]};
            6'h21: eng_rdata = r_clkdiv[h_eng];
            6'h22: eng_rdata = {1'b0, r_wrap[h_eng]};
            6'h23: eng_rdata = {1'b0, r_outcfg[h_eng]};
            6'h24: eng_rdata = {2'b0, r_misc[h_eng]};
            6'h25: eng_rdata = {1'b0, r_incfg[h_eng]};
            6'h27: eng_rdata = (rxl[h_eng] != 0) ? pop_data[h_eng] : 16'd0;
            6'h28: eng_rdata = {2'b0, e_pc[h_eng], run[h_eng], 1'b0, rxl[h_eng], 1'b0, txl[h_eng]};
            default: eng_rdata = 16'd0;
        endcase
        case (h_addr)
            6'h29:   h_rdata = {8'd0, r_filter};                      // chip-wide
            6'h2A:   h_rdata = {8'd0, 4'd2, NENG4};                   // ID: [7:4] spec version 2, [3:0] engines
            default: h_rdata = eng_ok ? eng_rdata : 16'd0;
        endcase
    end

    // ------------------------------------------------------------ engine pins to chip pins (the lowest engine driving a pin wins)
    reg [31:0] drv, val;
    reg        any_rx;                  // IRQ: some engine's RX FIFO holds data
    integer m;
    always @(*) begin
        drv = 32'd0; val = 32'd0; any_rx = 1'b0;
        for (m = NENG - 1; m >= 0; m = m - 1) begin          // highest first, so the lowest has the last word
            drv    = drv | e_out_dir[m];
            val    = (e_out_dir[m] & e_out_val[m]) | (~e_out_dir[m] & val);
            any_rx = any_rx | (rxl[m] != 0);
        end
    end

    assign uio_oe  = drv[7:0];
    assign uio_out = val[7:0] & drv[7:0];
    assign uo_out  = {val[13:8] & drv[13:8], any_rx, miso};

    wire _unused = &{ena, h_rd, ui_in[0], 1'b0};

endmodule
