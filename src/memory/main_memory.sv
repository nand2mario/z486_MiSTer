// Main memory mux - most accesses go to SDRAM, VGA accesses go to vga module.
// nand2mario, 7/2025
module main_memory (
    input             clk,
    input             reset,
    input      [31:0] cpu_addr,
    input      [31:0] cpu_din,
    output reg [31:0] cpu_dout,
    output            cpu_resp_valid,   // read data available (pulse)
    input      [3:0]  cpu_be,           // byte enable for writes, assumed consecutive 1's
    input      [7:0]  cpu_burstcount,   // burst count for reads
    output            cpu_ready,        // accepted this cycle
    input             cpu_valid,        // request valid
    input             cpu_write,        // 1=write, 0=read
    input      [1:0]  ram_size,         // 0/1/2/3 = 16/32/64/128MB

    // Memory interface - goes to SDRAM (valid/ready)
    output     [31:0] mem_addr,
    output     [31:0] mem_din,
    input      [31:0] mem_dout,
    input             mem_resp_valid,
    output     [3:0]  mem_be,
    output     [7:0]  mem_burstcount,
    input             mem_ready,        // SDRAM accepted this request
    output            mem_valid,        // held until ready
    output            mem_write,        // 1=write, 0=read

    // VGA memory interface - goes to vga.v
    output reg [16:0] vga_address,
    input      [7:0]  vga_readdata,
    output reg [7:0]  vga_writedata,
    input      [2:0]  vga_memmode,
    output reg        vga_read,
    output reg        vga_write,

    input      [5:0]  vga_wr_seg,
    input      [5:0]  vga_rd_seg,
    input             vga_fb_en,
    input             vga_chain4,
    input      [3:0]  vga_map_mask,
    input      [1:0]  vga_read_plane,
    input      [1:0]  vga_write_mode,

    output reg        vga_wr_done,    // pulses 1 cycle when VGA write completes

    // DDR3 SVGA framebuffer read/write port (used when vga_fb_en; post-boot).
    // ET4000 linear address = bank(vga_wr_seg/rd_seg)*64KB + window offset.
    output reg [28:0] fb_ddram_addr,
    output reg [63:0] fb_ddram_din,
    output reg  [7:0] fb_ddram_be,
    output            fb_ddram_we,
    output reg        fb_ddram_rd,
    input      [63:0] fb_ddram_dout,
    input             fb_ddram_dout_ready,
    output     [7:0]  fb_ddram_burstcnt,
    input             fb_ddram_busy
);

reg vga_busy;
reg vga_dout_ready;
reg [31:0] vga_dout;
reg vga_accepted;
reg fb_read_high_dword;

