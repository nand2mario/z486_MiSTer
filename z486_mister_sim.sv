//
// z486_MiSTer top level for Verilator simulation.
//
`timescale 1ns / 1ns

module z486_mister_sim (
	input         clk_sys,
	input         reset,
	input         clk_audio,

	input  [63:0] status,
	input   [7:0] sim_kbd_data,
	input         sim_kbd_data_valid,
	output  [8:0] sim_kbd_host_data,
	input         sim_kbd_host_data_clear,
	input   [7:0] sim_mouse_data,
	input         sim_mouse_data_valid,
	input         sim_soft_reset,

	input         ioctl_download,
	input  [15:0] ioctl_index,
	input         ioctl_wr,
	input  [26:0] ioctl_addr,
	input  [15:0] ioctl_dout,
	output        ioctl_wait,

	inout  [15:0] sdram_dq,
	output [12:0] sdram_a,
	output  [1:0] sdram_ba,
	output  [1:0] sdram_dqm,
	output        sdram_nwe,
	output        sdram_nras,
	output        sdram_ncas,
	output        sdram_ncs,
	output        sdram_cke,

	input         ddram_busy,
	output  [7:0] ddram_burstcnt,
	output [28:0] ddram_addr,
	input  [63:0] ddram_dout,
	input         ddram_dout_ready,
	output        ddram_rd,
	output [63:0] ddram_din,
	output  [7:0] ddram_be,
	output        ddram_we,

	output        ce_pixel,
	output  [7:0] video_r,
	output  [7:0] video_g,
	output  [7:0] video_b,
	output        video_hs,
	output        video_vs,
	output        video_de,
	output [19:0] fb_start_addr,
	output  [8:0] fb_width,
	output [10:0] fb_height,
	output  [8:0] fb_stride,
	output  [3:0] fb_flags,
	output        fb_off,
	output  [7:0] fb_pal_addr,
	output [17:0] fb_pal_data,
	output        fb_pal_wr,
	output [15:0] audio_l,
	output [15:0] audio_r,
	output [15:0] sample_sb_l,
	output [15:0] sample_sb_r,
	output        active,
	output        debug_bios_loaded_o,
	output        debug_first_instruction_o,

    input  [15:0] mgmt_address,
    input         mgmt_read,
    input         mgmt_write,
    input  [15:0] mgmt_writedata,
    output [15:0] mgmt_readdata,
    output [1:0]  fdd_request,
    output [2:0]  ide0_request,
    output [2:0]  ide1_request,

	output [15:0] dbg_cs,
	output [31:0] dbg_eip,
	output [31:0] dbg_cs_base,
	output        dbg_pe,
	output        dbg_vm,
	output  [7:0] dbg_post_code,
	output  [7:0] dbg_syscfg,
	output  [7:0] dbg_uart_byte,
	output        dbg_uart_we,
	output        soft_reset_req,

	// Optional PC+zSST integration diagnostics. These remain zero in the
	// ordinary MiSTer simulation build and become live in `make voodoo`.
	output        dbg_zsst_memory_enable,
	output [31:0] dbg_zsst_init_enable,
	output        dbg_zsst_video_active,
	output [31:0] dbg_zsst_host_reads,
	output [31:0] dbg_zsst_host_writes,
	output [31:0] dbg_zsst_memory_reads,
	output [31:0] dbg_zsst_memory_writes,
	output [31:0] dbg_zsst_pci_reads,
	output [31:0] dbg_zsst_pci_writes,
	output [31:0] dbg_zsst_pci_config_address,
	output [15:0] dbg_zsst_pci_last_io_address,
	output  [7:0] dbg_zsst_pci_last_writedata,
	output        dbg_zsst_pci_last_write,
	output [23:0] dbg_zsst_last_host_address,
	output [31:0] dbg_zsst_last_host_data,
	output        dbg_zsst_last_host_write,
	output        dbg_zsst_event_valid,
	output [23:0] dbg_zsst_event_address,
	output [31:0] dbg_zsst_event_data,
	output  [3:0] dbg_zsst_event_be,
	output        dbg_zsst_event_write,
	output        dbg_zsst_mem_write_valid,
	output [39:0] dbg_zsst_mem_write_address,
	output [127:0] dbg_zsst_mem_write_data,
	output [15:0] dbg_zsst_mem_write_strobe,
	output  [1:0] dbg_zsst_displayed_buffer,
	output [23:0] dbg_zsst_buffer_size,
	output [15:0] dbg_zsst_stride,
	output  [9:0] dbg_zsst_width,
	output  [9:0] dbg_zsst_height,

	// Co-simulation taps (verilator/cosim.cpp): the CPU's issue stream, its
	// data requests at acceptance (program order), read completions, direct
	// stores, and DMA writes into guest memory.
	output        cosim_cpu_reset_n,
	output        cosim_issue,
	output [31:0] cosim_issue_eip,
	output [31:0] cosim_ecx,
	output [31:0] cosim_eflags,
	output        cosim_a20,
	output        cosim_dreq_acc,
	output        cosim_dreq_write,
	output [31:0] cosim_dreq_addr,
	output  [3:0] cosim_dreq_be,
	output [31:0] cosim_dreq_wdata,
	output [31:0] cosim_dreq_wdata_direct,
	output  [4:0] cosim_dreq_kind,      // {walker, vga, x87, inta, io}
	output        cosim_drd_done,
	output [31:0] cosim_drd_data,
	output        cosim_fst_acc,
	output [31:0] cosim_fst_addr,
	output  [3:0] cosim_fst_be,
	output [31:0] cosim_fst_wdata,
	output        cosim_dma_wr,
	output [31:0] cosim_dma_addr,
	output  [3:0] cosim_dma_be,
	output [31:0] cosim_dma_wdata,
	output        cosim_bus_quiet,      // no CPU bus cycle requested, outstanding or buffered
	output [255:0] cosim_gprs           // EDI..EAX as an issuing instruction reads them
);

// The simulation build overrides this parameter for speed-sensitive testing.
parameter [27:0] CLOCK_RATE_HZ = 28'd20_000_000;
parameter ENABLE_X87 = 1'b1;

wire        software_reset;
reg  [7:0]  software_reset_count;
wire        core_reset = reset | (software_reset_count != 8'd0);
assign soft_reset_req = software_reset;

wire  [7:0] syscfg;
assign dbg_syscfg = syscfg;
wire  [1:0] cpu_speed_osd = {status[9] ^ status[8], status[8]};

reg   [7:0] mouse_data;
reg         mouse_data_valid;
wire  [8:0] mouse_host_cmd;
wire        mouse_host_cmd_clear = mouse_host_cmd[8];

reg  [31:0] mouse_reply_bytes_r;
reg   [2:0] mouse_reply_count_r;
reg   [7:0] pending_mouse_cmd_r;
reg         pending_mouse_arg_r;

wire [15:0] sample_opl_l;
wire [15:0] sample_opl_r;
wire  [8:0] sample_cms_l;
wire  [8:0] sample_cms_r;
wire        speaker_out;
wire        speaker_out_audio;
wire        sbp;
wire  [4:0] vol_master_l;
wire  [4:0] vol_master_r;
wire  [4:0] vol_voice_l;
wire  [4:0] vol_voice_r;
wire  [4:0] vol_cd_l;
wire  [4:0] vol_cd_r;
wire  [4:0] vol_midi_l;
wire  [4:0] vol_midi_r;
wire  [4:0] vol_line_l;
wire  [4:0] vol_line_r;
wire  [1:0] vol_spk;
wire  [4:0] vol_en;

wire [31:0] dbg_sd_avm_address;
wire [31:0] dbg_sd_avm_writedata;
wire        dbg_sd_avm_write;
wire        dbg_sd_avm_wait;
wire        dbg_sd_avm_accept;
wire [31:0] dbg_mm_addr;
wire [31:0] dbg_mm_din;
wire [31:0] dbg_mm_dout;
wire        dbg_mm_valid;
wire        dbg_mm_write;
wire        dbg_mm_ready;
wire        dbg_mm_resp_valid;
wire [31:0] dbg_mem_address;
wire [31:0] dbg_mem_din;
wire [31:0] dbg_mem_dout;
wire        dbg_mem_valid;
wire        dbg_mem_we;
wire        dbg_mem_ready;
wire        dbg_mem_resp_valid;
wire [31:0] dbg_avm_address;
wire [31:0] dbg_avm_readdata;
wire        dbg_avm_ready;
wire        dbg_avm_resp_valid;
wire [31:0] dbg_cpu_din_z;
wire  [2:0] debug_boot_stage;
wire        debug_sd_error;
wire        debug_bios_loaded;
wire        debug_vga_bios_sig_bad;
wire        debug_vga_bios_sig_checked;
wire        debug_first_instruction;
wire        debug_post_write;
wire  [7:0] dbg_uart_byte_w;
wire        dbg_uart_we_w;
wire        video_ce;
wire        video_blank_n;
wire        video_hsync;
wire        video_vsync;
wire  [7:0] video_r_w;
wire  [7:0] video_g_w;
wire  [7:0] video_b_w;
wire        dummy_sd_clk;
wire        dummy_sd_cmd;
wire  [3:0] dummy_sd_dat;
wire        sim_ps2_kbd_clk;
wire        sim_ps2_kbd_dat;
wire        sim_ps2_kbd_clk_fb;
wire        sim_ps2_kbd_dat_fb;
wire        sim_ps2_mouse_clk;
wire        sim_ps2_mouse_dat;
wire        sim_ps2_mouse_clk_fb;
wire        sim_ps2_mouse_dat_fb;
wire  [8:0] sim_kbd_host_data_w;
wire  [7:0] mouse_tx_data;
wire        mouse_tx_valid;

assign sim_kbd_host_data = sim_kbd_host_data_w;
assign mouse_tx_data = mouse_data_valid ? mouse_data : sim_mouse_data;
assign mouse_tx_valid = mouse_data_valid | (sim_mouse_data_valid & ~mouse_data_valid);

assign active = debug_first_instruction | debug_post_write | sim_kbd_data_valid | sim_mouse_data_valid | mouse_data_valid;

logic clk_ps2;
localparam PS2DIV = 1000;      // ~12.5kHz from 25MHz
always_ff @(posedge clk_sys) begin
	integer cnt;
	cnt <= cnt + 1;
	if (cnt == PS2DIV) begin
		clk_ps2 <= ~clk_ps2;
		cnt <= 0;
	end
end

z486_ps2_device ps2_kbd_sim (
	.clk_sys     (clk_sys),
	.reset       (reset),
	.ps2_clk     (clk_ps2),
	.wdata       (sim_kbd_data),
	.we          (sim_kbd_data_valid),
	.ps2_clk_out (sim_ps2_kbd_clk),
	.ps2_dat_out (sim_ps2_kbd_dat),
	.tx_empty    (),
	.ps2_clk_in  (sim_ps2_kbd_clk_fb),
	.ps2_dat_in  (sim_ps2_kbd_dat_fb),
	.rdata       (sim_kbd_host_data_w),
	.rd          (sim_kbd_host_data_clear)
);

z486_ps2_device ps2_mouse_sim (
	.clk_sys     (clk_sys),
	.reset       (reset),
	.ps2_clk     (clk_ps2),
	.wdata       (mouse_tx_data),
	.we          (mouse_tx_valid),
	.ps2_clk_out (sim_ps2_mouse_clk),
	.ps2_dat_out (sim_ps2_mouse_dat),
	.tx_empty    (),
	.ps2_clk_in  (sim_ps2_mouse_clk_fb),
	.ps2_dat_in  (sim_ps2_mouse_dat_fb),
	.rdata       (mouse_host_cmd),
	.rd          (mouse_host_cmd_clear)
);

always @(posedge clk_sys) begin
	if (reset) begin
		software_reset_count <= 8'd0;
`ifdef VERILATOR
	end else if (software_reset | sim_soft_reset) begin
