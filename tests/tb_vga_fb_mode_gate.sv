`timescale 1ns/1ps

// F3 - fb_en (vga_flags[1:0]) must drop when the attribute controller
// leaves graphics mode. vga.v survives a CPU-only warm reset with its ET4000
// extended registers (ATC 0x16) intact, so ATC 0x10 bit 0 has to gate it.

module tb_vga_fb_mode_gate;
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

    // same predicate as FB_EN in z486_mister.sv
    wire fb_en = ~vga_flags[2] && |vga_flags[1:0];

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

        // ------------------------------------------------------------ F3
        // An ET4000 VBE framebuffer mode: ATC 0x16 bit 7 (bypass internal
        // palette) set, ATC 0x10 bit 0 (graphics mode) set, bit 6 (PELWIDTH)
        // clear so fb_en can assert.
        atc_wr(5'h16, 8'h80);
        atc_wr(5'h10, 8'h01);
        @(posedge clk_sys); @(posedge clk_sys); #1;
        if (vga_flags[1:0] !== 2'b01 || !fb_en)
            $fatal(1, "graphics-mode framebuffer not enabled: vga_flags=%b fb_en=%b",
                   vga_flags, fb_en);

        // The BIOS's warm-boot mode-3 set clears ATC 0x10 bit 0 but does NOT
        // touch the ET4000 extended ATC 0x16, exactly as modelled here.
        atc_wr(5'h10, 8'h00);
        @(posedge clk_sys); @(posedge clk_sys); #1;
        if (dut.attrib_reg16[7] !== 1'b1)
            $fatal(1, "test error: ATC16 bit7 should still be set");
        if (vga_flags[1:0] !== 2'b00 || fb_en)
            $fatal(1, "fb_en survived into text mode: vga_flags=%b fb_en=%b (BIOS text output would be remapped into DDR3)",
                   vga_flags, fb_en);

        // Re-entering graphics mode must bring it back.
        atc_wr(5'h10, 8'h01);
        @(posedge clk_sys); @(posedge clk_sys); #1;
        if (!fb_en)
            $fatal(1, "fb_en did not return on re-entering graphics mode");
        $display("PASS: fb_en tracks ATC10 graphics mode, not just ATC16");

        // 16bpp and 24bpp selectors must still work, and still be gated.
        atc_wr(5'h16, 8'hA0);           // bits[5:4]=2 -> 16bpp
        @(posedge clk_sys); @(posedge clk_sys); #1;
        if (vga_flags[1:0] !== 2'b10)
            $fatal(1, "16bpp depth decode broken: %b", vga_flags[1:0]);
        atc_wr(5'h10, 8'h00);
        @(posedge clk_sys); @(posedge clk_sys); #1;
        if (vga_flags[1:0] !== 2'b00)
            $fatal(1, "16bpp fb_en survived into text mode: %b", vga_flags[1:0]);
        atc_wr(5'h16, 8'h80);
        atc_wr(5'h10, 8'h01);
        $display("PASS: 16bpp depth decode preserved and gated");

        $finish;
    end

    integer cycles = 0;
    always @(posedge clk_sys) begin
        cycles <= cycles + 1;
        if (cycles > 20000) $fatal(1, "watchdog: tb_vga_fb_mode_gate made no progress");
    end
endmodule
