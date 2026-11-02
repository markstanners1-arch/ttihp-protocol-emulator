// One protocol engine, built from docs/isa.md (v0.1).
// Checked against the Python model (model/engine.py) every system clock by model/cosim.py.
//
// In 74-series terms: a 16-bit clock divider, a 5-bit program counter, two 16-bit
// loadable down-counters (X, Y), two 16-bit shift registers (OSR out, ISR in) with bit counters,
// a 5-bit delay counter, a 16-bit stopwatch, two 4-word FIFOs, a 2-flip-flop synchroniser
// on every input, and a 32 x 16 program memory. One instruction per engine tick.

`timescale 1ns/1ps
`default_nettype none

module engine (
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

    // program memory write port
    input  wire        imem_we,
    input  wire [4:0]  imem_addr,
    input  wire [15:0] imem_wdata,

    // host side of the FIFOs
    input  wire        host_push,
    input  wire [15:0] host_push_data,
    input  wire        host_pop,
    output wire [15:0] host_pop_data,     // head of the RX FIFO
    output wire [2:0]  tx_level,
    output wire [2:0]  rx_level,

    // pins
    input  wire [31:0] pins_in,
    output reg  [31:0] out_val,
    output reg  [31:0] out_dir,

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

    reg [15:0] txm [0:3];           // TX FIFO: host -> engine
    reg [1:0]  tx_rd, tx_wr;
    reg [2:0]  tx_cnt;
    reg [15:0] rxm [0:3];           // RX FIFO: engine -> host
    reg [1:0]  rx_rd, rx_wr;
    reg [2:0]  rx_cnt;

    assign tx_level      = tx_cnt;
    assign rx_level      = rx_cnt;
    assign host_pop_data = rxm[rx_rd];
    wire   host_push_ok  = host_push && (tx_cnt != 3'd4);
    wire   host_pop_ok   = host_pop  && (rx_cnt != 3'd0);

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
    reg        tx_pop_eng, rx_push_eng;
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
        n_out_val = out_val; n_out_dir = out_dir;
        tx_pop_eng = 0; rx_push_eng = 0; rx_push_data = 0;
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
            default: in_data = 16'd0;
        endcase
        in_data = in_data & msk;
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
                    if (sync2[pidx] != a[7]) begin
                        if (a[6] && y == 16'd0) begin
                            do_jump = 1'b1; jaddr = cfg_fault_addr;
                        end else begin
                            if (a[6]) n_y = y - 16'd1;
                            stall = 1'b1;
                        end
                    end
                end
                3'd2: begin                                         // IN
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
                        end else if (tx_cnt == 3'd0) begin
                            if (a[5]) stall = 1'b1;
                            else begin n_osr = x; n_osr_count = 0; end
                        end else begin
                            tx_pop_eng = 1'b1;
                            n_osr = txm[tx_rd]; n_osr_count = 0;
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
                        3'd5: v = {8'd0, 1'b0, rx_cnt, 1'b0, tx_cnt};
                        3'd6: v = isr;
                        default: v = osr;
                    endcase
                    if (a[4:3] == 2'd1)      v = ~v;
                    else if (a[4:3] == 2'd2) v = bitrev16(v);
                    case (a[7:5])
                        3'd0: begin pw_en = 1'b1; pw_base = cfg_out_base; pw_count = cfg_out_count; pw_data = v; end
                        3'd1: n_x = v;
                        3'd2: n_y = v;
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
                        default: ;
                    endcase
                end
                endcase

                // the one shared pin writer
                pw_m = rotl32((32'd1 << pw_count) - 32'd1, pw_base);
                pw_d = rotl32({16'd0, pw_data}, pw_base);
                if (pw_en && !pw_dir) n_out_val = (out_val & ~pw_m) | (pw_d & pw_m);
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
            out_val <= 0; out_dir <= 0;
            div <= 0; sync1 <= 0; sync2 <= 0;
            tx_rd <= 0; tx_wr <= 0; tx_cnt <= 0;
            rx_rd <= 0; rx_wr <= 0; rx_cnt <= 0;
        end else begin
            // ---- registers
            pc <= n_pc; x <= n_x; y <= n_y;
            osr <= n_osr; osr_count <= n_osr_count;
            isr <= n_isr; isr_count <= n_isr_count;
            delay <= n_delay; sw <= n_sw; sw_run <= n_sw_run;
            out_val <= n_out_val; out_dir <= n_out_dir;
            div <= tick ? cfg_clkdiv : div - 16'd1;
            sync2 <= sync1; sync1 <= pins_in;

            // ---- FIFOs (host and engine can act in the same clock)
            if (host_push_ok) begin txm[tx_wr] <= host_push_data; tx_wr <= tx_wr + 2'd1; end
            if (tx_pop_eng)   tx_rd <= tx_rd + 2'd1;
            tx_cnt <= tx_cnt + {2'b0, host_push_ok} - {2'b0, tx_pop_eng};
            if (rx_push_eng)  begin rxm[rx_wr] <= rx_push_data; rx_wr <= rx_wr + 2'd1; end
            if (host_pop_ok)  rx_rd <= rx_rd + 2'd1;
            rx_cnt <= rx_cnt + {2'b0, rx_push_eng} - {2'b0, host_pop_ok};
        end
    end

endmodule
