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
    wire  [7:0] vga_readdata;
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
    logic   ddr_addr_pattern = 0;   // 1 => returned data identifies its address
    wire [31:0] ddr_dwidx = {fb_ddram_addr, 1'b0};  // dword index of the low half

    always @(posedge clk) begin
        fb_ddram_dout_ready <= 0;
        if (fb_ddram_rd && !fb_ddram_busy) begin
            fb_accepts <= fb_accepts + 1;
            fb_ddram_dout <= ddr_addr_pattern ? {ddr_dwidx + 32'd1, ddr_dwidx}
                                              : 64'h8877_6655_4433_2211;
            fb_ddram_dout_ready <= 1;
        end
    end

    // -------------------------------------------------- legacy plane RAM model
    // vga.v presents the byte one clock after vga_address/vga_read are driven,
    // which is the cycle in which main_memory shifts it in.
    assign vga_readdata = vga_address[7:0] ^ 8'h5A;

    function automatic [31:0] plane_dword(input integer dw);
        plane_dword = {8'((dw*4+3) ^ 8'h5A), 8'((dw*4+2) ^ 8'h5A),
                       8'((dw*4+1) ^ 8'h5A), 8'((dw*4+0) ^ 8'h5A)};
    endfunction

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
            ddr_addr_pattern = 0;
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

        // ------------------------------------------------------------------
        // F2 - a cache-line fill out of the aperture owes FOUR ordered dword
        // responses. l1_icache.sv issues burstcount=4 at a 16-byte-aligned
        // address and completes on four mem_resp_valid pulses (the 128-bit
        // line route is tied off on this board). Both aperture read paths used
        // to answer with exactly one response, deadlocking the fetch unit and
        // therefore the whole memory fabric.
        //
        // The aperture state (bank, chain-4) is perturbed after the first beat:
        // the remaining beats must still use what was captured at acceptance.
        // ------------------------------------------------------------------
        begin : fb_line_fill
            integer beat;
            logic [31:0] expect_dw;
            @(negedge clk);
            ddr_addr_pattern = 1;
            fb_ddram_busy = 0;
            vga_fb_en = 1;
            vga_chain4 = 1;
            vga_rd_seg = 6'h12;
            cpu_addr = 32'h000A_0000;
            cpu_be = 4'hF;
            cpu_write = 0;
            cpu_burstcount = 4;
            cpu_line_read = 1;
            cpu_valid = 1;
            do begin
                @(posedge clk);
                #1;
            end while (!cpu_ready);
            @(negedge clk);
            cpu_valid = 0;
            cpu_line_read = 0;
            cpu_burstcount = 1;
            // 0x3F80_0000 | (0x12 << 16) = 0x3F92_0000 -> dword index 0x0FE4_8000
            for (beat = 0; beat < 4; beat = beat + 1) begin
                expect_dw = 32'h0FE4_8000 + beat;
                // delayed DDR3: make every beat wait, and re-issue under busy
                fb_ddram_busy = 1;
                repeat (2 + beat) @(negedge clk);
                fb_ddram_busy = 0;
                @(negedge clk);
                fb_ddram_busy = 1;
                begin : wait_beat
                    integer i;
                    logic got;
                    got = 0;
                    for (i = 0; i < 40 && !got; i = i + 1) begin
                        @(posedge clk);
                        #1;
                        if (cpu_resp_valid) begin
                            got = 1;
                            if (cpu_dout !== expect_dw)
                                $fatal(1, "aperture line fill beat %0d: expected %08x got %08x",
                                       beat, expect_dw, cpu_dout);
                        end
                    end
                    if (!got)
                        $fatal(1, "aperture line fill stalled after %0d of 4 dword responses",
                               beat);
                end
                if (beat == 0) begin
                    // Mid-burst bank / plane / address change. A correct
                    // implementation captured them at request acceptance.
                    vga_rd_seg = 6'h3F;
                    vga_read_plane = 3;
                    cpu_addr = 32'h000B_8000;
                end
            end
            @(negedge clk);
            fb_ddram_busy = 0;
            // No fifth response.
            repeat (10) begin
                @(posedge clk);
                #1;
                if (cpu_resp_valid)
                    $fatal(1, "aperture line fill produced a fifth response");
            end
            if (fb_accepts < 4)
                $fatal(1, "aperture line fill issued fewer than 4 DDR3 reads");
            $display("PASS: FB_READ line fill returns 4 ordered dwords, bank captured at acceptance");
        end

        // Same contract on the legacy (fb_en=0) plane-RAM read path.
        begin : vga_line_fill
            integer beat, i;
            logic got;
            logic [31:0] expect_dw;
            @(negedge clk);
            vga_fb_en = 0;
            vga_chain4 = 1;
            vga_memmode = 3'b100;
            cpu_addr = 32'h000A_0000;
            cpu_be = 4'hF;
            cpu_write = 0;
            cpu_burstcount = 4;
            cpu_line_read = 1;
            cpu_valid = 1;
            do begin
                @(posedge clk);
                #1;
            end while (!cpu_ready);
            @(negedge clk);
            cpu_valid = 0;
            cpu_line_read = 0;
            cpu_burstcount = 1;
            cpu_addr = 32'h000B_0000;   // must not affect the accepted request
            for (beat = 0; beat < 4; beat = beat + 1) begin
                expect_dw = plane_dword(beat);
                got = 0;
                for (i = 0; i < 60 && !got; i = i + 1) begin
                    @(posedge clk);
                    #1;
                    if (cpu_resp_valid) begin
                        got = 1;
                        if (cpu_dout !== expect_dw)
                            $fatal(1, "legacy VGA line fill beat %0d: expected %08x got %08x",
                                   beat, expect_dw, cpu_dout);
                    end
                end
                if (!got)
                    $fatal(1, "legacy VGA line fill stalled after %0d of 4 dword responses",
                           beat);
            end
            repeat (20) begin
                @(posedge clk);
                #1;
                if (cpu_resp_valid)
                    $fatal(1, "legacy VGA line fill produced a fifth response");
            end
            $display("PASS: legacy VGA_READ line fill returns 4 ordered dwords");
        end

        // A single-dword aperture read must still produce exactly one response.
        begin : single_dword_after_burst
            integer i;
            integer resp;
            @(negedge clk);
            vga_fb_en = 1;
            ddr_addr_pattern = 0;
            fb_ddram_busy = 0;
            vga_chain4 = 1;
            vga_rd_seg = 6'h12;
            cpu_addr = 32'h000A_0000;
            cpu_be = 4'hF;
            cpu_burstcount = 1;
            cpu_line_read = 0;
            cpu_valid = 1;
            do begin
                @(posedge clk);
                #1;
            end while (!cpu_ready);
            @(negedge clk);
            cpu_valid = 0;
            resp = 0;
            for (i = 0; i < 30; i = i + 1) begin
                @(posedge clk);
                #1;
                if (cpu_resp_valid) begin
                    resp = resp + 1;
                    if (cpu_dout !== 32'h4433_2211)
                        $fatal(1, "single aperture dword read data %08x", cpu_dout);
                end
            end
            if (resp !== 1)
                $fatal(1, "single aperture dword read produced %0d responses", resp);
            $display("PASS: single-dword aperture read still produces exactly one response");
        end

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
