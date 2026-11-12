// SPDX-License-Identifier: GPL-2.0-or-later
// MiSTer NetBridge: the FPGA side of a network card on a MiSTer core.
//
// The DE10-Nano's FPGA has no network port; the ARM side (the MiSTer's Linux)
// has. This module keeps a small shared area in HPS DDR3 and the netbridge
// helper on the ARM side moves Ethernet frames between it and eth0. See
// docs/PROTOCOL.md for the layout and the handshake.
//
// The NIC model (an NE2000, a MEGA65 controller, anything with a frame
// buffer) talks to this module through two byte streams:
//
//   transmit: pulse tx_start with tx_len; the bridge reads the frame byte by
//     byte (tx_rd/tx_addr, tx_data one cycle later, as from a block RAM with a
//     registered output) and pulses tx_done once the helper has sent it, or
//     after a timeout if there is no helper.
//   receive: while rx_ready (room for a whole frame, 1536 + 4 bytes) the
//     bridge asks the helper for a frame; rx_start gives its length and kind,
//     then rx_we delivers it a byte per cycle (CRC included), then rx_end.
//     The NIC must take a byte on every cycle rx_we is high.
//
// The bridge starts no TX copy and no RX frame while `hold` is high, so the NIC
// can use its buffer port (for example to write a ring header) right after
// rx_end: hold must already be high in the cycle rx_end is.
//
// DDR side: the MiSTer DDRAM_* interface (64-bit words, word addresses), one
// word per request (burst count 1). Use netbridge_ddram_arb.sv to share the
// port with a core's own DDR traffic.
module netbridge #(
    parameter [28:0] BASE      = 29'h7FE0000,  // DDR word address of the area (ARM 0x3FF00000)
    parameter [14:0] POLL_IDLE = 15'h7FFF,     // cycles between polls when idle
    parameter [14:0] POLL_BUSY = 15'd1023,     // ... while a frame is in flight
    parameter        TX_TO_BITS = 22           // TX timeout 2^n cycles with a helper (2^17 without)
) (
    input  logic        clk,
    input  logic        reset,

    // NIC state
    input  logic        running,               // the NIC is started (frames flow)
    input  logic [47:0] mac,                   // own address, mac[47:40] first on the wire
    input  logic  [7:0] filter,                // bit 0 own address only (else everything),
                                               // bit 4 broadcast too, bit 5 multicast too
    output logic        helper,                // the helper answers

    // transmit
    input  logic        tx_start,              // pulse, tx_len valid
    input  logic [10:0] tx_len,                // bytes, 1-2047, without CRC
    output logic        tx_busy,
    output logic        tx_done,               // pulse
    output logic        tx_rd,                 // the bridge is reading tx_addr
    output logic [10:0] tx_addr,
    input  logic  [7:0] tx_data,               // byte at tx_addr, one cycle after tx_rd

    // receive
    input  logic        rx_ready,
    input  logic        hold,
    output logic        rx_start,              // pulse: rx_len, rx_bcast, rx_mcast valid
    output logic [10:0] rx_len,                // bytes including the 4 CRC bytes
    output logic        rx_bcast,
    output logic        rx_mcast,
    output logic        rx_we,
    output logic [10:0] rx_addr,               // 0 = first byte of the frame
    output logic  [7:0] rx_data,
    output logic        rx_end,                // pulse: the whole frame is delivered

    // DDR (DDRAM_* style, burst count 1)
    output logic [28:0] ddr_addr,
    output logic        ddr_rd,
    output logic        ddr_we,
    output logic [63:0] ddr_din,
    output logic  [7:0] ddr_be,
    input  logic        ddr_busy,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dout_ready
);

localparam [7:0]  VERSION = 8'd2;
localparam [55:0] SIG     = 56'h74_65_4E_54_53_69_4D;    // "MiSTNet", 'M' first

localparam [2:0] D_IDLE = 3'd0, D_WAIT = 3'd1, D_WR = 3'd2, D_TXRD = 3'd3,
                 D_TXACC = 3'd4, D_RXBYTE = 3'd5;
logic  [2:0] dst;
logic        dret;                 // D_WAIT for: 0 the helper's word, 1 RX data
logic        init;                 // the helper's word not read yet
logic        pub0, pub2, beat;     // words to write: state, MAC/filter, heartbeat
logic  [7:0] hb;
logic  [7:0] rx_req, rx_done, tx_seq, tx_ack;
logic        rx_wait, tx_copy, tx_sent, tx_got;
logic [10:0] tx_n;                 // frame length
logic  [7:0] tx_lastw;             // index of the last TX word
logic [TX_TO_BITS-1:0] tx_to;
logic [14:0] poll_cnt;
logic        last_running;
logic [47:0] last_mac;
logic  [7:0] last_filter;

