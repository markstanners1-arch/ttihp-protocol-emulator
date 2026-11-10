// The whole chip: SPI host port + chip-wide input filter and ID register + NCLUSTER clusters (src/cluster.v), each of
// NENG engines (the Tiny Tapeout wrapper sets 4 with CRC = 0; the MachXO3L kit build has 2, the Cyclone IV and Mojo
// builds 3, or 2 with the serialiser). Tiny Tapeout pin interface. Spec: docs/host_port.md (host side), docs/isa.md (engines),
// docs/core_design.md (hierarchy).

`timescale 1ns/1ps
`default_nettype none

module protocol_chip #(
    parameter NENG     = 3,             // engines per cluster, 1 to 4 (the host's engine field is 3 bits)
    parameter NCLUSTER = 1,             // clusters, 1 to 64 (the host's cluster field is 6 bits); this package has one pin bank
    parameter TXDEPTH0 = 1024,          // engine 0's TX FIFO depth (the serialiser's frame buffer): 1024 on the ASIC, 64 on the FPGAs
    parameter SER0     = 1,             // engine 0 has the serialiser (the MachXO3L kit's default build leaves it out)
    parameter CRC      = 1              // every engine has a CRC unit (likewise)
) (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n,
    // engine 0's receive pin: the pad it names, out to a latch that holds it at the falling edge of clk (in the
    // wrapper: a technology latch on the ASIC, a falling-edge flip-flop on an FPGA), and that latch's output back in
    output wire       rx_pad,
    input  wire       rx_fall
);
    localparam [3:0] NENG4 = NENG;      // for the ID register

    // ------------------------------------------------------------ host port
    wire        h_wr, h_rd, h_pop, miso;
    wire [5:0]  h_clu;
    wire [2:0]  h_eng;
    wire [5:0]  h_addr;
    wire [15:0] h_wdata;
    reg  [15:0] h_rdata;

    host_spi host (
        .clk(clk), .rst_n(rst_n),
        .cs_n(ui_in[0]), .sck(ui_in[1]), .mosi(ui_in[2]), .miso(miso),
        .wr(h_wr), .rd(h_rd), .pop(h_pop), .clu(h_clu), .eng(h_eng), .addr(h_addr),
        .wdata(h_wdata), .rdata(h_rdata));

    // Cluster decode. A cluster number past the last: writes ignored, reads 0. Reads use the compare directly (the host
    // port fetches rdata the clock after it latches the command). Writes and pops use a registered copy: a strobe comes
    // at least 16 SCK edges (128 clocks) after the command word, so the copy is long settled, and it keeps the 6-bit
    // compare out of every register and program-word enable (on the MachXO3L kit the direct form cost about 245 LUTs).
    wire clu_ok = (h_clu < NCLUSTER);
    reg  clu_ok_r;
    always @(posedge clk) clu_ok_r <= rst_n & clu_ok;

    // ------------------------------------------------------------ chip-wide registers
    reg [7:0] r_filter;                 // input glitch filter: [3:0] N, [7:4] P (docs/input_filter.md)
    always @(posedge clk) begin
        if (!rst_n) r_filter <= 8'd0;
        else if (h_wr && clu_ok_r && h_addr == 6'h29) r_filter <= h_wdata[7:0];   // whatever the engine field says
    end

    // ------------------------------------------------------------ pins as the engines see them (32 numbers)
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

    // the receiver's two samples bypass the glitch filter (a filter set for buses would swallow 50 ns pulses, and
    // receive must not depend on a setting shared by every pin). Rising edge: the synchronised pin (in_s2) and one
    // flip-flop in place of the filter's stage. Falling edge: the pad latched outside, then three flip-flops to match
    // in_s1, in_s2 and that stage. The engine then gets its two samples in time order, falling-edge one first.
    wire [31:0] pads = {12'd0, ui_in[7:3], 7'd0, uio_in};
    wire [4:0]  rx_pin;
    assign rx_pad = pads[rx_pin];
    reg  [2:0]  rx_al;
    always @(posedge clk) rx_al <= {rx_al[1:0], rx_fall};
    wire [31:0] pins_s2 = {12'd0, in_s2[12:8], 7'd0, in_s2[7:0]};
    reg         rx_rs;
    always @(posedge clk) rx_rs <= pins_s2[rx_pin];

    // ------------------------------------------------------------ the clusters
    wire [15:0] c_rdata [0:NCLUSTER-1];
    wire [31:0] c_val   [0:NCLUSTER-1];
    wire [31:0] c_drv   [0:NCLUSTER-1];
    wire        c_irq   [0:NCLUSTER-1];
    wire [4:0]  c_rxpin [0:NCLUSTER-1];

    genvar c;
    generate
        for (c = 0; c < NCLUSTER; c = c + 1) begin : clu
            reg sel_r;                  // this cluster is addressed (registered: see the cluster decode note above)
            always @(posedge clk) sel_r <= rst_n & (h_clu == c);
            cluster #(.NENG(NENG), .NSLOT(4), .NPIN(32), .TXDEPTH0(TXDEPTH0), .SER0(SER0), .CRC(CRC)) u (
                .clk(clk), .rst_n(rst_n),
                .wr(h_wr && sel_r), .pop(h_pop && sel_r), .eng(h_eng), .addr(h_addr), .wdata(h_wdata), .rdata(c_rdata[c]),
                .pins_in(pins_in), .out_val(c_val[c]), .out_dir(c_drv[c]), .irq(c_irq[c]),
                .rx_pin(c_rxpin[c]), .rx_fall(c == 0 ? rx_al[2] : 1'b0), .rx_rise(c == 0 ? rx_rs : 1'b0));
        end
    endgenerate

    // ------------------------------------------------------------ host reads
    reg [15:0] sel_rdata;               // the addressed cluster's word
    reg        any_rx;                  // IRQ: some engine's RX FIFO holds data
    integer m;
    always @(*) begin
        sel_rdata = 16'd0; any_rx = 1'b0;
        for (m = 0; m < NCLUSTER; m = m + 1) begin
            if (h_clu == m) sel_rdata = c_rdata[m];
            any_rx = any_rx | c_irq[m];
        end
        if (!clu_ok) h_rdata = 16'd0;
        else case (h_addr)
            6'h29:   h_rdata = {8'd0, r_filter};                  // chip-wide
            6'h2A:   h_rdata = {8'd0, 4'd2, NENG4};               // ID: [7:4] spec version 2, [3:0] engines
            default: h_rdata = sel_rdata;
        endcase
    end

    // ------------------------------------------------------------ cluster 0's pin bank to the chip pins (this package has one bank)
    assign rx_pin = c_rxpin[0];                 // the one pin bank's receiver is cluster 0's engine 0
    wire [31:0] drv = c_drv[0], val = c_val[0];
    assign uio_oe  = drv[7:0];
    assign uio_out = val[7:0] & drv[7:0];
    assign uo_out  = {val[13:8] & drv[13:8], any_rx, miso};

    wire _unused = &{ena, h_rd, ui_in[0], 1'b0};

endmodule
