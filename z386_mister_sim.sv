//
// z386_MiSTer top level for Verilator simulation.
//
`timescale 1ns / 1ns

module z386_mister_sim (
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
	output  [7:0] dbg_uart_byte,
	output        dbg_uart_we,
	output        soft_reset_req
);

// The simulation build overrides this parameter for speed-sensitive testing.
parameter [27:0] CLOCK_RATE_HZ = 28'd20_000_000;

wire        software_reset;
reg  [7:0]  software_reset_count;
wire        core_reset = reset | (software_reset_count != 8'd0);
assign soft_reset_req = software_reset;

wire  [7:0] syscfg;

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

z386_ps2_device ps2_kbd_sim (
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

z386_ps2_device ps2_mouse_sim (
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

system #(
	.SYS_FREQ(CLOCK_RATE_HZ),
	.SDRAM_HAS_DQM(1'b0),
	.SDRAM_FAST_GRADE(1'b1),
	.DCACHE_SET_BITS(7),   // DEBUG: reproduce 8KB doom crash
	.ICACHE_SET_BITS(7),
	.ENABLE_CMS(1'b0)
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

	.sdram_dq            (sdram_dq),
	.sdram_a             (sdram_a),
	.sdram_ba            (sdram_ba),
	.sdram_dqm           (sdram_dqm),
	.sdram_nwe           (sdram_nwe),
	.sdram_nras          (sdram_nras),
	.sdram_ncas          (sdram_ncas),
	.sdram_ncs           (sdram_ncs),
	.sdram_cke           (sdram_cke),

	.ddram_busy          (ddram_busy),
	.ddram_burstcnt      (ddram_burstcnt),
	.ddram_addr          (ddram_addr),
	.ddram_dout          (ddram_dout),
	.ddram_dout_ready    (ddram_dout_ready),
	.ddram_rd            (ddram_rd),
	.ddram_din           (ddram_din),
	.ddram_be            (ddram_be),
	.ddram_we            (ddram_we),

	.refresh_allowed     (1'b1),

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
	.ram_size            (status[30:29]),
	.sdram_size          (2'd3),
	.uma_ram             (1'b0),
	.cpu_speed_osd      (2'd0),
	.syscfg              (syscfg),

	.video_ce            (video_ce),
	.video_blank_n       (video_blank_n),
	.video_hsync         (video_hsync),
	.video_vsync         (video_vsync),
	.video_r             (video_r_w),
	.video_g             (video_g_w),
	.video_b             (video_b_w),
	.video_border        (~status[54]),
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

endmodule
