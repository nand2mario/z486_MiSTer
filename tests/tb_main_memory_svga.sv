`timescale 1ns / 1ps

module tb_main_memory_svga;
    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;

    logic [31:0] cpu_addr = 0;
    logic [31:0] cpu_din = 0;
    logic [31:0] cpu_dout;
    logic cpu_resp_valid;
    logic [127:0] cpu_line_dout;
    logic cpu_line_resp_valid;
    logic [3:0] cpu_be = 0;
    logic [7:0] cpu_burstcount = 1;
    logic cpu_line_read = 0;
    logic cpu_ready;
    logic cpu_valid = 0;
    logic cpu_write = 0;
    logic [1:0] ram_size = 0;
    logic [31:0] mem_addr;
    logic [31:0] mem_din;
    logic [31:0] mem_dout = 0;
    logic mem_resp_valid = 0;
    logic [127:0] mem_line_dout = 0;
    logic mem_line_resp_valid = 0;
    logic [3:0] mem_be;
    logic [7:0] mem_burstcount;
    logic mem_line_read;
    logic mem_ready = 0;
    logic mem_valid;
    logic mem_write;
    logic [16:0] vga_address;
    logic [7:0] vga_readdata = 0;
    logic [7:0] vga_writedata;
    logic [2:0] vga_memmode = 3'b100;
    logic vga_read;
    logic vga_write;
    logic [5:0] vga_wr_seg = 0;
    logic [5:0] vga_rd_seg = 6'h12;
    logic vga_fb_en = 1;
    logic vga_chain4 = 1;
    logic [3:0] vga_map_mask = 4'hF;
    logic [1:0] vga_read_plane = 0;
    logic [1:0] vga_write_mode = 0;
    logic vga_wr_done;
    logic [28:0] fb_ddram_addr;
    logic [63:0] fb_ddram_din;
    logic [7:0] fb_ddram_be;
    logic fb_ddram_we;
    logic fb_ddram_rd;
    logic [63:0] fb_ddram_dout = 0;
    logic fb_ddram_dout_ready = 0;
    logic [7:0] fb_ddram_burstcnt;
    logic fb_ddram_busy = 0;

    main_memory dut (.*);

    // ------------------------------------------------------------- DDR3 model
    // Avalon-MM slave semantics: a read is accepted only in a cycle where the
    // master holds fb_ddram_rd AND the slave reports !busy in that same cycle.
    // A master that samples !busy and pulses rd one cycle later loses the
    // request - which is the defect the handshake cases below exist to catch.
    integer fb_accepts = 0;

    always @(posedge clk) begin
        fb_ddram_dout_ready <= 0;
        if (fb_ddram_rd && !fb_ddram_busy) begin
            fb_accepts <= fb_accepts + 1;
            fb_ddram_dout <= 64'h8877_6655_4433_2211;
            fb_ddram_dout_ready <= 1;
        end
    end

    // ---------------------------------------------------------------- helpers

    // Present exactly one cycle in which the DDR3 reports !busy, `hold` cycles
    // after the request was accepted, then take busy away again and see whether
    // the read survived.
    task automatic fb_read_under_busy(input integer hold, input [31:0] addr);
        integer acc_start, i;
        logic   got;
        logic [31:0] data;
        begin
            acc_start = fb_accepts;
            got = 0;
            data = 32'hx;
            @(negedge clk);
            fb_ddram_busy = 1;
            cpu_addr = addr;
            cpu_be = 4'hF;
            cpu_write = 0;
            cpu_line_read = 0;
            cpu_burstcount = 1;
            cpu_valid = 1;
            do begin
                @(posedge clk);
                #1;
            end while (!cpu_ready);
            @(negedge clk);
            cpu_valid = 0;
            for (i = 0; i < hold; i = i + 1) @(negedge clk);
            fb_ddram_busy = 0;      // the single !busy cycle
            @(negedge clk);
            fb_ddram_busy = 1;      // gone again
            for (i = 0; i < 40; i = i + 1) begin
                @(posedge clk);
                #1;
                if (cpu_resp_valid && !got) begin
                    got = 1;
                    data = cpu_dout;
                end
            end
            @(negedge clk);
            fb_ddram_busy = 0;
            if (fb_accepts != acc_start + 1)
                $fatal(1, "FB_READ hold=%0d: expected exactly 1 accepted DDR3 read, got %0d (Avalon read not held until !busy)",
                       hold, fb_accepts - acc_start);
            if (!got)
                $fatal(1, "FB_READ hold=%0d: no cpu_resp_valid - the read was dropped and the FSM is wedged",
                       hold);
            if (data !== 32'h4433_2211)
                $fatal(1, "FB_READ hold=%0d: wrong data %08x", hold, data);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset = 0;

        // Read the upper dword of bank 0x12, then change the CPU address as soon
        // as the request is accepted. The DDR response must use the accepted
        // request's half-select rather than the now-live CPU address.
        @(negedge clk);
        cpu_addr = 32'h000A_0004;
        cpu_be = 4'hF;
        cpu_valid = 1;
        do begin
            @(posedge clk);
            #1;
        end while (!cpu_ready);

        if (fb_ddram_addr !== 29'h07F2_4000)
            $fatal(1, "SVGA read address mismatch: %08x", fb_ddram_addr);

        @(negedge clk);
        cpu_valid = 0;
        cpu_addr = 32'h000A_0000;

        do begin
            @(posedge clk);
            #1;
        end while (!cpu_resp_valid);

        if (cpu_dout !== 32'h8877_6655)
            $fatal(1, "SVGA read used live address half-select: got %08x", cpu_dout);

        $display("PASS: SVGA read preserves the accepted dword half-select");

        // Windows' ET4000 driver disables chain-4 for screen-to-screen blits.
        // Each aperture byte then addresses four adjacent framebuffer pixels;
        // a read loads all plane latches and write mode 1 copies those latches.
        @(negedge clk);
        vga_chain4 = 0;
        vga_rd_seg = 6'h01;
        vga_read_plane = 2;
        cpu_addr = 32'h000A_0010;
        cpu_be = 4'h1;
        cpu_valid = 1;
        cpu_write = 0;
        do begin
            @(posedge clk);
            #1;
        end while (!cpu_ready);

        if (fb_ddram_addr !== 29'h07F0_8008)
            $fatal(1, "planar SVGA read address mismatch: %08x", fb_ddram_addr);

        @(negedge clk);
        cpu_valid = 0;
        do begin
            @(posedge clk);
            #1;
        end while (!cpu_resp_valid);

        if (cpu_dout !== 32'h3333_3333)
            $fatal(1, "planar SVGA selected-plane read mismatch: %08x", cpu_dout);

        @(negedge clk);
        vga_wr_seg = 6'h02;
        vga_map_mask = 4'hA;
        vga_write_mode = 1;
        cpu_addr = 32'h000A_0020;
        cpu_be = 4'h2;
        cpu_din = 32'h0000_A500;
        cpu_valid = 1;
        cpu_write = 1;
        do begin
            @(posedge clk);
            #1;
        end while (!cpu_ready);

        if (fb_ddram_addr !== 29'h07F1_0010)
            $fatal(1, "planar SVGA write address mismatch: %08x", fb_ddram_addr);
        if (fb_ddram_be !== 8'hA0)
            $fatal(1, "planar SVGA map mask mismatch: %02x", fb_ddram_be);
        if (fb_ddram_din !== 64'h4433_2211_0000_0000)
            $fatal(1, "planar SVGA latch data mismatch: %016x", fb_ddram_din);

        @(negedge clk);
        cpu_valid = 0;
        $display("PASS: planar SVGA write mode 1 copies all four VGA latches");

        // A larger physical SDRAM module must not leak past the guest RAM
        // size. Cache-line reads still need one response per requested beat.
        @(negedge clk);
        vga_chain4 = 1;
        cpu_addr = 32'h0100_0000;
        cpu_be = 4'hF;
        cpu_burstcount = 3;
        cpu_valid = 1;
        cpu_write = 0;
        #1;
        if (!cpu_ready || mem_valid)
            $fatal(1, "16MB boundary read was sent to physical SDRAM");
        @(negedge clk);
        cpu_valid = 0;
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!cpu_resp_valid || cpu_dout !== 32'hFFFF_FFFF)
                $fatal(1, "missing open-bus burst response above 16MB");
        end
        @(posedge clk);
        #1;
        if (cpu_resp_valid)
            $fatal(1, "extra open-bus burst response above 16MB");

        @(negedge clk);
        cpu_addr = 32'h0100_0000;
        cpu_burstcount = 1;
        cpu_valid = 1;
        cpu_write = 1;
        #1;
        if (!cpu_ready || mem_valid)
            $fatal(1, "write above 16MB was not ignored locally");
        @(negedge clk);
        cpu_valid = 0;

        ram_size = 1;
        cpu_addr = 32'h0100_0000;
        cpu_valid = 1;
        cpu_write = 0;
        #1;
        if (cpu_ready || !mem_valid)
            $fatal(1, "32MB configuration rejected an in-range access");
        @(negedge clk);
        cpu_valid = 0;

        ram_size = 3;
        cpu_addr = 32'h0800_0000;
        cpu_valid = 1;
        #1;
        if (!cpu_ready || mem_valid)
            $fatal(1, "address above 128MB aliased into physical SDRAM");
        @(negedge clk);
        cpu_valid = 0;
        $display("PASS: configured RAM size is enforced as a physical decode limit");

        // ------------------------------------------------------------------
        // F1 - the DDR3 read must be HELD until the slave is not busy in the
        // same cycle. DDRAM_BUSY is the HPS f2sdram bridge's waitrequest and
        // goes high for refresh and for the scaler's own framebuffer fetches.
        // A dropped read leaves FB_READ_WAIT waiting forever, and because
        // mem_valid is gated on !vga_busy that wedges every later CPU access:
        // the 8-bpp "desktop painted then frozen" failure mode.
        // ------------------------------------------------------------------
        @(negedge clk);
        ram_size = 0;
        vga_fb_en = 1;
        vga_chain4 = 1;
        vga_rd_seg = 6'h12;
        vga_read_plane = 0;
        cpu_din = 0;
        fb_read_under_busy(1, 32'h000A_0000);
        fb_read_under_busy(2, 32'h000A_0000);
        fb_read_under_busy(7, 32'h000A_0000);
        $display("PASS: FB_READ holds the DDR3 read until it is accepted (busy 1/2/7 cycles)");

        $finish;
    end

    // The defects under test all manifest as a stalled FSM; fail, do not hang.
    integer cycles = 0;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles > 6000)
            $fatal(1, "watchdog: no progress in 6000 cycles");
    end
endmodule
