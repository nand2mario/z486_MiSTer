// SPDX-License-Identifier: GPL-2.0-or-later
// NE2000-compatible network card (DP8390 with the NE2000's remote DMA and
// 16K of buffer RAM) for MiSTer cores with an ISA-style I/O bus, bridged to
// the MiSTer's network port by netbridge.sv and the netbridge helper.
//
// Registers occupy 20h I/O ports (the usual base is 300h): 00h-0Fh the DP8390
// registers in pages selected by CR[7:6], 10h-17h the data port, 18h-1Fh the
// reset port. The buffer RAM is at 4000h-7FFFh in remote DMA space, the
// address PROM (each byte twice, 'WW' at 0Eh/0Fh: a 16-bit NE2000) at
// 0000h-001Fh.
//
// Bus: io_cs selects the card; io_read/io_write are one-cycle strobes, and
// io_readdata is registered on the io_read edge (the side effect, such as a
// data port advance, happens on that edge too). A 16-bit IN/OUT is two byte
// accesses at 10h then 11h: in word mode (DCR bit 0) the access at 10h moves
// the whole word, as every data port access does on the real card, even an
// 8-bit one, and 11h carries its high byte. Drivers such as the Crynwr
// NE2000 packet driver rely on that.
//
// irq is level, high while an enabled ISR bit is set.
module netbridge_ne2000 #(
    parameter [47:0] MAC  = 48'h02_4E_45_32_4B_01,  // default address, first byte in [47:40]
    parameter [28:0] BASE = 29'h7FE0000              // shared area (DDR word address)
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        enable,

    input  logic  [4:0] io_address,
    input  logic        io_read,
    input  logic        io_write,
    input  logic        io_cs,
    input  logic  [7:0] io_writedata,
    output logic  [7:0] io_readdata = 8'hff,
    output logic        irq,

    output logic [28:0] ddr_addr,
    output logic        ddr_rd,
    output logic        ddr_we,
    output logic [63:0] ddr_din,
    output logic  [7:0] ddr_be,
    input  logic        ddr_busy,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dout_ready
);

wire rst = reset || !enable;

// ------------------------------------------------------------------ registers
logic  [7:0] cr;                  // [7:6] page, [5:3] remote DMA, [2] TXP, [1] STA, [0] STP
logic  [7:0] pstart, pstop, bnry, tpsr, curr;
logic [15:0] tbcr;
logic  [7:0] isr;
logic  [6:0] imr;
logic  [5:0] rcr;
logic  [4:0] tcr;
logic  [6:0] dcr;
logic  [7:0] tsr, rsr;
logic  [7:0] par [0:5];
logic  [7:0] mar [0:7];
logic [15:0] raddr, rcnt;         // remote DMA address / byte count

wire  [1:0] page    = cr[7:6];
wire        running = cr[1] && !cr[0];

assign irq = enable && |(isr[6:0] & imr);

// buffer RAM, even and odd bytes in two banks so that a word is at hand:
// port A remote DMA, port B the bridge (one byte at a time)
logic        ram_we_b;
logic [13:0] ram_addr_b;
logic  [7:0] ram_d_b, ram_q_b;
logic        we_e_a, we_o_a;
logic [12:0] addr_a;
logic  [7:0] q_e_a, q_o_a, q_e_b, q_o_b;
logic        b_odd;

netbridge_dpram #(.AW(13)) ram_even (
    .clk(clk),
    .we_a(we_e_a), .addr_a(addr_a), .d_a(io_writedata), .q_a(q_e_a),
    .we_b(ram_we_b && !ram_addr_b[0]), .addr_b(ram_addr_b[13:1]), .d_b(ram_d_b), .q_b(q_e_b)
);
netbridge_dpram #(.AW(13)) ram_odd (
    .clk(clk),
    .we_a(we_o_a), .addr_a(addr_a), .d_a(io_writedata), .q_a(q_o_a),
    .we_b(ram_we_b && ram_addr_b[0]), .addr_b(ram_addr_b[13:1]), .d_b(ram_d_b), .q_b(q_o_b)
);
always_ff @(posedge clk) b_odd <= ram_addr_b[0];
assign ram_q_b = b_odd ? q_o_b : q_e_b;

function automatic [7:0] prom(input [4:0] a);
    case (a[4:1])
        4'd0: prom = MAC[47:40];
        4'd1: prom = MAC[39:32];
        4'd2: prom = MAC[31:24];
        4'd3: prom = MAC[23:16];
        4'd4: prom = MAC[15:8];
        4'd5: prom = MAC[7:0];
        4'd7: prom = 8'h57;
        default: prom = 8'h00;
    endcase
