// NE2000-compatible network card (DP8390 with the NE2000's remote DMA) at
// 300h, bridged to the MiSTer's network port through HPS DDR3.
//
// The DE10-Nano's FPGA cannot reach the board's Ethernet port; the ARM side
// can.  So the card keeps a small shared area in DDR3 at ARM address
// 0x3FF00000 (DDR word address 0x7FE0000) and a helper program on the MiSTer
// (c65_net, shared with the C65 core, which uses the same layout) moves frames
// between there and eth0:
//
//   +0x0000  word 0, written here:
//              [7:0] 0xE7 magic   [15:8] version 1   [23:16] rx_req   [31:24] rx_slot
//              [39:32] tx_seq     [51:40] tx_len     [63:56] flags: bit 0 running
//   +0x0008  word 1, written by the helper:
//              [7:0] rx_done      [15:8] tx_done     [23:16] 0xA5 while it runs
//   +0x0010  word 2, written here: [47:0] MAC (first byte in [7:0]),
//              [55:48] filter: bit 0 own address only, 4 broadcast, 5 multicast
//   +0x0800  TX frame (2K)
//   +0x1000  RX frame (slot 0; slots 1-3 unused here): bytes 0/1 the length
//              including the 4 CRC bytes (bits 10:0) and flags (bit 13 broadcast,
//              12 multicast), the frame from byte 2
//
// RX: while the ring has room for a full frame the card asks for one
// (rx_req + 1); the helper writes it and answers rx_done = rx_req; the card
// copies it into the receive ring with the DP8390's 4-byte header.  TX: the
// card copies the frame out of its buffer, publishes tx_seq + 1 and the length,
// and the helper answers tx_done = tx_seq.  Without a helper a frame still
// "goes out" after a timeout.
//
// The card's 16K of buffer RAM is at 4000h-7FFFh, the address PROM (each byte
// twice, 'WW' at 0Eh/0Fh: a 16-bit NE2000) at 0000h-001Fh.  The I/O bus here
// is byte-sequential, so a 16-bit IN/OUT on the data port arrives as two byte
// accesses at 10h and 11h: in word mode 10h moves the word (as any access
// does on the card, even an 8-bit one) and 11h carries its high byte.
//
// Peripheral reads are registered: io_read performs the side effect on the same
// edge that captures io_readdata.
module ne2000 #(
    parameter [47:0] MAC = 48'h02_4E_45_32_4B_01
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

localparam logic [28:0] BASE = 29'h7FE0000;

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
// port A remote DMA, port B the frame engines (one byte at a time)
logic        ram_we_b;
logic [13:0] ram_addr_b;
logic  [7:0] ram_d_b, ram_q_b;
logic        we_e_a, we_o_a;
logic [12:0] addr_a;
logic  [7:0] q_e_a, q_o_a, q_e_b, q_o_b;
logic        b_odd;

dpram #(.ADRW(13), .DATW(8)) ram_even (
    .clock     (clk),
    .wren_a    (we_e_a),
    .address_a (addr_a),
    .data_a    (io_writedata),
    .q_a       (q_e_a),
    .wren_b    (ram_we_b && !ram_addr_b[0]),
    .address_b (ram_addr_b[13:1]),
    .data_b    (ram_d_b),
    .q_b       (q_e_b)
);
dpram #(.ADRW(13), .DATW(8)) ram_odd (
    .clock     (clk),
    .wren_a    (we_o_a),
    .address_a (addr_a),
    .data_a    (io_writedata),
    .q_a       (q_o_a),
    .wren_b    (ram_we_b && ram_addr_b[0]),
    .address_b (ram_addr_b[13:1]),
    .data_b    (ram_d_b),
    .q_b       (q_o_b)
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

// ------------------------------------------------------------------ frame engines (DDR side)
localparam logic [2:0] D_IDLE = 3'd0, D_WAIT = 3'd1, D_WR = 3'd2, D_TXRD = 3'd3,
                       D_TXACC = 3'd4, D_RXBYTE = 3'd5, D_RXHDR = 3'd6;
logic  [2:0] dst;
logic  [1:0] dret;                // what D_WAIT returns to: 0 poll, 1 RX word
logic        init;                // the helper's word not read yet
logic        helper;              // 0xA5 seen
logic        pub0, pub2;
logic  [7:0] rx_req, rx_done, tx_seq, tx_done;
logic        rx_wait, rx_got;
logic        tx_start, tx_busy, tx_sent, tx_got, tx_copy;
logic [11:0] tx_len;
logic [21:0] tx_to;
logic [14:0] poll_cnt;
logic        last_running;
logic  [5:0] last_rcr;
logic        par_we;

// TX copy
logic [15:0] tx_ptr;
logic [11:0] tx_cnt, tx_i;
logic  [8:0] tx_lastw;            // index of the last TX word
wire  [11:0] tbcr_m1 = tbcr[11:0] - 12'd1;
logic [63:0] tx_word;

