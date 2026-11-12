// NE2000 card: PROM, remote DMA, transmit and the receive ring (with wrap),
// against a model of the c65_net helper on the DDR side.
`timescale 1ns/1ns
module tb_ne2000;

logic clk = 0, reset = 1;
always #5 clk = ~clk;

logic  [4:0] io_address;
logic        io_read = 0, io_write = 0, io_cs = 0;
logic  [7:0] io_writedata, io_readdata;
logic        irq;
logic [28:0] ddr_addr;
logic        ddr_rd, ddr_we;
logic [63:0] ddr_din;
logic  [7:0] ddr_be;
logic        ddr_busy = 0;
logic [63:0] ddr_dout;
logic        ddr_dout_ready = 0;

ne2000 dut (
    .clk(clk), .reset(reset), .enable(1'b1),
    .io_address(io_address), .io_read(io_read), .io_write(io_write), .io_cs(io_cs),
    .io_writedata(io_writedata), .io_readdata(io_readdata), .irq(irq),
    .ddr_addr(ddr_addr), .ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_din(ddr_din), .ddr_be(ddr_be),
    .ddr_busy(ddr_busy), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready)
);

// ---------------------------------------------------------------- DDR model
localparam [28:0] BASE = 29'h7FE0000;
logic [63:0] shm [0:'h5FF];
integer      lat = 0;
logic [10:0] rd_idx;
logic        rd_pend = 0;
integer      seed = 1;

always @(posedge clk) begin
    ddr_dout_ready <= 0;
    ddr_busy <= ($random(seed) & 3) == 0;
    if (!ddr_busy && ddr_we) begin
        for (int b = 0; b < 8; b++)
            if (ddr_be[b]) shm[ddr_addr - BASE][8*b +: 8] <= ddr_din[8*b +: 8];
    end
    if (!ddr_busy && ddr_rd && !rd_pend) begin
        rd_pend <= 1; rd_idx <= ddr_addr - BASE; lat <= 3 + ($random(seed) & 7);
    end
    if (rd_pend) begin
        if (lat == 0) begin ddr_dout <= shm[rd_idx]; ddr_dout_ready <= 1; rd_pend <= 0; end
        else lat <= lat - 1;
    end
end

function automatic [7:0] sb(input integer a); sb = shm[a >> 3][8*(a & 7) +: 8]; endfunction
task automatic wb(input integer a, input [7:0] v); shm[a >> 3][8*(a & 7) +: 8] = v; endtask

// ---------------------------------------------------------------- helper model
logic [7:0] txf [0:2047];
integer     txlen = -1;
logic [7:0] rxq [0:63][0:1599];
integer     rxqlen [0:63];
integer     rxq_head = 0, rxq_n = 0;

initial begin
    for (int i = 0; i < 'h600; i++) shm[i] = 0;
    forever begin
        repeat (200) @(posedge clk);
        wb(10, 8'hA5);
        if (sb(0) == 8'hE7 && (sb(7) & 1)) begin
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

task automatic queue_rx(input integer len, input integer tag);
    integer t;
    t = (rxq_head + rxq_n) % 64;
    for (int i = 0; i < len; i++) rxq[t][i] = (i < 6) ? 8'hFF : 8'((i * 7 + tag) & 255);
    rxqlen[t] = len;
    rxq_n++;
endtask

// ---------------------------------------------------------------- I/O as the bus adapter does it
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
    for (int i = 0; i < limit; i++) begin
        inb(5'h07, v);
        if (v & bits) return;
        repeat (50) @(posedge clk);
    end
    $display("FAIL timeout waiting for ISR %h", bits); errors++;
endtask

logic [7:0] v, st, nx, ll, lh;
integer bnry, len, frames;

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
    for (int i = 0; i < 70; i++) outb(5'h10 + (i & 1), 8'((i * 3 + 1) & 255));
    inb(5'h07, v); check("RDC after write", v[6], 1);
    outb(5'h07, 8'h40);
    outb(5'h04, 8'h40); outb(5'h05, 8'd70); outb(5'h06, 8'd0);
    outb(5'h00, 8'h26);
    wait_isr(8'h02, 400);
    check("irq on PTX", irq, 1);
    inb(5'h04, v); check("TSR", v, 8'h01);
    check("TX length", txlen, 70);
    for (int i = 0; i < 70; i++) check($sformatf("TX[%0d]", i), txf[i], (i * 3 + 1) & 255);
    outb(5'h07, 8'h02);
    check("irq cleared", irq, 0);

    // receive frames of assorted lengths, around the ring several times
    bnry = 8'h46;
    frames = 0;
    for (int f = 0; f < 40; f++) queue_rx(60 + (f * 97) % 1450, f);
    while (frames < 40) begin
        integer page, ptr;
        logic [7:0] cur;
        wait_isr(8'h01, 2000);
        outb(5'h07, 8'h01);
        forever begin
            outb(5'h00, 8'h62); inb(5'h07, cur); outb(5'h00, 8'h22);
            page = (bnry + 1 >= 8'h80) ? 8'h46 : bnry + 1;
            if (page == cur) break;
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

    if (errors == 0) $display("PASS ne2000: PROM, remote DMA, TX, %0d RX frames", frames);
    else $display("FAILED with %0d errors", errors);
    $finish;
end

initial begin
    #200_000_000;
    $display("FAIL global timeout"); $finish;
end

endmodule