logic [63:0] tx_word;
logic [10:0] tx_i;
logic [63:0] rx_word;
logic [10:0] rx_bi;                // byte index in the slot (2 = first frame byte)
logic [10:0] rx_lim;               // rx_len + 2

wire  [10:0] rx_bi1  = rx_bi + 11'd1;
wire         rx_byte = rx_bi >= 11'd2 && rx_bi < rx_lim;
wire  [10:0] tx_m1   = tx_len - 11'd1;

assign tx_rd   = dst == D_TXRD;
assign tx_addr = tx_i;
assign rx_we   = dst == D_RXBYTE && rx_byte;
assign rx_addr = rx_bi - 11'd2;
assign rx_data = rx_word[{rx_bi[2:0], 3'b000} +: 8];

always_ff @(posedge clk) begin
    rx_start <= 1'b0;
    rx_end   <= 1'b0;
    tx_done  <= 1'b0;
    tx_got   <= 1'b0;
    if (reset) begin
        dst <= D_IDLE; ddr_rd <= 1'b0; ddr_we <= 1'b0; ddr_be <= 8'hFF; ddr_din <= '0; ddr_addr <= BASE;
        init <= 1'b1; helper <= 1'b0; pub0 <= 1'b1; pub2 <= 1'b1; beat <= 1'b0; hb <= 8'd0;
        poll_cnt <= '0; rx_req <= 8'd0; rx_done <= 8'd0; tx_seq <= 8'd0; tx_ack <= 8'd0;
        rx_wait <= 1'b0; tx_busy <= 1'b0; tx_copy <= 1'b0; tx_sent <= 1'b0; tx_n <= 11'd0; tx_to <= '0;
        last_running <= 1'b0; last_mac <= '0; last_filter <= '0;
        rx_len <= 11'd0; rx_bcast <= 1'b0; rx_mcast <= 1'b0;
    end
    else begin
        if (ddr_rd && !ddr_busy) ddr_rd <= 1'b0;
        if (ddr_we && !ddr_busy) ddr_we <= 1'b0;
        if (poll_cnt != 0) poll_cnt <= poll_cnt - 1'd1;
        // look for the helper's answer soon while something is pending
        if ((rx_wait || tx_busy) && poll_cnt > POLL_BUSY) poll_cnt <= POLL_BUSY;

        case (dst)
            D_IDLE:
                if (tx_busy && !tx_sent && !tx_copy && !hold) begin
                    // copy the frame into the TX area, whole words
                    tx_i <= 11'd0; tx_word <= '0; tx_copy <= 1'b1;
                    dst <= D_TXRD;
                end
                else if (rx_wait && rx_done == rx_req && !init && !hold) begin
                    rx_bi <= 11'd0;
                    ddr_addr <= BASE + 29'h200; ddr_rd <= 1'b1; dret <= 1'b1;
                    dst <= D_WAIT;
                end
                else if (pub0 && !init) begin
                    ddr_addr <= BASE; ddr_we <= 1'b1; ddr_be <= 8'hFF; pub0 <= 1'b0;
                    ddr_din <= {7'd0, running, 5'd0, tx_n, tx_seq, 8'd0, rx_req, VERSION, 8'hE7};
                    dst <= D_WR;
                end
                else if (pub2 && !init) begin
                    ddr_addr <= BASE + 29'd2; ddr_we <= 1'b1; ddr_be <= 8'hFF; pub2 <= 1'b0;
                    ddr_din <= {8'd0, filter, mac[7:0], mac[15:8], mac[23:16], mac[31:24], mac[39:32], mac[47:40]};
                    dst <= D_WR;
                end
                else if (poll_cnt == 0 && !beat && !init) begin
                    // heartbeat: the helper only serves an area whose signature keeps changing
                    ddr_addr <= BASE + 29'd3; ddr_we <= 1'b1; ddr_be <= 8'hFF; beat <= 1'b1;
                    ddr_din <= {hb + 8'd1, SIG}; hb <= hb + 8'd1;
                    dst <= D_WR;
                end
                else if (poll_cnt == 0) begin
                    ddr_addr <= BASE + 29'd1; ddr_rd <= 1'b1; dret <= 1'b0; beat <= 1'b0;
                    poll_cnt <= (rx_wait || tx_busy) ? POLL_BUSY : POLL_IDLE;
                    dst <= D_WAIT;
                end
                else if (running && helper && rx_ready && !rx_wait) begin
                    rx_wait <= 1'b1; rx_req <= rx_req + 8'd1; pub0 <= 1'b1;
                end

            D_WAIT:
                if (!ddr_rd && ddr_dout_ready) begin
                    if (dret) begin
                        rx_word <= ddr_dout;
                        if (rx_bi == 11'd0) begin
                            if (ddr_dout[10:0] < 11'd8 || ddr_dout[10:0] > 11'd1536) begin
                                rx_wait <= 1'b0; dst <= D_IDLE;       // nonsense: drop it
                            end
                            else begin
                                rx_len   <= ddr_dout[10:0];
                                rx_lim   <= ddr_dout[10:0] + 11'd2;
                                rx_bcast <= ddr_dout[13];
                                rx_mcast <= ddr_dout[12];
                                rx_start <= 1'b1;
                                dst <= D_RXBYTE;
                            end
                        end
                        else dst <= D_RXBYTE;
                    end
                    else begin
                        helper <= ddr_dout[23:16] == 8'hA5;
                        if (init) begin
                            // carry on from whatever the helper last answered
                            rx_done <= ddr_dout[7:0];  rx_req <= ddr_dout[7:0];
                            tx_ack  <= ddr_dout[15:8]; tx_seq <= ddr_dout[15:8];
                            init <= 1'b0;
                        end
                        else begin
                            rx_done <= ddr_dout[7:0];
                            if (ddr_dout[15:8] != tx_ack) begin tx_ack <= ddr_dout[15:8]; tx_got <= 1'b1; end
                        end
                        dst <= D_IDLE;
                    end
                end

            D_WR:
                if (!ddr_we) dst <= tx_copy ? D_TXRD : D_IDLE;

            // ---- TX: a byte per two cycles into tx_word, a DDR write per 8
            D_TXRD:
                dst <= D_TXACC;
            D_TXACC: begin
                tx_word <= {tx_data, tx_word[63:8]};
                tx_i    <= tx_i + 11'd1;
                if (tx_i[2:0] == 3'd7) begin
                    ddr_addr <= BASE + 29'h100 + {21'd0, tx_i[10:3]};
                    ddr_din  <= {tx_data, tx_word[63:8]}; ddr_be <= 8'hFF; ddr_we <= 1'b1;
                    if (tx_i[10:3] == tx_lastw) begin
                        tx_sent <= 1'b1; tx_copy <= 1'b0; tx_seq <= tx_seq + 8'd1; pub0 <= 1'b1;
                    end
                    dst <= D_WR;
                end
                else dst <= D_TXRD;
            end

            // ---- RX: 8 bytes of the slot per DDR read
            D_RXBYTE: begin
                rx_bi <= rx_bi1;
                if (rx_bi1 >= rx_lim) begin
                    rx_wait <= 1'b0; rx_end <= 1'b1;
                    dst <= D_IDLE;
                end
                else if (rx_bi[2:0] == 3'd7) begin
                    ddr_addr <= BASE + 29'h200 + {21'd0, rx_bi1[10:3]};
                    ddr_rd <= 1'b1; dret <= 1'b1;
                    dst <= D_WAIT;
                end
            end
            default: dst <= D_IDLE;
        endcase

        if (tx_busy) begin
            tx_to <= tx_to + 1'd1;
            if (tx_sent && ((tx_got && tx_ack == tx_seq) || (helper ? &tx_to : &tx_to[16:0]))) begin
                tx_busy <= 1'b0; tx_sent <= 1'b0; tx_done <= 1'b1;
            end
        end
        if (tx_start && !tx_busy) begin
            tx_busy <= 1'b1; tx_sent <= 1'b0; tx_to <= '0;
            tx_n     <= (tx_len == 11'd0) ? 11'd1 : tx_len;
            tx_lastw <= (tx_len == 11'd0) ? 8'd0 : tx_m1[10:3];
        end

        last_running <= running;
        last_mac     <= mac;
        last_filter  <= filter;
        if (running != last_running) pub0 <= 1'b1;
        if (mac != last_mac || filter != last_filter) pub2 <= 1'b1;
    end
end

endmodule