// RX copy
logic [63:0] rx_word;
logic [10:0] rx_bi;               // byte index in the slot
logic [10:0] rx_len;              // frame length including CRC
logic [10:0] rx_lim;              // rx_len + 2: end of the frame in the slot
logic  [1:0] rx_flags;            // {broadcast, multicast}
logic [15:0] rx_wp;               // ring write address
logic  [1:0] rx_hi;               // header byte
logic  [7:0] rx_next;

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
wire [10:0] rx_bi1   = rx_bi + 11'd1;
wire        rx_data  = rx_bi >= 11'd2 && rx_bi < rx_lim;

always_comb begin
    ram_we_b   = 1'b0;
    ram_addr_b = tx_ptr[13:0];
    ram_d_b    = rx_word[7:0];
    if (dst == D_RXBYTE) begin
        ram_addr_b = rx_wp[13:0];
        ram_d_b    = rx_word[{rx_bi[2:0], 3'b000} +: 8];
        ram_we_b   = rx_data && rx_wp[15:14] == 2'b01;
    end
    else if (dst == D_RXHDR) begin
        ram_addr_b = {curr[5:0], 6'd0, rx_hi};
        ram_we_b   = curr[7:6] == 2'b01;
        case (rx_hi)
            2'd0: ram_d_b = {2'b00, |rx_flags, 4'b0000, 1'b1};
            2'd1: ram_d_b = rx_next;
            2'd2: ram_d_b = rx_len[7:0];
            default: ram_d_b = {5'd0, rx_len[10:8]};
        endcase
    end
end

always_ff @(posedge clk) begin
    rx_got <= 1'b0;
    tx_got <= 1'b0;
    if (rst) begin
        dst <= D_IDLE; ddr_rd <= 1'b0; ddr_we <= 1'b0; ddr_be <= 8'hFF; ddr_din <= '0; ddr_addr <= BASE;
        init <= 1'b1; helper <= 1'b0; pub0 <= 1'b1; pub2 <= 1'b1; poll_cnt <= '0;
        rx_req <= 8'd0; rx_done <= 8'd0; tx_seq <= 8'd0; tx_done <= 8'd0;
        rx_wait <= 1'b0; tx_busy <= 1'b0; tx_sent <= 1'b0; tx_copy <= 1'b0; tx_len <= 12'd0; tx_to <= '0;
        last_running <= 1'b0; last_rcr <= '0;
    end
    else begin
        if (ddr_rd && !ddr_busy) ddr_rd <= 1'b0;
        if (ddr_we && !ddr_busy) ddr_we <= 1'b0;
        if (poll_cnt != 0) poll_cnt <= poll_cnt - 1'd1;
        // look for the helper's answer soon once something is pending
        if ((rx_wait || tx_busy) && poll_cnt > 15'd1023) poll_cnt <= 15'd1023;

        case (dst)
            D_IDLE:
                if (tx_busy && !tx_sent && !tx_copy) begin
                    // copy the frame out of the buffer into the TX area
                    tx_i <= 12'd0; tx_word <= '0; tx_copy <= 1'b1;
                    dst <= D_TXRD;
                end
                else if (rx_wait && rx_done == rx_req && !init) begin
                    rx_bi <= 11'd0;
                    ddr_addr <= BASE + 29'h200; ddr_rd <= 1'b1; dret <= 2'd1;
                    dst <= D_WAIT;
                end
                else if (pub0 && !init) begin
                    ddr_addr <= BASE; ddr_we <= 1'b1; ddr_be <= 8'hFF; pub0 <= 1'b0;
                    ddr_din <= {7'd0, running, 4'd0, tx_len, tx_seq, 8'd0, rx_req, 8'h01, 8'hE7};
                    dst <= D_WR;
                end
                else if (pub2 && !init) begin
                    ddr_addr <= BASE + 29'd2; ddr_we <= 1'b1; ddr_be <= 8'hFF; pub2 <= 1'b0;
                    ddr_din <= {8'd0, 2'b00, rcr[3], rcr[2], 3'b000, !rcr[4],
                                par[5], par[4], par[3], par[2], par[1], par[0]};
                    dst <= D_WR;
                end
                else if (poll_cnt == 0) begin
                    ddr_addr <= BASE + 29'd1; ddr_rd <= 1'b1; dret <= 2'd0;
                    poll_cnt <= (rx_wait || tx_busy) ? 15'd1023 : 15'h7FFF;
                    dst <= D_WAIT;
                end
                else if (running && helper && !rx_wait && ring_room) begin
                    rx_wait <= 1'b1; rx_req <= rx_req + 8'd1; pub0 <= 1'b1;
                end

            D_WAIT:
                if (!ddr_rd && ddr_dout_ready) begin
                    if (dret == 2'd1) begin
                        rx_word <= ddr_dout;
                        if (rx_bi == 11'd0) begin
                            rx_len   <= ddr_dout[10:0];
                            rx_lim   <= ddr_dout[10:0] + 11'd2;
                            rx_flags <= ddr_dout[13:12];
                            rx_wp    <= {curr, 8'd4};
                        end
                        dst <= D_RXBYTE;
                    end
                    else begin
                        helper <= ddr_dout[23:16] == 8'hA5;
                        if (init) begin
                            // carry on from whatever the helper last answered
                            rx_done <= ddr_dout[7:0]; rx_req <= ddr_dout[7:0];
                            tx_done <= ddr_dout[15:8]; tx_seq <= ddr_dout[15:8];
                            init <= 1'b0;
                        end
                        else begin
                            rx_done <= ddr_dout[7:0];
                            if (ddr_dout[15:8] != tx_done) begin tx_done <= ddr_dout[15:8]; tx_got <= 1'b1; end
                        end
                        dst <= D_IDLE;
                    end
                end

            D_WR:
                if (!ddr_we) dst <= tx_copy ? D_TXRD : D_IDLE;

            // ---- TX: one buffer byte per two cycles into tx_word, a DDR write per 8
            D_TXRD:
                dst <= D_TXACC;           // ram_q_b for tx_ptr next cycle
            // (whole words: the bytes after the frame are never sent)
            D_TXACC: begin
                tx_word <= {ram_q_b, tx_word[63:8]};
                tx_ptr  <= tx_ptr + 16'd1;
                tx_i    <= tx_i + 12'd1;
                if (tx_i[2:0] == 3'd7) begin
                    ddr_addr <= BASE + 29'h100 + {20'd0, tx_i[11:3]};
                    ddr_din  <= {ram_q_b, tx_word[63:8]}; ddr_be <= 8'hFF; ddr_we <= 1'b1;
                    if (tx_i[11:3] == tx_lastw) begin
                        tx_sent <= 1'b1; tx_copy <= 1'b0; tx_len <= tx_cnt; tx_seq <= tx_seq + 8'd1; pub0 <= 1'b1;
                    end
                    dst <= D_WR;
                end
                else dst <= D_TXRD;
            end

            // ---- RX: 8 bytes of the slot per DDR read
            D_RXBYTE: begin
                if (rx_data) rx_wp <= ring_inc(rx_wp, pstart, pstop);
                rx_bi <= rx_bi1;
                if (rx_bi == 11'd1 && (rx_len < 11'd8 || rx_len > 11'd1536)) begin
                    rx_wait <= 1'b0; dst <= D_IDLE;          // nonsense: drop it
                end
                else if (rx_bi1 >= rx_lim) begin
                    rx_hi <= 2'd0; rx_next <= rx_npage;
                    dst <= D_RXHDR;
                end
                else if (rx_bi[2:0] == 3'd7) begin
                    ddr_addr <= BASE + 29'h200 + {21'd0, rx_bi1[10:3]};
                    ddr_rd <= 1'b1; dret <= 2'd1;
                    dst <= D_WAIT;
                end
            end
            D_RXHDR: begin
                rx_hi <= rx_hi + 2'd1;
                if (rx_hi == 2'd3) begin
                    rx_wait <= 1'b0;
                    dst <= D_IDLE;
                end
            end
            default: dst <= D_IDLE;
        endcase

        if (tx_busy) begin
            tx_to <= tx_to + 1'd1;
            if (tx_sent && ((tx_got && tx_done == tx_seq) || (helper ? &tx_to : &tx_to[16:0]))) begin
                tx_busy <= 1'b0; tx_sent <= 1'b0;
            end
        end
        if (tx_start && !tx_busy) begin
            tx_busy <= 1'b1; tx_sent <= 1'b0; tx_to <= '0;
            tx_ptr  <= {tpsr, 8'd0};
            tx_cnt  <= (tbcr > 16'd2047) ? 12'd2047 : (tbcr == 16'd0) ? 12'd1 : tbcr[11:0];
            tx_lastw <= (tbcr > 16'd2047) ? 9'd255 : (tbcr == 16'd0) ? 9'd0 : tbcr_m1[11:3];
        end

        last_running <= running;
        last_rcr     <= rcr;
        if (running != last_running) pub0 <= 1'b1;
        if (rcr != last_rcr || par_we) pub2 <= 1'b1;
    end
end

// frame finished: ring update and completion flags, used by the register side
wire rx_done_ev = dst == D_RXHDR && rx_hi == 2'd3;
logic tx_busy_d;
wire tx_done_ev = tx_busy_d && !tx_busy;

// ------------------------------------------------------------------ CPU side
integer k;
always_ff @(posedge clk) begin
    tx_start <= 1'b0;
    par_we   <= 1'b0;
    tx_busy_d <= tx_busy;
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
            rsr    <= {2'b00, |rx_flags, 4'b0000, 1'b1};
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
                    4'h1, 4'h2, 4'h3, 4'h4, 4'h5, 4'h6: begin par[ra - 4'h1] <= io_writedata; par_we <= 1'b1; end
                    4'h7: curr <= io_writedata;
                    default: mar[ra[2:0]] <= io_writedata;
                endcase
                default: ;
            endcase
        end
    end
end

endmodule