endfunction

// Remote DMA data: raddr has been stable for at least two cycles. In word
// mode (DCR bit 0) every data port access moves a word, as on the card, even
// an 8-bit IN or OUT; the high byte of a 16-bit one follows at 11h.
wire        wmode  = dcr[0];
wire        r_ram  = raddr[15:14] == 2'b01;
wire        r_prom = raddr[15:5] == 11'd0;
wire  [7:0] dp_e   = r_ram ? q_e_a : r_prom ? prom({raddr[4:1], 1'b0}) : 8'hff;
wire  [7:0] dp_o   = r_ram ? q_o_a : r_prom ? prom({raddr[4:1], 1'b1}) : 8'hff;
wire  [7:0] dp_q   = (raddr[0] && !wmode) ? dp_o : dp_e;
logic  [7:0] dp_hi;               // word mode: the high byte for 11h
logic [12:0] hi_waddr;            // word mode: where a write at 11h goes
logic        hi_wram;

wire io_rd    = io_read  && io_cs;
wire io_wr    = io_write && io_cs;
wire dp_sel   = io_address[4:3] == 2'b10;      // 10h-17h data port
wire rst_sel  = io_address[4:3] == 2'b11;      // 18h-1Fh reset port
wire reg_sel  = !io_address[4];
wire [3:0] ra = io_address[3:0];

wire dp_hi_acc = wmode && io_address[0];      // 11h in word mode: the high byte
assign addr_a  = (io_wr && dp_sel && dp_hi_acc) ? hi_waddr : raddr[13:1];
assign we_e_a  = io_wr && dp_sel && !dp_hi_acc && r_ram && (wmode || !raddr[0]);
assign we_o_a  = io_wr && dp_sel && (dp_hi_acc ? hi_wram : (r_ram && !wmode && raddr[0]));

function automatic [15:0] ring_inc2(input [15:0] a, input [7:0] ps, input [7:0] pe);
    logic [15:0] n;
    n = a + 16'd2;
    if (n[7:0] == 8'd0 && n[15:8] == pe) n = {ps, 8'd0};
    ring_inc2 = n;
endfunction

logic [7:0] reg_q;
always_comb begin
    logic [7:0] r;
    r = 8'h00;
    if (ra == 4'h0) r = cr;
    else case (page)
        2'd0: case (ra)
            4'h3: r = bnry;
            4'h4: r = tsr;
            4'h7: r = isr;
            4'h8: r = raddr[7:0];
            4'h9: r = raddr[15:8];
            4'hA: r = 8'h50;
            4'hB: r = 8'h43;
            4'hC: r = rsr;
            default: r = 8'h00;
        endcase
        2'd1: case (ra)
            4'h1, 4'h2, 4'h3, 4'h4, 4'h5, 4'h6: r = par[ra - 4'h1];
            4'h7: r = curr;
            default: r = mar[ra[2:0]];
        endcase
        2'd2: case (ra)
            4'h1: r = pstart;
            4'h2: r = pstop;
            4'h3: r = curr;
            4'h4: r = tpsr;
            4'h5: r = curr;
            4'hC: r = {2'b11, rcr};
            4'hD: r = {3'b111, tcr};
            4'hE: r = {1'b1, dcr};
            4'hF: r = {1'b1, imr};
            default: r = 8'h00;
        endcase
        default: r = 8'h00;
    endcase
    reg_q = r;
end

// ------------------------------------------------------------------ the bridge
logic        tx_start, tx_busy, tx_done, tx_rd;
logic [10:0] tx_addr;
logic        rx_start, rx_bcast, rx_mcast, rx_we, rx_end;
logic [10:0] rx_len, rx_addr;
logic  [7:0] rx_data;
logic        hdr_act;              // writing the 4-byte ring header
logic  [1:0] hdr_i;
logic [15:0] rx_wp;                // ring write address
logic  [7:0] rx_next;              // the page after the frame

wire  [7:0] ring_pages = pstop - pstart;
wire  [7:0] avail      = (bnry > curr) ? bnry - curr : ring_pages - (curr - bnry);
wire        ring_room  = avail >= 8'd7;

function automatic [15:0] ring_inc(input [15:0] a, input [7:0] ps, input [7:0] pe);
    logic [15:0] n;
    n = a + 16'd1;
    if (n[7:0] == 8'd0 && n[15:8] == pe) n = {ps, 8'd0};
    ring_inc = n;
endfunction

wire [11:0] rx_tot   = {1'b0, rx_len} + 12'd4 + 12'd255;
wire  [8:0] rx_nsum  = {1'b0, curr} + {5'd0, rx_tot[11:8]};
wire  [8:0] rx_nwrap = rx_nsum - {1'b0, pstop} + {1'b0, pstart};
wire  [7:0] rx_npage = (rx_nsum >= {1'b0, pstop}) ? rx_nwrap[7:0] : rx_nsum[7:0];
wire  [5:0] tx_page  = tpsr[5:0] + {3'd0, tx_addr[10:8]};
wire [10:0] tx_len   = (tbcr > 16'd2047) ? 11'd2047 : tbcr[10:0];

netbridge #(.BASE(BASE)) bridge (
    .clk(clk), .reset(rst),
    .running(running),
    .mac({par[0], par[1], par[2], par[3], par[4], par[5]}),
    .filter({2'b00, rcr[3], rcr[2], 3'b000, !rcr[4]}),
    .helper(),
    .tx_start(tx_start), .tx_len(tx_len),
    .tx_busy(tx_busy), .tx_done(tx_done), .tx_rd(tx_rd), .tx_addr(tx_addr), .tx_data(ram_q_b),
    .rx_ready(ring_room), .hold(rx_end || hdr_act),
    .rx_start(rx_start), .rx_len(rx_len), .rx_bcast(rx_bcast), .rx_mcast(rx_mcast),
    .rx_we(rx_we), .rx_addr(rx_addr), .rx_data(rx_data), .rx_end(rx_end),
    .ddr_addr(ddr_addr), .ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_din(ddr_din), .ddr_be(ddr_be),
    .ddr_busy(ddr_busy), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready)
);

always_comb begin
    ram_we_b   = 1'b0;
    ram_addr_b = {tx_page, tx_addr[7:0]};
    ram_d_b    = rx_data;
    if (rx_we) begin
        ram_addr_b = rx_wp[13:0];
        ram_we_b   = rx_wp[15:14] == 2'b01;
    end
    else if (hdr_act) begin
        ram_addr_b = {curr[5:0], 6'd0, hdr_i};
        ram_we_b   = curr[7:6] == 2'b01;
        case (hdr_i)
            2'd0: ram_d_b = {2'b00, rx_bcast | rx_mcast, 4'b0000, 1'b1};
            2'd1: ram_d_b = rx_next;
            2'd2: ram_d_b = rx_len[7:0];
            default: ram_d_b = {5'd0, rx_len[10:8]};
        endcase
    end
end

always_ff @(posedge clk) begin
    if (rst) begin
        hdr_act <= 1'b0; hdr_i <= 2'd0; rx_wp <= 16'd0; rx_next <= 8'd0;
    end
    else begin
        if (rx_start) begin
            rx_wp   <= {curr, 8'd4};
            rx_next <= rx_npage;
        end
        if (rx_we) rx_wp <= ring_inc(rx_wp, pstart, pstop);
        if (rx_end) begin hdr_act <= 1'b1; hdr_i <= 2'd0; end
        else if (hdr_act) begin
            hdr_i <= hdr_i + 2'd1;
            if (hdr_i == 2'd3) hdr_act <= 1'b0;
        end
    end
end

// frame finished: ring update and completion flags, used by the register side
wire rx_done_ev = hdr_act && hdr_i == 2'd3;
wire tx_done_ev = tx_done;

// ------------------------------------------------------------------ CPU side
integer k;
always_ff @(posedge clk) begin
    tx_start <= 1'b0;
    if (rst) begin
        cr <= 8'h21; isr <= 8'h80; imr <= 7'd0; rcr <= 6'd0; tcr <= 5'd0; dcr <= 7'd0;
        pstart <= 8'h46; pstop <= 8'h80; bnry <= 8'h46; curr <= 8'h47; tpsr <= 8'h40;
        tbcr <= 16'd0; tsr <= 8'd0; rsr <= 8'd0; raddr <= 16'd0; rcnt <= 16'd0;
        par[0] <= MAC[47:40]; par[1] <= MAC[39:32]; par[2] <= MAC[31:24];
        par[3] <= MAC[23:16]; par[4] <= MAC[15:8];  par[5] <= MAC[7:0];
        for (k = 0; k < 8; k = k + 1) mar[k] <= 8'h00;
        io_readdata <= 8'hff;
    end
    else begin
        if (rx_done_ev) begin
            curr   <= rx_next;
            rsr    <= {2'b00, rx_bcast | rx_mcast, 4'b0000, 1'b1};
            isr[0] <= 1'b1;
        end
        if (tx_done_ev) begin
            tsr    <= 8'h01;
            isr[1] <= 1'b1;
            cr[2]  <= 1'b0;
        end

        if (io_rd) begin
            if (dp_sel && dp_hi_acc) io_readdata <= dp_hi;
            else if (dp_sel && wmode) begin
                io_readdata <= dp_e; dp_hi <= dp_o;
                raddr <= ring_inc2(raddr, pstart, pstop);
                rcnt  <= (rcnt <= 16'd2) ? 16'd0 : rcnt - 16'd2;
                if (rcnt != 16'd0 && rcnt <= 16'd2) isr[6] <= 1'b1;
            end
            else if (dp_sel) begin
                io_readdata <= dp_q;
                raddr <= ring_inc(raddr, pstart, pstop);
                rcnt  <= rcnt - 16'd1;
                if (rcnt == 16'd1) isr[6] <= 1'b1;
            end
            else if (rst_sel) begin
                io_readdata <= 8'hff;
                cr <= 8'h21; isr[7] <= 1'b1;
            end
            else io_readdata <= reg_q;
        end

        if (io_wr) begin
            if (dp_sel && dp_hi_acc) ;
            else if (dp_sel && wmode) begin
                hi_waddr <= raddr[13:1]; hi_wram <= r_ram;
                raddr <= ring_inc2(raddr, pstart, pstop);
                rcnt  <= (rcnt <= 16'd2) ? 16'd0 : rcnt - 16'd2;
                if (rcnt != 16'd0 && rcnt <= 16'd2) isr[6] <= 1'b1;
            end
            else if (dp_sel) begin
                raddr <= ring_inc(raddr, pstart, pstop);
                rcnt  <= rcnt - 16'd1;
                if (rcnt == 16'd1) isr[6] <= 1'b1;
            end
            else if (rst_sel) begin
                cr <= 8'h21; isr[7] <= 1'b1;
            end
            else if (ra == 4'h0) begin
                cr[7:6] <= io_writedata[7:6];
                cr[5:3] <= io_writedata[5] ? 3'b100 : io_writedata[5:3];
                if (io_writedata[0]) begin
                    cr[1:0] <= 2'b01; isr[7] <= 1'b1;
                end
                else if (io_writedata[1]) begin
                    cr[1:0] <= 2'b10; isr[7] <= 1'b0;
                end
                if (io_writedata[2] && !io_writedata[0] && !tx_busy) begin
                    cr[2] <= 1'b1; tx_start <= 1'b1;
                end
                // remote DMA of zero bytes completes at once
                if (!io_writedata[5] && io_writedata[4:3] != 2'b00 && rcnt == 16'd0) isr[6] <= 1'b1;
            end
            else case (page)
                2'd0: case (ra)
                    4'h1: pstart <= io_writedata;
                    4'h2: pstop  <= io_writedata;
                    4'h3: bnry   <= io_writedata;
                    4'h4: tpsr   <= io_writedata;
                    4'h5: tbcr[7:0]  <= io_writedata;
                    4'h6: tbcr[15:8] <= io_writedata;
                    4'h7: isr[6:0] <= isr[6:0] & ~io_writedata[6:0];
                    4'h8: raddr[7:0]  <= io_writedata;
                    4'h9: raddr[15:8] <= io_writedata;
                    4'hA: rcnt[7:0]  <= io_writedata;
                    4'hB: rcnt[15:8] <= io_writedata;
                    4'hC: rcr <= io_writedata[5:0];
                    4'hD: tcr <= io_writedata[4:0];
                    4'hE: dcr <= io_writedata[6:0];
                    4'hF: imr <= io_writedata[6:0];
                    default: ;
                endcase
                2'd1: case (ra)
                    4'h1, 4'h2, 4'h3, 4'h4, 4'h5, 4'h6: begin par[ra - 4'h1] <= io_writedata; end
                    4'h7: curr <= io_writedata;
                    default: mar[ra[2:0]] <= io_writedata;
                endcase
                default: ;
            endcase
        end
    end
end

endmodule
