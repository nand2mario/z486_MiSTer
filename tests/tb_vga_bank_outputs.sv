`timescale 1ns/1ps

// vga_rd_seg / vga_wr_seg (the CPU aperture bank) must track the 3CD/3CB
// bank registers with no extra clock of latency.

module tb_vga_bank_outputs;
    logic clk_sys = 0;
    logic clk_vga = 0;
    logic rst_n = 0;

    logic [3:0] io_address = 0;
    logic io_read = 0;
    wire  [7:0] io_readdata;
    logic io_write = 0;
    logic [7:0] io_writedata = 0;
    logic io_b_cs = 0;
    logic io_c_cs = 0;
    logic io_d_cs = 0;
    logic [16:0] mem_address = 0;
    logic mem_read = 0;
    wire  [7:0] mem_readdata;
    logic mem_write = 0;
    logic [7:0] mem_writedata = 0;
    wire irq;
    logic [27:0] clock_rate_vga = 28'd25_175_000;
    wire vga_ce;
    logic vga_f60 = 0;
    wire [2:0] vga_memmode;
    wire vga_blank_n;
    wire vga_off;
    wire vga_horiz_sync;
    wire vga_vert_sync;
    wire [7:0] vga_r;
    wire [7:0] vga_g;
    wire [7:0] vga_b;
    wire [17:0] vga_pal_d;
    wire [7:0] vga_pal_a;
    wire vga_pal_we;
    wire [19:0] vga_start_addr;
    wire [5:0] vga_wr_seg;
    wire [5:0] vga_rd_seg;
    wire [8:0] vga_width;
    wire [8:0] vga_stride;
    wire [10:0] vga_height;
    wire [3:0] vga_flags;
    wire vga_chain4;
    wire [3:0] vga_map_mask;
    wire [1:0] vga_read_plane;
    wire [1:0] vga_write_mode;
    logic vga_lores = 0;
    logic vga_border = 0;
    logic scanline_req_valid = 0;
    wire scanline_req_ready;
    logic scanline_frame_start = 0;
    logic [10:0] scanline_y = 0;
    wire [10:0] scanline_width;
    wire [10:0] scanline_height;
    wire [31:0] scanline_native_frames;
    wire scanline_done;

    always #5 clk_sys = ~clk_sys;
    always #7 clk_vga = ~clk_vga;

    vga dut (.*);


    task automatic io_c_wr(input [3:0] a, input [7:0] d);
        begin
            @(negedge clk_sys);
            io_c_cs = 1; io_b_cs = 0; io_d_cs = 0;
            io_address = a; io_writedata = d; io_write = 1;
            @(negedge clk_sys);
            io_write = 0; io_c_cs = 0;
            @(negedge clk_sys);
        end
    endtask

    task automatic io_c_rd(input [3:0] a, output [7:0] d);
        begin
            @(negedge clk_sys);
            io_c_cs = 1; io_b_cs = 0; io_d_cs = 0;
            io_address = a; io_read = 1;
            @(posedge clk_sys);     // io_c_read_valid edge; io_readdata registers here
            @(negedge clk_sys);
            d = io_readdata;
            io_read = 0; io_c_cs = 0;
            @(negedge clk_sys);
        end
    endtask

    // Attribute controller: 3C0 alternates index / data via the flip-flop.
    task automatic atc_wr(input [4:0] idx, input [7:0] d);
        begin
            // Reading 3BA/3DA clears the flip-flop; drive the index first.
            io_c_wr(4'h0, {3'b001, idx});   // index, PAS set
            io_c_wr(4'h0, d);               // data
        end
    endtask

    task automatic seq_wr(input [4:0] idx, input [7:0] d);
        begin
            io_c_wr(4'h4, {3'd0, idx});
            io_c_wr(4'h5, d);
        end
    endtask

    logic [7:0] rd;

    initial begin
        repeat (4) @(negedge clk_sys);
        rst_n = 1;
        repeat (2) @(negedge clk_sys);

        // ----------------------------------------------------- Codex Fix 3
        // 3CD: high nibble = read bank, low nibble = write bank.
        @(negedge clk_sys);
        io_c_cs = 1; io_b_cs = 0; io_d_cs = 0;
        io_address = 4'hD; io_writedata = 8'h21; io_write = 1;
        @(posedge clk_sys);     // seg_rd/seg_wr update on this edge
        #1;
        if (dut.seg_rd[3:0] !== 4'h2 || dut.seg_wr[3:0] !== 4'h1)
            $fatal(1, "test error: 3CD write did not land");
        if (vga_rd_seg !== 6'h02 || vga_wr_seg !== 6'h01)
            $fatal(1, "aperture bank outputs lag the 3CD bank registers by a clock (rd=%02x wr=%02x)",
                   vga_rd_seg, vga_wr_seg);
        @(negedge clk_sys);
        io_write = 0; io_c_cs = 0;
        // 3CB supplies bits [5:4] of each bank.
        @(negedge clk_sys);
        io_c_cs = 1;
        io_address = 4'hB; io_writedata = 8'h32; io_write = 1;
        @(posedge clk_sys);
        #1;
        if (vga_rd_seg !== 6'h32 || vga_wr_seg !== 6'h21)
            $fatal(1, "3CB high bank bits lag (rd=%02x wr=%02x)", vga_rd_seg, vga_wr_seg);
        @(negedge clk_sys);
        io_write = 0; io_c_cs = 0;
        $display("PASS: 3CD/3CB bank registers reach the aperture with no extra latency");


        $finish;
    end

    integer cycles = 0;
    always @(posedge clk_sys) begin
        cycles <= cycles + 1;
        if (cycles > 20000) $fatal(1, "watchdog: tb_vga_fb_mode_gate made no progress");
    end
endmodule