// Keep the configured guest RAM size as a real decode boundary. CMOS reports
// the same limit, but the physical SDRAM module may be larger.
function automatic ram_address_in_range(input [31:0] address, input [1:0] size);
    ram_address_in_range =
        (size == 2'd0) ? ~|address[31:24] :
        (size == 2'd1) ? ~|address[31:25] :
        (size == 2'd2) ? ~|address[31:26] :
                         ~|address[31:27];
endfunction

// SDRAM path: pass through when not VGA region and VGA FSM is idle
assign mem_addr       = cpu_addr;
assign mem_din        = cpu_din;
assign mem_be         = cpu_be;
assign mem_burstcount = cpu_burstcount;
assign mem_valid      = cpu_valid && !vga_rgn && !vga_busy && ram_address_in_range(cpu_addr, ram_size);
assign mem_write      = cpu_write;

// CPU acceptance: either SDRAM accepted or VGA accepted
assign cpu_ready      = mem_ready | vga_accepted |
                        (cpu_valid && !vga_rgn && !ram_address_in_range(cpu_addr, ram_size) && state == IDLE);
assign cpu_resp_valid = mem_resp_valid | vga_dout_ready;
assign cpu_dout       = vga_dout_ready ? vga_dout : mem_dout;

logic [2:0] state;
localparam IDLE = 0;
localparam VGA_READ = 1;
localparam VGA_WRITE = 2;
localparam FB_WRITE = 3;
localparam FB_READ  = 4;   // issue DDR3 read
localparam FB_READ_WAIT = 5;   // await read data
localparam UNMAPPED_READ = 6;

// DDR3 framebuffer write: assert WE while in FB_WRITE; accepted when ~busy.
assign fb_ddram_we       = (state == FB_WRITE);
assign fb_ddram_burstcnt = 8'd1;
// SVGA framebuffer base in DDR3 = byte 0x3F80_0000 = {4'h3,6'b111110,22'h0},
// matching FB_BASE = {4'h3,6'b111110,vga_start_addr,2'b00} in z486_mister.sv.
// Chain-4 exposes packed bytes. In planar mode each aperture byte addresses a
// four-pixel group; the request byte enable selects the aligned dword lane.
function automatic [31:0] framebuffer_byte_address(input [5:0] bank);
    framebuffer_byte_address = 32'h3F80_0000 |
        (vga_chain4 ? {10'b0, bank, cpu_addr[15:0]} :
         {8'b0, bank, cpu_addr[15:2],
          cpu_be[0] ? 2'd0 : cpu_be[1] ? 2'd1 : cpu_be[2] ? 2'd2 : 2'd3, 2'b00});
endfunction

reg   [1:0] vga_mask;
reg   [1:0] vga_cmp;
reg   [3:0] vga_be;
reg   [2:0] vga_bcnt;
reg   [31:0] vga_data;
reg   [1:0] vga_bank;

// = 0xA0000-0xBFFFF (VGA: exact region depends on VGA_MODE)
wire vga_rgn = (cpu_addr[31:17] == 'h5) && ((cpu_addr[16:15] & vga_mask) == vga_cmp);

always @(posedge clk) begin
    if (reset) begin
        state <= IDLE;
        vga_busy <= 0;
        vga_dout_ready <= 0;
        vga_dout <= 0;
        vga_accepted <= 0;
        fb_ddram_addr <= 0;
        fb_ddram_din <= 0;
        fb_ddram_be <= 0;
        fb_ddram_rd <= 0;
        fb_read_high_dword <= 0;
    end else begin
        vga_read <= 0;
        vga_write <= 0;
        vga_dout_ready <= 0;
        vga_wr_done <= 0;
        vga_accepted <= 0;
        fb_ddram_rd <= 0;
        case (state)
            IDLE: begin
                // set up vga access to point to 1st enabled byte
                if (!vga_fb_en) begin
                    vga_address[16:2] <= cpu_addr[16:2];
                    if (cpu_be[0]) begin
                        vga_address[1:0] <= 0;
                        vga_writedata <= cpu_din[7:0];
                        vga_be <= cpu_be[3:1];      // 3 bytes remaining
                        vga_bcnt <= 3;
                        vga_data <= cpu_din[31:8];  // remaining data
                    end else if (cpu_be[1]) begin
                        vga_address[1:0] <= 1;
                        vga_writedata <= cpu_din[15:8];
                        vga_be <= cpu_be[3:2];    // 2 bytes remaining
                        vga_bcnt <= 2;
                        vga_data <= cpu_din[31:16];
                    end else if (cpu_be[2]) begin
                        vga_address[1:0] <= 2;
                        vga_writedata <= cpu_din[23:16];
                        vga_be <= cpu_be[3:3];
                        vga_bcnt <= 1;
                        vga_data <= cpu_din[31:24];
                    end else begin
                        vga_address[1:0] <= 3;
                        vga_writedata <= cpu_din[31:24];
                        vga_be <= 0;
                        vga_bcnt <= 0;
                        vga_data <= 0;
                    end
                end

                if (cpu_valid && !cpu_write && !vga_rgn && !ram_address_in_range(cpu_addr, ram_size)) begin
                    vga_busy <= 1;
                    vga_bcnt <= cpu_burstcount == 0 ? 3'd1 : cpu_burstcount[2:0];
                    state <= UNMAPPED_READ;
                end else if (cpu_valid && vga_rgn) begin
                    vga_accepted <= 1;
                    vga_busy <= 1;
                    if (!cpu_write) begin
                        if (vga_fb_en) begin
                            // SVGA: read back from the DDR3 framebuffer (banked by vga_rd_seg)
                            state <= FB_READ;
                            if (vga_chain4) begin
                                fb_ddram_addr <= framebuffer_byte_address(vga_rd_seg) >> 3;
                                fb_read_high_dword <= cpu_addr[2];
                            end else begin
                                fb_ddram_addr <= framebuffer_byte_address(vga_rd_seg) >> 3;
                                fb_read_high_dword <= cpu_be[1] | cpu_be[3];
                            end
                        end else begin
                            state <= VGA_READ;
                            vga_read <= 1;
                        end
                    end else if (vga_fb_en) begin
                        // SVGA: write into the DDR3 linear framebuffer (banked by vga_wr_seg)
                        state <= FB_WRITE;
                        if (vga_chain4) begin
                            fb_ddram_addr <= framebuffer_byte_address(vga_wr_seg) >> 3;
                            fb_ddram_be   <= cpu_addr[2] ? {cpu_be, 4'b0}   : {4'b0,  cpu_be};
                            fb_ddram_din  <= cpu_addr[2] ? {cpu_din, 32'b0} : {32'b0, cpu_din};
                        end else begin
                            fb_ddram_addr <= framebuffer_byte_address(vga_wr_seg) >> 3;
                            fb_ddram_be   <= (cpu_be[1] | cpu_be[3]) ?
                                             {vga_map_mask, 4'b0} : {4'b0, vga_map_mask};
                            if (vga_write_mode == 2'd1) begin
                                fb_ddram_din <= (cpu_be[1] | cpu_be[3]) ?
                                                  {vga_data, 32'b0} : {32'b0, vga_data};
                            end else if (cpu_be[0]) begin
                                fb_ddram_din <= (cpu_be[1] | cpu_be[3]) ?
                                                  {{4{cpu_din[7:0]}}, 32'b0} :
                                                  {32'b0, {4{cpu_din[7:0]}}};
                            end else if (cpu_be[1]) begin
                                fb_ddram_din <= (cpu_be[1] | cpu_be[3]) ?
                                                  {{4{cpu_din[15:8]}}, 32'b0} :
                                                  {32'b0, {4{cpu_din[15:8]}}};
                            end else if (cpu_be[2]) begin
                                fb_ddram_din <= (cpu_be[1] | cpu_be[3]) ?
                                                  {{4{cpu_din[23:16]}}, 32'b0} :
                                                  {32'b0, {4{cpu_din[23:16]}}};
                            end else begin
                                fb_ddram_din <= (cpu_be[1] | cpu_be[3]) ?
                                                  {{4{cpu_din[31:24]}}, 32'b0} :
                                                  {32'b0, {4{cpu_din[31:24]}}};
                            end
                        end
                    end else begin
                        state <= VGA_WRITE;
                        vga_write <= 1;
                    end
                end
            end
            FB_WRITE:
                if (!fb_ddram_busy) begin   // DDR3 accepted the write
                    vga_wr_done <= 1;
                    state <= IDLE;
                    vga_busy <= 0;
                end
            FB_READ:
                if (!fb_ddram_busy) begin   // issue the read (1-cycle pulse)
                    fb_ddram_rd <= 1;
                    state <= FB_READ_WAIT;
                end
            FB_READ_WAIT:
                if (fb_ddram_dout_ready) begin
                    if (!vga_chain4) begin
                        // VGA reads load all four plane latches and return the
                        // selected plane. Replication makes the selected byte
                        // available in whichever CPU byte lane requested it.
                        vga_data <= fb_read_high_dword ?
                                      fb_ddram_dout[63:32] : fb_ddram_dout[31:0];
                        case (vga_read_plane)
                            2'd0: vga_dout <= {4{fb_read_high_dword ?
                                                  fb_ddram_dout[39:32] : fb_ddram_dout[7:0]}};
                            2'd1: vga_dout <= {4{fb_read_high_dword ?
                                                  fb_ddram_dout[47:40] : fb_ddram_dout[15:8]}};
                            2'd2: vga_dout <= {4{fb_read_high_dword ?
                                                  fb_ddram_dout[55:48] : fb_ddram_dout[23:16]}};
                            2'd3: vga_dout <= {4{fb_read_high_dword ?
                                                  fb_ddram_dout[63:56] : fb_ddram_dout[31:24]}};
                        endcase
                    end else begin
                        // CPU dword = high/low half of the 64-bit DDR3 word it addressed
                        vga_dout <= fb_read_high_dword ?
                                      fb_ddram_dout[63:32] : fb_ddram_dout[31:0];
                    end
                    vga_dout_ready <= 1;
                    state <= IDLE;
                    vga_busy <= 0;
                end
            UNMAPPED_READ: begin
                vga_dout <= 32'hFFFF_FFFF;
                vga_dout_ready <= 1;
                if (vga_bcnt <= 1) begin
                    vga_bcnt <= 0;
                    state <= IDLE;
                    vga_busy <= 0;
                end else begin
                    vga_bcnt <= vga_bcnt - 1'd1;
                end
            end
            VGA_READ:
                if (!vga_read) begin
                    vga_read <= vga_be[0];
                    vga_be <= vga_be[3:1];
                    vga_bcnt <= vga_bcnt - 1;
                    vga_address[1:0] <= vga_address[1:0] + 2'd1;
                    vga_dout <= {vga_readdata, vga_dout[31:8]};
                    if (vga_bcnt == 0) begin    // read vga_bcnt times so cpu_dout is shifted correctly
                        vga_dout_ready <= 1;
                        state <= IDLE;
                        vga_busy <= 0;
                    end
                end
            VGA_WRITE: begin
                if (!vga_write) begin
                    vga_write <= vga_be[0];
                    vga_be <= vga_be[3:1];
                    vga_address[1:0] <= vga_address[1:0] + 2'd1;
                    vga_writedata <= vga_data[7:0];
                    vga_data <= {8'h00, vga_data[31:8]};
                    if (!vga_be) begin
                        state <= IDLE;
                        vga_busy <= 0;
                        vga_wr_done <= 1;
                    end
                end
            end
            default: ;
        endcase
    end
end

always @(posedge clk) begin
	case (vga_memmode)
		3'b100:		// 128K
			begin
				vga_mask <= 2'b00;
				vga_cmp  <= 2'b00;
			end

		3'b101:		// lower 64K
			begin
				vga_mask <= 2'b10;
				vga_cmp  <= 2'b00;
			end

		3'b110:		// 3rd 32K
			begin
				vga_mask <= 2'b11;
				vga_cmp  <= 2'b10;
			end

		3'b111:		// top 32K
			begin
				vga_mask <= 2'b11;
				vga_cmp  <= 2'b11;
			end

		default :	// disable VGA RAM
			begin
				vga_mask <= 2'b00;
				vga_cmp  <= 2'b11;
			end
	endcase
end

endmodule
