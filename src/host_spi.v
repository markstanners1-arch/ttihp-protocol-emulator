// SPI slave host port (docs/host_port.md). Mode 0, MSB first.
// A transaction: CS low, a 16-bit command ([15] read, [14:12] engine, [11:6] cluster, [5:0] register), then 16-bit words.
// (v0.2, 3 Nov 2026: the command grew from one byte to two to address up to eight engines.)
// SCK, CS and MOSI are sampled with the chip clock (2 flip-flop synchronisers), so the whole
// port runs in the chip's clock domain. SCK must be at most clk/8.
// MISO only ever changes just after a falling edge of SCK (SPI mode 0), so a host may sample it
// anywhere from the rising edge up to the next falling edge. (Found on the bench, 2 Nov 2026: the ESP32
// samples late; loading the next word just after a rising edge corrupted the last bit at low speeds.)
//
// Out to the chip: a simple register bus.
//   wr      one-clock pulse: write wdata to (eng, addr)
//   rd      one-clock pulse: load the word at (eng, addr) to send; rdata must be valid this clock (no side effects)
//   pop     one-clock pulse: the word at (eng, addr) has been fully sent; for the RX FIFO this pops it.
//           A word is only consumed once the host has clocked all 16 bits of it out.

`timescale 1ns/1ps
`default_nettype none

module host_spi (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cs_n,
    input  wire        sck,
    input  wire        mosi,
    output wire        miso,

    output reg         wr,
    output reg         rd,
    output reg         pop,
    output reg  [5:0]  clu,
    output reg  [2:0]  eng,
    output reg  [5:0]  addr,
    output reg  [15:0] wdata,
    input  wire [15:0] rdata
);

    localparam TXFIFO = 6'h26, RXFIFO = 6'h27;

    // synchronisers
    reg [2:0] cs_s, sck_s, mosi_s;
    always @(posedge clk) begin
        if (!rst_n) begin
            cs_s <= 3'b111; sck_s <= 3'b000; mosi_s <= 3'b000;
        end else begin
            cs_s <= {cs_s[1:0], cs_n}; sck_s <= {sck_s[1:0], sck}; mosi_s <= {mosi_s[1:0], mosi};
        end
    end
    wire cs_active = !cs_s[1];
    wire sck_rise  = (sck_s[2:1] == 2'b01);
    wire sck_fall  = (sck_s[2:1] == 2'b10);
    wire mosi_bit  = mosi_s[1];

    reg        in_cmd;        // 1 while the command word is coming in
    reg [3:0]  bitn;          // bits received in the current byte/word, minus 1 handled below
    reg [15:0] shin;          // incoming bits
    reg        is_read;
    reg [15:0] shout;         // outgoing bits, MSB on MISO
    reg        shift_ok;      // a falling edge may move MISO on (not the one straight after a load)
    reg        rd_next;       // load the next word one clock after a pop
    reg [15:0] nextw;         // the next word to send, waiting for a falling edge
    reg        have_next;

    assign miso = shout[15];

    wire [5:0] next_addr = (addr == TXFIFO || addr == RXFIFO) ? addr : addr + 6'd1;

    always @(posedge clk) begin
        wr <= 1'b0;
        rd <= rd_next;
        rd_next <= 1'b0;
        pop <= 1'b0;
        if (!rst_n || !cs_active) begin
            in_cmd <= 1'b1; bitn <= 4'd0; shin <= 16'd0; shout <= 16'd0; shift_ok <= 1'b0;
            rd <= 1'b0; rd_next <= 1'b0; have_next <= 1'b0; nextw <= 16'd0;
            if (!rst_n) begin is_read <= 1'b0; clu <= 6'd0; eng <= 3'd0; addr <= 6'd0; wdata <= 16'd0; end
        end else begin
            if (sck_rise) begin
                shin <= {shin[14:0], mosi_bit};
                bitn <= bitn + 4'd1;
                shift_ok <= 1'b1;
                if (in_cmd && bitn == 4'd15) begin
                    // 16-bit command complete: {read, engine[2:0], cluster[5:0], register[5:0]}
                    in_cmd  <= 1'b0;
                    bitn    <= 4'd0;
                    is_read <= shin[14];
                    eng     <= shin[13:11];
                    clu     <= shin[10:5];
                    addr    <= {shin[4:0], mosi_bit};
                    if (shin[14]) begin
                        rd <= 1'b1;                    // read the first word now (rdata next clock)
                    end
                    shift_ok <= 1'b0;
                end else if (!in_cmd && bitn == 4'd15) begin
                    // a 16-bit word complete
                    bitn <= 4'd0;
                    shift_ok <= 1'b0;
                    if (!is_read) begin
                        wr    <= 1'b1;
                        wdata <= {shin[14:0], mosi_bit};
                    end else begin
                        pop <= 1'b1;                   // the host now has this word: consume it
                        rd_next <= 1'b1;               // then load the next one
                    end
                end
            end
            if (wr || pop) addr <= next_addr;          // after a write or a completed read, move on
            if (rd) begin nextw <= rdata; have_next <= 1'b1; end   // fetched; goes out at the next falling edge
            if (sck_fall) begin
                if (have_next) begin shout <= nextw; have_next <= 1'b0; end
                else if (shift_ok) shout <= {shout[14:0], 1'b0};
            end
        end
    end

endmodule