`else
	end else if (sim_soft_reset) begin
`endif
		software_reset_count <= 8'hff;
	end else if (software_reset_count != 8'd0) begin
		software_reset_count <= software_reset_count - 8'd1;
	end
end

always @(posedge clk_sys) begin
	mouse_data_valid <= 1'b0;

	if (reset) begin
		mouse_reply_bytes_r <= 32'd0;
		mouse_reply_count_r <= 3'd0;
		pending_mouse_cmd_r <= 8'd0;
		pending_mouse_arg_r <= 1'b0;
		mouse_data <= 8'd0;
	end else begin
		if (mouse_reply_count_r != 3'd0) begin
			mouse_data <= mouse_reply_bytes_r[7:0];
			mouse_data_valid <= 1'b1;
			mouse_reply_bytes_r <= {8'd0, mouse_reply_bytes_r[31:8]};
			mouse_reply_count_r <= mouse_reply_count_r - 3'd1;
		end else if (mouse_host_cmd[8]) begin
			if (pending_mouse_arg_r) begin
				mouse_reply_bytes_r <= {24'd0, 8'hFA};
				mouse_reply_count_r <= 3'd1;
				pending_mouse_cmd_r <= 8'd0;
				pending_mouse_arg_r <= 1'b0;
			end else begin
				pending_mouse_cmd_r <= mouse_host_cmd[7:0];
				case (mouse_host_cmd[7:0])
					8'hFF: begin
						// Reset: ACK, BAT OK, standard PS/2 mouse ID.
						mouse_reply_bytes_r <= {8'd0, 8'h00, 8'hAA, 8'hFA};
						mouse_reply_count_r <= 3'd3;
						pending_mouse_cmd_r <= 8'd0;
					end
					8'hF2: begin
						// Identify: ACK, standard PS/2 mouse ID.
						mouse_reply_bytes_r <= {16'd0, 8'h00, 8'hFA};
						mouse_reply_count_r <= 3'd2;
						pending_mouse_cmd_r <= 8'd0;
					end
					8'hE9: begin
						// Status request: ACK, status, resolution, sample rate.
						mouse_reply_bytes_r <= {8'h64, 8'h02, 8'h00, 8'hFA};
						mouse_reply_count_r <= 3'd4;
						pending_mouse_cmd_r <= 8'd0;
					end
					8'hEB: begin
						// Read data: ACK plus a neutral three-byte packet.
						mouse_reply_bytes_r <= {8'h00, 8'h00, 8'h08, 8'hFA};
						mouse_reply_count_r <= 3'd4;
						pending_mouse_cmd_r <= 8'd0;
					end
					8'hE8,
					8'hF3: begin
						// Resolution/sample-rate commands consume one parameter.
						mouse_reply_bytes_r <= {24'd0, 8'hFA};
						mouse_reply_count_r <= 3'd1;
						pending_mouse_arg_r <= 1'b1;
					end
					default: begin
						mouse_reply_bytes_r <= {24'd0, 8'hFA};
						mouse_reply_count_r <= 3'd1;
						pending_mouse_cmd_r <= 8'd0;
					end
				endcase
			end
		end
	end
end

wire guest_mem_busy;
wire [31:0] guest_mem0_addr, guest_mem0_din, guest_mem0_dout;
wire  [3:0] guest_mem0_be;
wire  [7:0] guest_mem0_burstcount;
wire guest_mem0_resp_valid, guest_mem0_ready, guest_mem0_valid, guest_mem0_write;
wire [31:0] guest_mem1_addr, guest_mem1_din, guest_mem1_dout;
wire  [3:0] guest_mem1_be;
wire  [7:0] guest_mem1_burstcount;
wire guest_mem1_resp_valid, guest_mem1_ready, guest_mem1_valid, guest_mem1_write;

wire        zsst_host_req_valid;
wire        zsst_host_req_ready;
wire [23:0] zsst_host_address;
wire [31:0] zsst_host_writedata;
wire  [3:0] zsst_host_byteenable;
wire        zsst_host_write;
wire        zsst_host_rsp_valid;
wire        zsst_host_rsp_ready;
wire [31:0] zsst_host_readdata;
wire        zsst_host_error;
wire        zsst_memory_enable;
wire [31:0] zsst_init_enable;

`ifdef Z486_WB_SIM
wire [127:0] wb_line_data;
wire wb_line_valid, wb_line_read, wb_ready;
wire wb_aux_busy,wb_aux_ready,wb_aux_rd,wb_aux_we;
wire [28:0] wb_aux_addr;
wire [63:0] wb_aux_dout,wb_aux_din;
wire [7:0] wb_aux_be;
assign guest_mem_busy=!wb_ready;
assign ddram_rd=0;
assign ddram_we=0;
assign ddram_addr=0;
assign ddram_din=0;
assign ddram_be=0;
z486_wb_sim_memory simulated_kv260_memory(
    .aclk(clk_sys),.aresetn(!reset),.memory_base(40'd0),
    .cache_invalidate(core_reset),.cache_ready(wb_ready),
    .mem0_valid(guest_mem0_valid),.mem0_ready(guest_mem0_ready),
    .mem0_write(guest_mem0_write),.mem0_addr(guest_mem0_addr),
    .mem0_din(guest_mem0_din),.mem0_dout(guest_mem0_dout),.mem0_be(guest_mem0_be),
    .mem0_resp_valid(guest_mem0_resp_valid),.mem0_line_read(wb_line_read),
    .mem0_line_dout(wb_line_data),.mem0_line_resp_valid(wb_line_valid),
    .mem1_valid(guest_mem1_valid),.mem1_ready(guest_mem1_ready),
    .mem1_write(guest_mem1_write),.mem1_addr(guest_mem1_addr),
    .mem1_din(guest_mem1_din),.mem1_dout(guest_mem1_dout),.mem1_be(guest_mem1_be),
    .mem1_resp_valid(guest_mem1_resp_valid),
    .aux_rd(wb_aux_rd),.aux_we(wb_aux_we),.aux_addr(wb_aux_addr),
    .aux_din(wb_aux_din),.aux_be(wb_aux_be),.aux_busy(wb_aux_busy),
    .aux_dout(wb_aux_dout),.aux_dout_ready(wb_aux_ready)
);
`else
split_sdram_backend #(
	.FREQ(CLOCK_RATE_HZ),
	.HAS_DQM(1'b0),
	.FAST_GRADE(1'b1)
) simulated_de10_guest_memory (
	.clk(clk_sys), .reset(core_reset), .refresh_allowed(1'b1),
	.sdram_size(2'd3), .busy(guest_mem_busy),
	.mem0_valid(guest_mem0_valid), .mem0_ready(guest_mem0_ready),
	.mem0_write(guest_mem0_write), .mem0_addr(guest_mem0_addr),
	.mem0_din(guest_mem0_din), .mem0_dout(guest_mem0_dout),
	.mem0_resp_valid(guest_mem0_resp_valid), .mem0_be(guest_mem0_be),
	.mem0_burstcount(guest_mem0_burstcount),
	.mem1_valid(guest_mem1_valid), .mem1_ready(guest_mem1_ready),
	.mem1_write(guest_mem1_write), .mem1_addr(guest_mem1_addr),
	.mem1_din(guest_mem1_din), .mem1_dout(guest_mem1_dout),
	.mem1_resp_valid(guest_mem1_resp_valid), .mem1_be(guest_mem1_be),
	.mem1_burstcount(guest_mem1_burstcount),
	.sdram_dq(sdram_dq), .sdram_a(sdram_a), .sdram_ba(sdram_ba),
	.sdram_dqm(sdram_dqm), .sdram_nwe(sdram_nwe),
	.sdram_nras(sdram_nras), .sdram_ncas(sdram_ncas),
	.sdram_ncs(sdram_ncs), .sdram_cke(sdram_cke)
);
`endif

system #(
	.SYS_FREQ(CLOCK_RATE_HZ),
	.DCACHE_SET_BITS(7),   // DEBUG: reproduce 8KB doom crash
	.ICACHE_SET_BITS(7),
	.ENABLE_X87(ENABLE_X87),
	.ENABLE_CMS(1'b0),
`ifdef Z486_VOODOO
	.ENABLE_VOODOO(1'b1)
`else
	.ENABLE_VOODOO(1'b0)
`endif
) system_i (
	.clk_sys             (clk_sys),
	.reset               (core_reset),
	.hps_apply_reset     (status[0]),
	.software_reset      (software_reset),
	.clock_rate          (CLOCK_RATE_HZ),

	.fdd_request         (fdd_request),
	.ide0_request        (ide0_request),
	.ide1_request        (ide1_request),
	.floppy_wp           (2'b00),

    .mgmt_address        (mgmt_address),
    .mgmt_read           (mgmt_read),
    .mgmt_readdata       (mgmt_readdata),
    .mgmt_write          (mgmt_write),
    .mgmt_writedata      (mgmt_writedata),

	.ext_mem_busy        (guest_mem_busy),
	.ext_mem0_addr       (guest_mem0_addr),
	.ext_mem0_din        (guest_mem0_din),
	.ext_mem0_dout       (guest_mem0_dout),
	.ext_mem0_resp_valid (guest_mem0_resp_valid),
`ifdef Z486_WB_SIM
	.ext_mem0_line_dout  (wb_line_data),
	.ext_mem0_line_resp_valid(wb_line_valid),
	.ext_mem0_line_read  (wb_line_read),
`else
	.ext_mem0_line_dout  (128'd0),
	.ext_mem0_line_resp_valid(1'b0),
	.ext_mem0_line_read  (),
`endif
	.ext_mem0_be         (guest_mem0_be),
	.ext_mem0_burstcount (guest_mem0_burstcount),
	.ext_mem0_ready      (guest_mem0_ready),
	.ext_mem0_valid      (guest_mem0_valid),
	.ext_mem0_write      (guest_mem0_write),
	.ext_mem1_addr       (guest_mem1_addr),
	.ext_mem1_din        (guest_mem1_din),
	.ext_mem1_dout       (guest_mem1_dout),
	.ext_mem1_resp_valid (guest_mem1_resp_valid),
	.ext_mem1_be         (guest_mem1_be),
	.ext_mem1_burstcount (guest_mem1_burstcount),
	.ext_mem1_ready      (guest_mem1_ready),
	.ext_mem1_valid      (guest_mem1_valid),
	.ext_mem1_write      (guest_mem1_write),

`ifdef Z486_WB_SIM
	.ddram_busy          (wb_aux_busy),
	.ddram_burstcnt      (ddram_burstcnt),
	.ddram_addr          (wb_aux_addr),
	.ddram_dout          (wb_aux_dout),
	.ddram_dout_ready    (wb_aux_ready),
	.ddram_rd            (wb_aux_rd),
	.ddram_din           (wb_aux_din),
	.ddram_be            (wb_aux_be),
	.ddram_we            (wb_aux_we),
`else
	.ddram_busy          (ddram_busy),
	.ddram_burstcnt      (ddram_burstcnt),
	.ddram_addr          (ddram_addr),
	.ddram_dout          (ddram_dout),
	.ddram_dout_ready    (ddram_dout_ready),
	.ddram_rd            (ddram_rd),
	.ddram_din           (ddram_din),
	.ddram_be            (ddram_be),
	.ddram_we            (ddram_we),
`endif


	.sd_clk              (dummy_sd_clk),
	.sd_cmd              (dummy_sd_cmd),
	.sd_dat              (dummy_sd_dat),

	.ioctl_download      (ioctl_download),
	.ioctl_index         (ioctl_index),
	.ioctl_wr            (ioctl_wr),
	.ioctl_addr          (ioctl_addr),
	.ioctl_dout          (ioctl_dout),
	.ioctl_wait          (ioctl_wait),
	.img_mounted         (1'b0),
	.img_readonly        (1'b0),
	.img_size            (64'd0),
	.img_ack             (1'b0),
	.img_buff_din        (16'd0),

	.ps2_kbclk_in        (sim_ps2_kbd_clk),
	.ps2_kbdat_in        (sim_ps2_kbd_dat),
	.ps2_kbclk_out       (sim_ps2_kbd_clk_fb),
	.ps2_kbdat_out       (sim_ps2_kbd_dat_fb),

	.ps2_mouseclk_in     (sim_ps2_mouse_clk),
	.ps2_mousedat_in     (sim_ps2_mouse_dat),
	.ps2_mouseclk_out    (sim_ps2_mouse_clk_fb),
	.ps2_mousedat_out    (sim_ps2_mouse_dat_fb),
	.mouse_data          (8'd0),
	.mouse_data_valid    (1'b0),
	.mouse_host_cmd      (),
	.mouse_host_cmd_clear(1'b0),
	.zsst_host_req_valid (zsst_host_req_valid),
	.zsst_host_req_ready (zsst_host_req_ready),
	.zsst_host_address   (zsst_host_address),
	.zsst_host_writedata (zsst_host_writedata),
	.zsst_host_byteenable(zsst_host_byteenable),
	.zsst_host_write     (zsst_host_write),
	.zsst_host_rsp_valid (zsst_host_rsp_valid),
	.zsst_host_rsp_ready (zsst_host_rsp_ready),
	.zsst_host_readdata  (zsst_host_readdata),
	.zsst_host_error     (zsst_host_error),
	.zsst_memory_enable  (zsst_memory_enable),
	.zsst_init_enable    (zsst_init_enable),

	.dbg_uart_byte       (dbg_uart_byte_w),
	.dbg_uart_we         (dbg_uart_we_w),

	.dbg_sd_avm_address  (dbg_sd_avm_address),
	.dbg_sd_avm_writedata(dbg_sd_avm_writedata),
	.dbg_sd_avm_write    (dbg_sd_avm_write),
	.dbg_sd_avm_wait     (dbg_sd_avm_wait),
	.dbg_sd_avm_accept   (dbg_sd_avm_accept),
	.dbg_mm_addr         (dbg_mm_addr),
	.dbg_mm_din          (dbg_mm_din),
	.dbg_mm_dout         (dbg_mm_dout),
	.dbg_mm_valid        (dbg_mm_valid),
	.dbg_mm_write        (dbg_mm_write),
	.dbg_mm_ready        (dbg_mm_ready),
	.dbg_mm_resp_valid   (dbg_mm_resp_valid),
	.dbg_mem_address     (dbg_mem_address),
	.dbg_mem_din         (dbg_mem_din),
	.dbg_mem_dout        (dbg_mem_dout),
	.dbg_mem_valid       (dbg_mem_valid),
	.dbg_mem_we          (dbg_mem_we),
	.dbg_mem_ready       (dbg_mem_ready),
	.dbg_mem_resp_valid  (dbg_mem_resp_valid),
	.dbg_avm_address     (dbg_avm_address),
	.dbg_avm_readdata    (dbg_avm_readdata),
	.dbg_avm_ready       (dbg_avm_ready),
	.dbg_avm_resp_valid  (dbg_avm_resp_valid),
	.dbg_cpu_din_z       (dbg_cpu_din_z),

	.bootcfg             ({4'd0, status[2:1]}),
	.ram_size            (status[62:61] + 2'd2), // OSD index 0-3 = 64/128/16/32MB
	.uma_ram             (1'b0),
	.cpu_speed_osd      (cpu_speed_osd),
	.fast_off           (1'b0),          // sim: +z486_fast_off / +z486_fast_toggle=N
	.cache_off          (1'b0),          // sim: +z486_cache_off / +z486_cache_toggle=N
	.x87_off            (1'b0),          // sim: +z486_x87_off
	.syscfg              (syscfg),

	.video_ce            (video_ce),
	.video_blank_n       (video_blank_n),
	.video_hsync         (video_hsync),
	.video_vsync         (video_vsync),
	.video_r             (video_r_w),
	.video_g             (video_g_w),
	.video_b             (video_b_w),
	.video_f60           (~status[4]),
	.video_border        (~status[54]),
	.video_scanline_req  (1'b0),
	.video_scanline_ready(),
	.video_scanline_frame_start(1'b0),
	.video_scanline_y    (11'd0),
	.video_scanline_width(),
	.video_scanline_height(),
	.video_native_frames(),
	.video_scanline_done (),
	.video_start_addr    (fb_start_addr),
	.video_width         (fb_width),
	.video_height        (fb_height),
	.video_stride        (fb_stride),
	.video_flags         (fb_flags),
	.video_off           (fb_off),
	.video_pal_a         (fb_pal_addr),
	.video_pal_d         (fb_pal_data),
	.video_pal_we        (fb_pal_wr),

	.clk_audio           (clk_audio),
	.sample_cms_l        (sample_cms_l),
	.sample_cms_r        (sample_cms_r),
	.sample_sb_l         (sample_sb_l),
	.sample_sb_r         (sample_sb_r),
	.sample_opl_l        (sample_opl_l),
	.sample_opl_r        (sample_opl_r),
	.sound_fm_mode       (~status[57]),
	.sound_cms_en        (1'b0),
	.speaker_out         (speaker_out),
	.sbp                 (sbp),
	.vol_master_l        (vol_master_l),
	.vol_master_r        (vol_master_r),
	.vol_voice_l         (vol_voice_l),
	.vol_voice_r         (vol_voice_r),
	.vol_cd_l            (vol_cd_l),
	.vol_cd_r            (vol_cd_r),
	.vol_midi_l          (vol_midi_l),
	.vol_midi_r          (vol_midi_r),
	.vol_line_l          (vol_line_l),
	.vol_line_r          (vol_line_r),
	.vol_spk             (vol_spk),
	.vol_en              (vol_en),

	.debug_boot_stage    (debug_boot_stage),
	.debug_sd_error      (debug_sd_error),
	.debug_bios_loaded   (debug_bios_loaded),
	.debug_vga_bios_sig_bad(debug_vga_bios_sig_bad),
	.debug_vga_bios_sig_checked(debug_vga_bios_sig_checked),
	.debug_first_instruction(debug_first_instruction),
	.debug_post_code     (dbg_post_code),
	.debug_post_write    (debug_post_write),

	.cpu_pe              (dbg_pe),
	.cpu_vm              (dbg_vm),
	.cpu_cs              (dbg_cs),
	.cpu_eip             (dbg_eip),
	.cpu_cs_base         (dbg_cs_base)
);

assign dbg_zsst_memory_enable = zsst_memory_enable;
assign dbg_zsst_init_enable = zsst_init_enable;

`ifdef Z486_VOODOO
import sst1_pkg::*;

sst1_host_req_t zsst_sim_host_req;
sst1_host_rsp_t zsst_sim_host_rsp;
sst1_mem_req_t zsst_sim_mem_req;
sst1_mem_rsp_t zsst_sim_mem_rsp;
sst1_debug_host_event_t zsst_sim_debug_event;
wire zsst_sim_mem_req_valid, zsst_sim_mem_req_ready;
wire zsst_sim_mem_rsp_valid, zsst_sim_mem_rsp_ready;
wire zsst_sim_debug_event_valid;
wire [31:0] zsst_sim_outstanding_writes;
wire zsst_sim_video_active;
wire [1:0] zsst_sim_displayed_buffer;
wire [31:0] zsst_sim_video_dimensions;
reg [31:0] zsst_sim_host_reads_r, zsst_sim_host_writes_r;
reg [31:0] zsst_sim_memory_reads_r, zsst_sim_memory_writes_r;
reg [31:0] zsst_sim_pci_reads_r, zsst_sim_pci_writes_r;
reg [15:0] zsst_sim_pci_last_io_address_r;
reg [7:0] zsst_sim_pci_last_writedata_r;
reg zsst_sim_pci_last_write_r;
reg [23:0] zsst_sim_last_host_address_r;
reg [31:0] zsst_sim_last_host_data_r;
reg zsst_sim_last_host_write_r;
reg [23:0] zsst_sim_pending_read_address_r;
reg zsst_sim_pending_read_r;
reg [31:0] zsst_sim_retrace_counter_r;
reg [23:0] zsst_sim_buffer_size_r;
reg [15:0] zsst_sim_stride_r;
reg zsst_sim_mem_write_valid_r;
reg [39:0] zsst_sim_mem_write_address_r;
reg [127:0] zsst_sim_mem_write_data_r;
reg [15:0] zsst_sim_mem_write_strobe_r;
localparam [31:0] ZSST_SIM_FRAME_CYCLES = CLOCK_RATE_HZ / 60;
localparam [31:0] ZSST_SIM_RETRACE_CYCLES = CLOCK_RATE_HZ / 600;
wire zsst_sim_v_retrace =
	zsst_sim_retrace_counter_r < ZSST_SIM_RETRACE_CYCLES;

assign zsst_sim_host_req.addr = zsst_host_address;
assign zsst_sim_host_req.wdata = zsst_host_writedata;
assign zsst_sim_host_req.be = zsst_host_byteenable;
assign zsst_sim_host_req.write = zsst_host_write;
assign zsst_host_readdata = zsst_sim_host_rsp.rdata;
assign zsst_host_error = zsst_sim_host_rsp.error;

assign dbg_zsst_video_active = zsst_sim_video_active;
assign dbg_zsst_host_reads = zsst_sim_host_reads_r;
assign dbg_zsst_host_writes = zsst_sim_host_writes_r;
assign dbg_zsst_memory_reads = zsst_sim_memory_reads_r;
assign dbg_zsst_memory_writes = zsst_sim_memory_writes_r;
assign dbg_zsst_pci_reads = zsst_sim_pci_reads_r;
assign dbg_zsst_pci_writes = zsst_sim_pci_writes_r;
assign dbg_zsst_pci_config_address = system_i.zsst_pci_config.config_address;
assign dbg_zsst_pci_last_io_address = zsst_sim_pci_last_io_address_r;
assign dbg_zsst_pci_last_writedata = zsst_sim_pci_last_writedata_r;
assign dbg_zsst_pci_last_write = zsst_sim_pci_last_write_r;
assign dbg_zsst_last_host_address = zsst_sim_last_host_address_r;
assign dbg_zsst_last_host_data = zsst_sim_last_host_data_r;
assign dbg_zsst_last_host_write = zsst_sim_last_host_write_r;
assign dbg_zsst_event_valid = zsst_sim_debug_event_valid;
assign dbg_zsst_event_address = {zsst_sim_debug_event.region,
					 zsst_sim_debug_event.region_offset};
assign dbg_zsst_event_data = zsst_sim_debug_event.data;
assign dbg_zsst_event_be = zsst_sim_debug_event.be;
assign dbg_zsst_event_write = zsst_sim_debug_event.write;
assign dbg_zsst_mem_write_valid = zsst_sim_mem_write_valid_r;
assign dbg_zsst_mem_write_address = zsst_sim_mem_write_address_r;
assign dbg_zsst_mem_write_data = zsst_sim_mem_write_data_r;
assign dbg_zsst_mem_write_strobe = zsst_sim_mem_write_strobe_r;
assign dbg_zsst_displayed_buffer = zsst_sim_displayed_buffer;
assign dbg_zsst_buffer_size = zsst_sim_buffer_size_r;
assign dbg_zsst_stride = zsst_sim_stride_r;
assign dbg_zsst_width = zsst_sim_video_dimensions[21:0] == 0 ? 10'd640 :
			zsst_sim_video_dimensions[9:0] + 1'b1;
assign dbg_zsst_height = zsst_sim_video_dimensions[25:16] == 0 ? 10'd480 :
			 zsst_sim_video_dimensions[25:16];

always @(posedge clk_sys) begin
	if (core_reset) begin
		zsst_sim_host_reads_r <= 0;
		zsst_sim_host_writes_r <= 0;
		zsst_sim_memory_reads_r <= 0;
		zsst_sim_memory_writes_r <= 0;
		zsst_sim_pci_reads_r <= 0;
		zsst_sim_pci_writes_r <= 0;
		zsst_sim_pci_last_io_address_r <= 0;
		zsst_sim_pci_last_writedata_r <= 0;
		zsst_sim_pci_last_write_r <= 0;
		zsst_sim_last_host_address_r <= 0;
		zsst_sim_last_host_data_r <= 0;
		zsst_sim_last_host_write_r <= 0;
		zsst_sim_pending_read_address_r <= 0;
		zsst_sim_pending_read_r <= 0;
		zsst_sim_retrace_counter_r <= 0;
		zsst_sim_buffer_size_r <= 24'h10_0000;
		zsst_sim_stride_r <= 16'd1280;
		zsst_sim_mem_write_valid_r <= 1'b0;
		zsst_sim_mem_write_address_r <= 40'd0;
		zsst_sim_mem_write_data_r <= 128'd0;
		zsst_sim_mem_write_strobe_r <= 16'd0;
	end else begin
		zsst_sim_mem_write_valid_r <= 1'b0;
		if (system_i.zsst_pci_chip_select_raw &&
		    (system_i.iobus_read || system_i.iobus_write)) begin
			zsst_sim_pci_last_io_address_r <= system_i.iobus_address;
			zsst_sim_pci_last_writedata_r <= system_i.iobus_write ?
				system_i.iobus_writedata_byte : system_i.iobus_readdata8;
			zsst_sim_pci_last_write_r <= system_i.iobus_write;
			if (system_i.iobus_write)
				zsst_sim_pci_writes_r <= zsst_sim_pci_writes_r + 1'b1;
			else
				zsst_sim_pci_reads_r <= zsst_sim_pci_reads_r + 1'b1;
		end
		if (zsst_host_req_valid && zsst_host_req_ready) begin
			if (zsst_host_write) begin
				zsst_sim_last_host_address_r <= zsst_host_address;
				zsst_sim_last_host_data_r <= zsst_host_writedata;
				zsst_sim_last_host_write_r <= 1'b1;
				zsst_sim_host_writes_r <= zsst_sim_host_writes_r + 1'b1;
			end else begin
				zsst_sim_pending_read_address_r <= zsst_host_address;
				zsst_sim_pending_read_r <= 1'b1;
			end
		end
		if (zsst_sim_pending_read_r && zsst_host_rsp_valid &&
		    zsst_host_rsp_ready) begin
			zsst_sim_last_host_address_r <= zsst_sim_pending_read_address_r;
			zsst_sim_last_host_data_r <= zsst_sim_host_rsp.rdata;
			zsst_sim_last_host_write_r <= 1'b0;
			zsst_sim_host_reads_r <= zsst_sim_host_reads_r + 1'b1;
			zsst_sim_pending_read_r <= 1'b0;
		end
		if (zsst_sim_mem_req_valid && zsst_sim_mem_req_ready) begin
			if (zsst_sim_mem_req.write) begin
				zsst_sim_memory_writes_r <= zsst_sim_memory_writes_r + 1'b1;
				zsst_sim_mem_write_valid_r <= 1'b1;
				zsst_sim_mem_write_address_r <= zsst_sim_mem_req.addr;
				zsst_sim_mem_write_data_r <= zsst_sim_mem_req.wdata;
				zsst_sim_mem_write_strobe_r <= zsst_sim_mem_req.wstrb;
			end else
				zsst_sim_memory_reads_r <= zsst_sim_memory_reads_r + 1'b1;
		end
		if (zsst_host_req_valid && zsst_host_req_ready && zsst_host_write &&
		    zsst_init_enable[0]) begin
			case (zsst_host_address)
				24'h000214: zsst_sim_stride_r <=
					{5'd0, zsst_host_writedata[7:4], 7'd0};
				24'h000218: zsst_sim_buffer_size_r <=
					{15'd0, zsst_host_writedata[19:11]} << 12;
				default: ;
			endcase
		end
		if (zsst_sim_retrace_counter_r == ZSST_SIM_FRAME_CYCLES - 1)
			zsst_sim_retrace_counter_r <= 0;
		else
			zsst_sim_retrace_counter_r <= zsst_sim_retrace_counter_r + 1'b1;
	end
end

sst1_device zsst_sim_device (
	.clk(clk_sys), .reset_n(!core_reset),
	.init_write_enable(zsst_init_enable[0]),
	.init_remap_enable(zsst_init_enable[2]),
	.memory_enable(zsst_memory_enable),
	.memory_writes_idle(zsst_sim_outstanding_writes == 0),
	.fbi_memory_base(40'h0000_000000), .fbi_memory_size(24'h800000),
	.texture_memory_base(40'h0000_800000), .texture_memory_size(24'h800000),
	// DOS Glide waits for a retrace interval with vRetrace in [10,100].
	// Model a 10% vertical-blank duty cycle rather than a one-clock pulse.
	.v_retrace(zsst_sim_v_retrace),
	.v_retrace_count(zsst_sim_v_retrace ? 12'd50 : 12'd0),
	.scanout_rgb565(16'd0), .scanout_rgb888(),
	.displayed_buffer(zsst_sim_displayed_buffer),
	.swaps_pending(), .swap_event(),
	.video_frame_count(), .video_hsync_register(), .video_vsync_register(),
	.video_backporch_register(),
	.video_dimensions_register(zsst_sim_video_dimensions),
	.video_active(zsst_sim_video_active),
	.host_req_valid(zsst_host_req_valid), .host_req_ready(zsst_host_req_ready),
	.host_req(zsst_sim_host_req), .host_rsp_valid(zsst_host_rsp_valid),
	.host_rsp_ready(zsst_host_rsp_ready), .host_rsp(zsst_sim_host_rsp),
	.mem_req_valid(zsst_sim_mem_req_valid),
	.mem_req_ready(zsst_sim_mem_req_ready), .mem_req(zsst_sim_mem_req),
	.mem_rsp_valid(zsst_sim_mem_rsp_valid),
	.mem_rsp_ready(zsst_sim_mem_rsp_ready), .mem_rsp(zsst_sim_mem_rsp),
	.debug_host_event_valid(zsst_sim_debug_event_valid),
	.debug_host_event(zsst_sim_debug_event), .fifo_free(), .busy(),
	.pixels_in(), .chroma_fail(), .zfunc_fail(), .afunc_fail(),
	.pixels_out(), .last_alpha(), .last_w(), .perf_snapshot(1'b0),
	.perf_clear(1'b0), .perf_read_index(7'd0), .perf_read_data(),
	.perf_pending()
);

// The deterministic zSST DDR model is sufficient for PCI/Glide discovery and
// command-flow diagnosis. It deliberately returns address-pattern data rather
// than storing a full framebuffer; renderer correctness remains covered by the
// portable zSST scene and replay suites.
sst1_ddr_model #(
	.MIN_READ_LATENCY(4), .READ_JITTER(0), .LONG_DELAY_PERIOD(0),
	.WRITE_SERVICE_CYCLES(1), .REORDER_RESPONSES(1'b0),
	.STORE_MEMORY(1'b1), .MEMORY_BYTES(16 * 1024 * 1024)
) zsst_sim_memory (
	.clk(clk_sys), .reset_n(!core_reset),
	.req_valid(zsst_sim_mem_req_valid), .req_ready(zsst_sim_mem_req_ready),
	.req(zsst_sim_mem_req), .rsp_valid(zsst_sim_mem_rsp_valid),
	.rsp_ready(zsst_sim_mem_rsp_ready), .rsp(zsst_sim_mem_rsp),
	.cycles(), .read_requests(), .read_beats(), .write_requests(),
	.outstanding_reads(), .max_outstanding_reads(),
	.outstanding_writes(zsst_sim_outstanding_writes), .idle()
);
`else
assign zsst_host_req_ready = 1'b0;
assign zsst_host_rsp_valid = 1'b0;
assign zsst_host_readdata = 32'd0;
assign zsst_host_error = 1'b0;
assign dbg_zsst_video_active = 1'b0;
assign dbg_zsst_host_reads = 32'd0;
assign dbg_zsst_host_writes = 32'd0;
assign dbg_zsst_memory_reads = 32'd0;
assign dbg_zsst_memory_writes = 32'd0;
assign dbg_zsst_pci_reads = 32'd0;
assign dbg_zsst_pci_writes = 32'd0;
assign dbg_zsst_pci_config_address = 32'd0;
assign dbg_zsst_pci_last_io_address = 16'd0;
assign dbg_zsst_pci_last_writedata = 8'd0;
assign dbg_zsst_pci_last_write = 1'b0;
assign dbg_zsst_last_host_address = 24'd0;
assign dbg_zsst_last_host_data = 32'd0;
assign dbg_zsst_last_host_write = 1'b0;
assign dbg_zsst_event_valid = 1'b0;
assign dbg_zsst_event_address = 24'd0;
assign dbg_zsst_event_data = 32'd0;
assign dbg_zsst_event_be = 4'd0;
assign dbg_zsst_event_write = 1'b0;
assign dbg_zsst_mem_write_valid = 1'b0;
assign dbg_zsst_mem_write_address = 40'd0;
assign dbg_zsst_mem_write_data = 128'd0;
assign dbg_zsst_mem_write_strobe = 16'd0;
assign dbg_zsst_displayed_buffer = 2'd0;
assign dbg_zsst_buffer_size = 24'd0;
assign dbg_zsst_stride = 16'd0;
assign dbg_zsst_width = 10'd0;
assign dbg_zsst_height = 10'd0;
`endif

reg [16:0] spk_out;
reg [16:0] mix_tmp_l;
reg [16:0] mix_tmp_r;
reg [15:0] mix_dry_l;
reg [15:0] mix_dry_r;
reg [15:0] audio_l_r;
reg [15:0] audio_r_r;

synchronizer speaker_out_sync (
	.clk(clk_audio),
	.in(speaker_out),
	.out(speaker_out_audio)
);

always @(posedge clk_audio) begin
	reg [16:0] spk;
	spk <= {2'b00, {3'b000, speaker_out_audio}, 11'd0};
	spk_out <= spk >> ~vol_spk;
end

wire [15:0] master_l;
wire [15:0] master_r;
wire [15:0] sb_l;
wire [15:0] sb_r;
wire [15:0] opl_l;
wire [15:0] opl_r;
wire        sb_volume_valid;

sb_volume #(.NUM_CH(6), .SAMPLE_WIDTH(16)) sb_volume_inst (
	.clk(clk_audio),
	.sbp(sbp),
	.volumes_in({vol_master_l, vol_master_r,
	             vol_voice_l,  vol_voice_r,
	             vol_midi_l,   vol_midi_r}),
	.samples_in({mix_dry_l,    mix_dry_r,
	             sample_sb_l,  sample_sb_r,
	             sample_opl_l, sample_opl_r}),
	.samples_out({master_l, master_r,
	              sb_l,     sb_r,
	              opl_l,    opl_r}),
	.valid(sb_volume_valid)
);

always @(posedge clk_audio) begin
	if (sb_volume_valid) begin
		audio_l_r <= master_l;
		audio_r_r <= master_r;

		mix_tmp_l <= spk_out
		           + {2'b00, sample_cms_l, sample_cms_l[8:4]}
		           + {sb_l[15], sb_l}
		           + {opl_l[15], opl_l};
		mix_tmp_r <= spk_out
		           + {2'b00, sample_cms_r, sample_cms_r[8:4]}
		           + {sb_r[15], sb_r}
		           + {opl_r[15], opl_r};
	end

	mix_dry_l <= (^mix_tmp_l[16:15]) ? {mix_tmp_l[16], {15{mix_tmp_l[15]}}} : mix_tmp_l[15:0];
	mix_dry_r <= (^mix_tmp_r[16:15]) ? {mix_tmp_r[16], {15{mix_tmp_r[15]}}} : mix_tmp_r[15:0];
end

assign audio_l = audio_l_r;
assign audio_r = audio_r_r;

assign ce_pixel = video_ce;
assign video_r = video_r_w;
assign video_g = video_g_w;
assign video_b = video_b_w;
assign video_hs = video_hsync;
assign video_vs = video_vsync;
assign video_de = video_blank_n;
assign dbg_uart_byte = dbg_uart_byte_w;
assign dbg_uart_we = dbg_uart_we_w;
assign debug_bios_loaded_o = debug_bios_loaded;
assign debug_first_instruction_o = debug_first_instruction;

// Co-simulation taps (verilator/cosim_host.cpp).
assign cosim_cpu_reset_n      = system_i.z486_cpu.reset_n;
assign cosim_issue            = system_i.z486_cpu.i_issue && !system_i.z486_cpu.stall;
assign cosim_issue_eip        = system_i.z486_cpu.EIP;
assign cosim_ecx              = system_i.z486_cpu.data_unit_inst.gpr_capture_view[1];
assign cosim_eflags           = system_i.z486_cpu.eflags_fwd;
assign cosim_a20              = system_i.z486_cpu.a20_enable;
assign cosim_dreq_acc         = system_i.z486_cpu.dcache_req_valid && system_i.z486_cpu.dcache_req_accepted;
assign cosim_dreq_write       = system_i.z486_cpu.dcache_req_write;
assign cosim_dreq_addr        = system_i.z486_cpu.dcache_req_phys_addr_raw;
assign cosim_dreq_be          = system_i.z486_cpu.dcache_req_be;
assign cosim_dreq_wdata       = system_i.z486_cpu.dcache_req_wdata;
assign cosim_dreq_wdata_direct = system_i.z486_cpu.dcache_direct_wdata;
assign cosim_dreq_kind        = {system_i.z486_cpu.paging_inst.walk_biu_pending,
                                 system_i.z486_cpu.dcache_req_is_vga_mem,
                                 system_i.z486_cpu.dcache_req_is_x87,
                                 system_i.z486_cpu.dcache_req_is_inta,
                                 system_i.z486_cpu.dcache_req_is_io};
assign cosim_drd_done         = system_i.z486_cpu.dcache_read_complete;
assign cosim_drd_data         = system_i.z486_cpu.dcache_rdata;
assign cosim_fst_acc          = system_i.z486_cpu.fast_store_valid && system_i.z486_cpu.fast_store_accepted;
assign cosim_fst_addr         = system_i.z486_cpu.memory_inst.fast_store_phys_addr_raw;
assign cosim_fst_be           = system_i.z486_cpu.fast_store_be;
assign cosim_fst_wdata        = system_i.z486_cpu.fast_store_wdata;
assign cosim_dma_wr           = system_i.ext_mem1_valid && system_i.ext_mem1_write && system_i.ext_mem1_ready;
assign cosim_dma_addr         = system_i.ext_mem1_addr;
assign cosim_dma_be           = system_i.ext_mem1_be;
assign cosim_dma_wdata        = system_i.ext_mem1_din;
assign cosim_gprs             = {system_i.z486_cpu.data_unit_inst.gpr_capture_view[7],
                                 system_i.z486_cpu.data_unit_inst.gpr_capture_view[6],
                                 system_i.z486_cpu.data_unit_inst.gpr_capture_view[5],
                                 system_i.z486_cpu.data_unit_inst.gpr_capture_view[4],
                                 system_i.z486_cpu.data_unit_inst.gpr_capture_view[3],
                                 system_i.z486_cpu.data_unit_inst.gpr_capture_view[2],
                                 system_i.z486_cpu.data_unit_inst.gpr_capture_view[1],
                                 system_i.z486_cpu.data_unit_inst.gpr_capture_view[0]};
assign cosim_bus_quiet        = !system_i.z486_cpu.valid &&
                                system_i.z486_cpu.memory_inst.dcache_stores_drained &&
                                !system_i.z486_cpu.memory_inst.dcache_read_pending &&
                                !system_i.z486_cpu.memory_inst.icache_read_pending &&
                                !system_i.z486_cpu.memory_inst.direct_rd_pending &&
                                !system_i.z486_cpu.paging_inst.walk_biu_pending;

`ifdef VERILATOR
// Portable snapshots (verilator/snapshot.cpp): the co-simulation reference's
// architectural state, written into z486 while it is fresh from reset. Word
// indices as in cosim_host.cpp (arch_word): 0-7 EAX..EDI, 8 EIP, 9 EFLAGS,
// 10 CR0, 11 CR2, 12 CR3, 13 DR6, 14 DR7, 15/16 GDTR base/limit, 17/18 IDTR
// base/limit, then per segment (ES CS SS DS FS GS TR LDTR) the selector, the
// base and {A, G, D/B, P, DPL, S, type, raw limit[19:0]}.
import "DPI-C" function int unsigned cosim_arch_word(input int idx);
export "DPI-C" task cosim_load_arch;
task cosim_load_arch;
	z486_pkg::seg_desc_t d;
	logic [31:0] a;
	system_i.z486_cpu.data_unit_inst.eax = cosim_arch_word(0);
	system_i.z486_cpu.data_unit_inst.ecx = cosim_arch_word(1);
	system_i.z486_cpu.data_unit_inst.edx = cosim_arch_word(2);
	system_i.z486_cpu.data_unit_inst.ebx = cosim_arch_word(3);
	system_i.z486_cpu.data_unit_inst.esp = cosim_arch_word(4);
	system_i.z486_cpu.data_unit_inst.ebp = cosim_arch_word(5);
	system_i.z486_cpu.data_unit_inst.esi = cosim_arch_word(6);
	system_i.z486_cpu.data_unit_inst.edi = cosim_arch_word(7);
	system_i.z486_cpu.EIP = cosim_arch_word(8);
	system_i.z486_cpu.data_unit_inst.eflags = cosim_arch_word(9);
	system_i.z486_cpu.CR0 = cosim_arch_word(10);
	system_i.z486_cpu.CR2 = cosim_arch_word(11);
	system_i.z486_cpu.CR3 = cosim_arch_word(12);
	system_i.z486_cpu.DR6 = cosim_arch_word(13);
	system_i.z486_cpu.DR7 = cosim_arch_word(14);
	system_i.z486_cpu.seg_unit.gdt_base = cosim_arch_word(15);
	system_i.z486_cpu.seg_unit.gdt_limit = cosim_arch_word(16);
	system_i.z486_cpu.seg_unit.idt_base = cosim_arch_word(17);
	system_i.z486_cpu.seg_unit.idt_limit = cosim_arch_word(18);
	system_i.z486_cpu.ES = cosim_arch_word(19);
	system_i.z486_cpu.CS = cosim_arch_word(22);
	system_i.z486_cpu.SS = cosim_arch_word(25);
	system_i.z486_cpu.DS = cosim_arch_word(28);
	system_i.z486_cpu.FS = cosim_arch_word(31);
	system_i.z486_cpu.GS = cosim_arch_word(34);
	system_i.z486_cpu.TR = cosim_arch_word(37);
	system_i.z486_cpu.LDTR = cosim_arch_word(40);
	for (int i = 0; i < 8; i++) begin
		a = cosim_arch_word(21 + 3 * i);
		d.base = cosim_arch_word(20 + 3 * i);
		d.limit = a[19:0];
		d.seg_type = a[23:20];
		d.S = a[24];
		d.DPL = a[26:25];
		d.P = a[27];
		d.D_B = a[28];
		d.G = a[29];
		d.A = a[30];
		system_i.z486_cpu.seg_unit.desc_cache[i] = d;
	end
	// Fetch resumes at CS:EIP (a linear address, as after a far jump).
	system_i.z486_cpu.prefetch_inst.pf_fetch_addr = cosim_arch_word(20 + 3 * 1) + cosim_arch_word(8);
endtask
`endif

endmodule
