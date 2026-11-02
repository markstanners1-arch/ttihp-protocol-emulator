// The whole chip: SPI host port + two engines + their setting registers + pin wiring.
// Tiny Tapeout pin interface. Spec: docs/host_port.md (host side), docs/isa.md (engines).

`timescale 1ns/1ps
`default_nettype none

module protocol_chip (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ------------------------------------------------------------ host port
    wire        h_wr, h_rd, h_pop, h_eng, miso;
    wire [5:0]  h_addr;
    wire [15:0] h_wdata;
    reg  [15:0] h_rdata;

    host_spi host (
        .clk(clk), .rst_n(rst_n),
        .cs_n(ui_in[0]), .sck(ui_in[1]), .mosi(ui_in[2]), .miso(miso),
        .wr(h_wr), .rd(h_rd), .pop(h_pop), .eng(h_eng), .addr(h_addr),
        .wdata(h_wdata), .rdata(h_rdata));

    // ------------------------------------------------------------ setting registers, one set per engine
    reg        run      [0:1];
    reg [15:0] r_clkdiv [0:1];
    reg [14:0] r_wrap   [0:1];
    reg [14:0] r_outcfg [0:1];
    reg [12:0] r_misc   [0:1];
    reg [14:0] r_incfg  [0:1];
    reg [7:0]  r_filter;            // chip-wide input glitch filter: [3:0] N, [7:4] P (docs/input_filter.md)

    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (k = 0; k < 2; k = k + 1) begin
                run[k] <= 1'b0; r_clkdiv[k] <= 0; r_wrap[k] <= 0; r_outcfg[k] <= 0; r_misc[k] <= 0; r_incfg[k] <= 0;
            end
            r_filter <= 8'd0;
        end else if (h_wr) begin
            case (h_addr)
                6'h20: run[h_eng]      <= h_wdata[0];
                6'h21: r_clkdiv[h_eng] <= h_wdata;
                6'h22: r_wrap[h_eng]   <= h_wdata[14:0];
                6'h23: r_outcfg[h_eng] <= h_wdata[14:0];
                6'h24: r_misc[h_eng]   <= h_wdata[12:0];
                6'h25: r_incfg[h_eng]  <= h_wdata[14:0];
                6'h29: r_filter        <= h_wdata[7:0];
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------ pins as the engines see them (32 numbers)
    wire [31:0] e_out_val [0:1];
    wire [31:0] e_out_dir [0:1];
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

    // ------------------------------------------------------------ the two engines
    wire [15:0] pop_data [0:1];
    wire [2:0]  txl [0:1], rxl [0:1];
    wire [4:0]  e_pc [0:1];

    genvar g;
    generate
        for (g = 0; g < 2; g = g + 1) begin : eng
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
    always @(*) begin
        case (h_addr)
            6'h20: h_rdata = {15'd0, run[h_eng]};
            6'h21: h_rdata = r_clkdiv[h_eng];
            6'h22: h_rdata = {1'b0, r_wrap[h_eng]};
            6'h23: h_rdata = {1'b0, r_outcfg[h_eng]};
            6'h24: h_rdata = {3'b0, r_misc[h_eng]};
            6'h25: h_rdata = {1'b0, r_incfg[h_eng]};
            6'h27: h_rdata = (rxl[h_eng] != 0) ? pop_data[h_eng] : 16'd0;
            6'h28: h_rdata = {2'b0, e_pc[h_eng], run[h_eng], 1'b0, rxl[h_eng], 1'b0, txl[h_eng]};
            6'h29: h_rdata = {8'd0, r_filter};
            default: h_rdata = 16'd0;
        endcase
    end

    // ------------------------------------------------------------ engine pins to chip pins (engine A wins)
    wire [31:0] drv = e_out_dir[0] | e_out_dir[1];
    wire [31:0] val = (e_out_dir[0] & e_out_val[0]) | (~e_out_dir[0] & e_out_val[1]);

    assign uio_oe  = drv[7:0];
    assign uio_out = val[7:0] & drv[7:0];
    assign uo_out  = {val[13:8] & drv[13:8], (rxl[0] != 0) || (rxl[1] != 0), miso};

    wire _unused = &{ena, h_rd, ui_in[0], 1'b0};

endmodule
