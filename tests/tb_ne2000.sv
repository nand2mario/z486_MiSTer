// SPDX-License-Identifier: GPL-2.0-or-later
// netbridge_ne2000 + netbridge + netbridge_ddram_arb against a DDR model with
// bursts, a model of the netbridge helper (protocol version 2: it serves the
// area only while the signature is there and the heartbeat moves), and a
// second DDR master doing burst writes and reads that must not be disturbed.
//
// Checks: the PROM in byte and word reads, remote DMA, a transmitted frame,
// PTX and the interrupt, and 40 received frames of assorted lengths read
// around the receive ring several times.
`timescale 1ns/1ns
module tb_ne2000;

logic clk = 0, reset = 1;
always #5 clk = ~clk;

logic  [4:0] io_address;
logic        io_read = 0, io_write = 0, io_cs = 0;
logic  [7:0] io_writedata, io_readdata;
logic        irq;

// NIC side of the arbiter
logic [28:0] b_addr;
logic        b_rd, b_we, b_busy, b_dout_ready;
logic [63:0] b_din;
logic  [7:0] b_be;
// core side
logic [28:0] a_addr = 0;
logic  [7:0] a_burstcnt = 1;
logic        a_rd = 0, a_we = 0, a_busy, a_dout_ready;
logic [63:0] a_din = 0;
logic  [7:0] a_be = 8'hFF;
// DDR
logic [28:0] ddr_addr;
logic  [7:0] ddr_burstcnt, ddr_be;
logic        ddr_rd, ddr_we;
logic [63:0] ddr_din, ddr_dout;
logic        ddr_busy = 0, ddr_dout_ready = 0;

netbridge_ne2000 dut (
    .clk(clk), .reset(reset), .enable(1'b1),
    .io_address(io_address), .io_read(io_read), .io_write(io_write), .io_cs(io_cs),
    .io_writedata(io_writedata), .io_readdata(io_readdata), .irq(irq),
    .ddr_addr(b_addr), .ddr_rd(b_rd), .ddr_we(b_we), .ddr_din(b_din), .ddr_be(b_be),
    .ddr_busy(b_busy), .ddr_dout(ddr_dout), .ddr_dout_ready(b_dout_ready)
);

netbridge_ddram_arb arb (
    .clk(clk), .reset(reset),
    .a_addr(a_addr), .a_burstcnt(a_burstcnt), .a_rd(a_rd), .a_we(a_we), .a_din(a_din), .a_be(a_be),
    .a_busy(a_busy), .a_dout_ready(a_dout_ready),
    .b_addr(b_addr), .b_rd(b_rd), .b_we(b_we), .b_din(b_din), .b_be(b_be),
    .b_busy(b_busy), .b_dout_ready(b_dout_ready),
    .ddr_addr(ddr_addr), .ddr_burstcnt(ddr_burstcnt), .ddr_rd(ddr_rd), .ddr_we(ddr_we),
    .ddr_din(ddr_din), .ddr_be(ddr_be), .ddr_busy(ddr_busy), .ddr_dout_ready(ddr_dout_ready)
);

// ---------------------------------------------------------------- DDR model (bursts)
localparam [28:0] BASE = 29'h7FE0000;    // shared area
localparam [28:0] ABASE = 29'h1000000;   // the other master's region
localparam integer NSHM = 'h600, NA = 'h1000;
logic [63:0] mem [0:NSHM + NA - 1];
integer seed = 1;

function automatic integer idx(input [28:0] a);
    if (a >= BASE && a < BASE + NSHM) idx = a - BASE;
    else if (a >= ABASE && a < ABASE + NA) idx = NSHM + (a - ABASE);
    else begin $display("FAIL DDR access outside the model at %h", a); idx = 0; end
endfunction

integer wr_rem = 0, wr_idx;
integer rq [0:1023];
integer rq_h = 0, rq_n = 0;

always @(posedge clk) begin
    ddr_dout_ready <= 0;
    ddr_busy <= ($random(seed) & 3) == 0;
    if (!ddr_busy && ddr_we) begin
        if (wr_rem == 0) begin wr_idx = idx(ddr_addr); wr_rem = ddr_burstcnt; end
        for (int b = 0; b < 8; b++)
            if (ddr_be[b]) mem[wr_idx][8*b +: 8] <= ddr_din[8*b +: 8];
        wr_idx++; wr_rem--;
    end
    if (!ddr_busy && ddr_rd) begin
        if (wr_rem != 0) $display("FAIL read inside a write burst");
        for (int i = 0; i < ddr_burstcnt; i++) begin
            rq[(rq_h + rq_n) % 1024] = idx(ddr_addr) + i; rq_n++;
        end
    end
    else if (rq_n > 0 && ($random(seed) % 4) != 0) begin
        ddr_dout <= mem[rq[rq_h]]; ddr_dout_ready <= 1;
        rq_h = (rq_h + 1) % 1024; rq_n--;
    end
end

function automatic [7:0] sb(input integer a); sb = mem[a >> 3][8*(a & 7) +: 8]; endfunction
task automatic wb(input integer a, input [7:0] v); mem[a >> 3][8*(a & 7) +: 8] = v; endtask

// ---------------------------------------------------------------- helper model
logic [7:0] txf [0:2047];
integer     txlen = -1;
logic [7:0] rxq [0:63][0:1599];
integer     rxqlen [0:63];
integer     rxq_head = 0, rxq_n = 0;
integer     beats = 0;

function automatic bit sig_ok();
    sig_ok = sb('h18) == "M" && sb('h19) == "i" && sb('h1A) == "S" && sb('h1B) == "T" &&
             sb('h1C) == "N" && sb('h1D) == "e" && sb('h1E) == "t";
endfunction

initial begin
    integer last_hb, last_change;
    for (int i = 0; i < NSHM + NA; i++) mem[i] = 0;
    last_hb = -1; last_change = -1000000;
    forever begin
        repeat (200) @(posedge clk);
        if (sig_ok() && sb('h1F) != last_hb) begin
            last_hb = sb('h1F); last_change = $time / 10; beats++;
        end
        // live: the signature is there and the heartbeat moved lately
        if (sb(0) == 8'hE7 && sb(1) == 8'd2 && sig_ok() && $time / 10 - last_change < 3 * 'h8000) begin
        wb(10, 8'hA5); wb(11, 8'd2);
        if (sb(7) & 1) begin
        if (sb(4) != sb(9)) begin
            txlen = sb(5) | ((sb(6) & 15) << 8);
            for (int i = 0; i < txlen; i++) txf[i] = sb('h800 + i);
            wb(9, sb(4));
        end
        if (sb(2) != sb(8) && rxq_n > 0) begin
            integer n;
            n = rxqlen[rxq_head] + 4;
            wb('h1000, n & 255);
            wb('h1001, ((n >> 8) & 7) | ((rxq[rxq_head][0] == 8'hFF) ? 8'h20 : 8'h00));
            for (int i = 0; i < n; i++) wb('h1002 + i, (i < n - 4) ? rxq[rxq_head][i] : 8'hCC);
            rxq_head = (rxq_head + 1) % 64; rxq_n--;
            wb(8, sb(2));
        end
        end
        end
    end
end

task automatic queue_rx(input integer len, input integer tag);
    integer t;
    t = (rxq_head + rxq_n) % 64;
    for (int i = 0; i < len; i++) rxq[t][i] = (i < 6) ? 8'hFF : ((i * 7 + tag) & 255);
    rxqlen[t] = len;
    rxq_n++;
endtask

// ---------------------------------------------------------------- the other DDR master
integer a_errors = 0, a_bursts = 0;
logic   a_stop = 0;

function automatic [63:0] pat(input [28:0] a, input integer pass);
    pat = {3'd0, a, (pass * 32'h9E3779B9) ^ {3'd0, a}};
endfunction

initial begin
    integer pass;
    @(negedge reset);
    for (pass = 0; !a_stop; pass++) begin
        integer n, off, got;
        n   = 1 + ($random(seed) & 15);
        off = $random(seed) & 'hFF0;
        // write burst
        @(posedge clk);
        a_addr <= ABASE + off; a_burstcnt <= n; a_we <= 1; a_din <= pat(ABASE + off, pass);
        for (int i = 0; i < n; i++) begin
            do @(posedge clk); while (a_busy);
            if (i < n - 1) a_din <= pat(ABASE + off + i + 1, pass); else a_we <= 0;
        end
        // read it back
        @(posedge clk);
        a_rd <= 1;
        do @(posedge clk); while (a_busy);
        a_rd <= 0;
        got = 0;
        while (got < n) begin
            @(posedge clk);
            if (a_dout_ready) begin
                if (ddr_dout !== pat(ABASE + off + got, pass)) begin
                    if (a_errors < 5) $display("FAIL other master: burst %0d word %0d got %h", pass, got, ddr_dout);
                    a_errors++;
                end
                got++;
            end
        end
        a_bursts++;
        repeat ($random(seed) & 7) @(posedge clk);
    end
end

// ---------------------------------------------------------------- I/O as a byte-sequential bus does it
task automatic outb(input [4:0] a, input [7:0] d);
    @(posedge clk); io_address <= a; io_cs <= 1; io_write <= 1; io_writedata <= d;
    @(posedge clk); io_write <= 0;
    @(posedge clk); io_cs <= 0;
endtask

task automatic inb(input [4:0] a, output [7:0] d);
    @(posedge clk); io_address <= a; io_cs <= 1; io_read <= 1;
    @(posedge clk); io_read <= 0;
    @(posedge clk); d = io_readdata; io_cs <= 0;
endtask

integer errors = 0;
task automatic check(input string what, input integer got, input integer want);
    if (got !== want) begin $display("FAIL %s: got %h want %h", what, got, want); errors++; end
endtask

task automatic set_rdma(input [15:0] addr, input [15:0] cnt, input [7:0] cmd);
    outb(5'h0A, cnt[7:0]); outb(5'h0B, cnt[15:8]);
    outb(5'h08, addr[7:0]); outb(5'h09, addr[15:8]);
    outb(5'h00, cmd);
endtask

task automatic wait_isr(input [7:0] bits, input integer limit);
    logic [7:0] v;
    integer i;
    v = 0;
    for (i = 0; i < limit && !(v & bits); i++) begin
        inb(5'h07, v);
        if (!(v & bits)) repeat (50) @(posedge clk);
    end
    if (!(v & bits)) begin $display("FAIL timeout waiting for ISR %h", bits); errors++; end
endtask

logic [7:0] v, st, nx, ll, lh;
integer bnry, len, frames, more;

initial begin
    repeat (5) @(posedge clk);
    reset = 0;
    repeat (20) @(posedge clk);

    // reset port, as drivers probe it
    inb(5'h1F, v); outb(5'h1F, v);
    inb(5'h07, v); check("ISR RST", v[7], 1);

    // PROM in word mode with 8-bit INs (as the Crynwr driver reads it): a word each
    outb(5'h00, 8'h21); outb(5'h0E, 8'h49);
    set_rdma(16'h0000, 16'd32, 8'h0A);
    for (int i = 0; i < 16; i++) begin
        logic [7:0] want;
        inb(5'h10, v);
        case (i) 0: want = 8'h02; 1: want = 8'h4E; 2: want = 8'h45; 3: want = 8'h32;
                 4: want = 8'h4B; 5: want = 8'h01; 7: want = 8'h57; default: want = 8'h00; endcase
        check($sformatf("PROM[%0d]", i), v, want);
    end
    inb(5'h07, v); check("RDC after PROM", v[6], 1);
    outb(5'h07, 8'hFF);
    // and with 16-bit INs (10h then 11h): each byte twice
    set_rdma(16'h0000, 16'd12, 8'h0A);
    for (int i = 0; i < 6; i++) begin
        logic [7:0] lo, hi;
        inb(5'h10, lo); inb(5'h11, hi);
        check($sformatf("PROM word %0d", i), {hi, lo}, {2{(i == 0) ? 8'h02 : (i == 1) ? 8'h4E : (i == 2) ? 8'h45 : (i == 3) ? 8'h32 : (i == 4) ? 8'h4B : 8'h01}});
    end
    outb(5'h07, 8'hFF);

    // init as a packet driver does
    outb(5'h00, 8'h21);
    outb(5'h01, 8'h46); outb(5'h02, 8'h80); outb(5'h03, 8'h46); outb(5'h04, 8'h40);
    outb(5'h07, 8'hFF); outb(5'h0F, 8'h13);
    outb(5'h00, 8'h61);
    outb(5'h01, 8'h02); outb(5'h02, 8'h4E); outb(5'h03, 8'h45);
    outb(5'h04, 8'h32); outb(5'h05, 8'h4B); outb(5'h06, 8'h01);
    outb(5'h07, 8'h47);
    outb(5'h00, 8'h22);
    outb(5'h0D, 8'h00); outb(5'h0C, 8'h04);

    // transmit 70 bytes
    set_rdma(16'h4000, 16'd70, 8'h12);
    for (int i = 0; i < 70; i++) outb(5'h10 + (i & 1), (i * 3 + 1) & 255);
    inb(5'h07, v); check("RDC after write", v[6], 1);
    outb(5'h07, 8'h40);
    outb(5'h04, 8'h40); outb(5'h05, 8'd70); outb(5'h06, 8'd0);
    outb(5'h00, 8'h26);
    wait_isr(8'h02, 2000);
    check("irq on PTX", irq, 1);
    inb(5'h04, v); check("TSR", v, 8'h01);
    check("TX length", txlen, 70);
    for (int i = 0; i < 70; i++) check($sformatf("TX[%0d]", i), txf[i], (i * 3 + 1) & 255);
    outb(5'h07, 8'h02);
    check("irq cleared", irq, 0);
    check("version byte", sb(1), 2);
    check("MAC in the area", {sb('h10), sb('h11), sb('h12), sb('h13), sb('h14), sb('h15)}, 48'h024E45324B01);
    check("filter byte", sb('h16), 8'h11);

    // receive frames of assorted lengths, around the ring several times
    bnry = 8'h46;
    frames = 0;
    for (int f = 0; f < 40; f++) queue_rx(60 + (f * 97) % 1450, f);
    while (frames < 40) begin
        integer page, ptr;
        logic [7:0] cur;
        wait_isr(8'h01, 4000);
        outb(5'h07, 8'h01);
        more = 1;
        while (more) begin
            outb(5'h00, 8'h62); inb(5'h07, cur); outb(5'h00, 8'h22);
            page = (bnry + 1 >= 8'h80) ? 8'h46 : bnry + 1;
            if (page == cur) more = 0;
            else begin
            set_rdma(page << 8, 16'd4, 8'h0A);
            inb(5'h10, st); inb(5'h11, nx); inb(5'h10, ll); inb(5'h11, lh);
            len = {lh, ll};
            check($sformatf("frame %0d status", frames), st, 8'h21);
            check($sformatf("frame %0d length", frames), len, 60 + (frames * 97) % 1450 + 4);
            ptr = (page << 8) + 4;
            set_rdma(ptr, len[15:0] + len[0], 8'h0A);
            for (int i = 0; i < len; i++) begin
                inb(5'h10 + (i & 1), v);
                if (i < len - 4) check($sformatf("frame %0d byte %0d", frames, i), v,
                                       (i < 6) ? 8'hFF : ((i * 7 + frames) & 255));
                if (errors > 10) begin $display("too many errors"); $finish; end
            end
            bnry = (nx == 8'h46) ? 8'h7F : nx - 1;
            outb(5'h03, bnry[7:0]);
            frames++;
            end
        end
    end

    a_stop = 1;
    repeat (200) @(posedge clk);
    check("other master errors", a_errors, 0);
    if (a_bursts < 50) begin $display("FAIL other master only finished %0d bursts", a_bursts); errors++; end
    if (beats < 3) begin $display("FAIL heartbeat moved only %0d times", beats); errors++; end
    if (errors == 0)
        $display("PASS netbridge_ne2000: PROM, remote DMA, TX, %0d RX frames; %0d bursts of the other master intact; %0d heartbeats",
                 frames, a_bursts, beats);
    else $display("FAILED with %0d errors", errors);
    $finish;
end

initial begin
    #400_000_000;
    $display("FAIL global timeout"); $finish;
end

endmodule
