// z386 SoC — z386 CPU with ao486-derived peripherals
module system (
    input         clk_sys,
    input         reset,
    input         hps_apply_reset,
    output        software_reset,    // keyboard controller 0xFE reset command
	input  [27:0] clock_rate,

	output [1:0]  fdd_request,
	output [2:0]  ide0_request,
	output [2:0]  ide1_request,
	input  [1:0]  floppy_wp,
	input   [1:0] joystick_dis,
	input  [13:0] joystick_dig_1,
	input  [13:0] joystick_dig_2,
	input  [15:0] joystick_ana_1,
	input  [15:0] joystick_ana_2,
	input   [1:0] joystick_mode,
	input   [1:0] joystick_timed,

    input  [15:0] mgmt_address,
    input         mgmt_read,
    output [15:0] mgmt_readdata,
    input         mgmt_write,
    input  [15:0] mgmt_writedata,

    // SDRAM interface
    inout  [15:0] sdram_dq,
    output [12:0] sdram_a,
    output [1:0]  sdram_ba,
    output [1:0]  sdram_dqm,
    output        sdram_nwe,
    output        sdram_nras,
    output        sdram_ncas,
    output        sdram_ncs,
    output        sdram_cke,
    input         refresh_allowed,

    // Shared HPS DDR window. Main_MiSTer stages ROMs at SHMEM 0x300C0000.
    input         ddram_busy,
    output  [7:0] ddram_burstcnt,
    output [28:0] ddram_addr,
    input  [63:0] ddram_dout,
    input         ddram_dout_ready,
    output        ddram_rd,
    output [63:0] ddram_din,
    output  [7:0] ddram_be,
    output        ddram_we,

    // SD card
    output        sd_clk,
    inout         sd_cmd,
    inout  [3:0]  sd_dat,

    // MiSTer HPS-side boot/media path
    input         ioctl_download,
    input  [15:0] ioctl_index,
    input         ioctl_wr,
    input  [26:0] ioctl_addr,
    input  [15:0] ioctl_dout,
    output        ioctl_wait,
    input         img_mounted,
    input         img_readonly,
    input  [63:0] img_size,
    output [31:0] img_lba,
    output  [5:0] img_blk_cnt,
    output        img_rd,
    output        img_wr,
    input         img_ack,
    output [12:0] img_buff_addr,
    input  [15:0] img_buff_din,
    output [15:0] img_buff_dout,
    output        img_buff_wr,

	input         ps2_mouseclk_in,
	input         ps2_mousedat_in,
	output        ps2_mouseclk_out,
	output        ps2_mousedat_out,
	input         ps2_kbclk_in,
	input         ps2_kbdat_in,
	output        ps2_kbclk_out,
	output        ps2_kbdat_out,

	// Mouse byte stream (for injecting PS/2 mouse packets)
	input   [7:0] mouse_data,
	input         mouse_data_valid,
	output  [8:0] mouse_host_cmd,	// PS/2 mouse host->device byte to UART bridge
	input         mouse_host_cmd_clear,

    // Debug stream up to UART bridge
    output  [7:0] dbg_uart_byte,
    output        dbg_uart_we,
    output        mpu_uart_tx,

    // SignalTap anchors for the boot-ROM / reset-vector path.
    output [31:0] dbg_sd_avm_address,
    output [31:0] dbg_sd_avm_writedata,
    output        dbg_sd_avm_write,
    output        dbg_sd_avm_wait,
    output        dbg_sd_avm_accept,

    output [31:0] dbg_mm_addr,
    output [31:0] dbg_mm_din,
    output [31:0] dbg_mm_dout,
    output        dbg_mm_valid,
    output        dbg_mm_write,
    output        dbg_mm_ready,
    output        dbg_mm_resp_valid,

    output [31:0] dbg_mem_address,
    output [31:0] dbg_mem_din,
    output [31:0] dbg_mem_dout,
    output        dbg_mem_valid,
    output        dbg_mem_we,
    output        dbg_mem_ready,
    output        dbg_mem_resp_valid,

    output [31:0] dbg_avm_address,
    output [31:0] dbg_avm_readdata,
    output        dbg_avm_ready,
    output        dbg_avm_resp_valid,
    output [31:0] dbg_cpu_din_z,

	input   [5:0] bootcfg,
    input   [1:0] ram_size,       // 0/1/2/3 = 16/32/64/128MB exposed to software
    input   [1:0] sdram_size,     // 1/2/3 = detected 32/64/128MB module geometry
    input         uma_ram,
	input   [1:0] cpu_speed_osd,  // 0=full, 1=15, 2=30, 3=56 MHz
	output  [7:0] syscfg,

	output wire        video_ce,
	output wire        video_blank_n,
	output wire        video_hsync,
	output wire        video_vsync,
	output wire [7:0]  video_r,
	output wire [7:0]  video_g,
	output wire [7:0]  video_b,
	input              video_border,	// show VGA overscan border (OSD)

	// SVGA framebuffer descriptor (from vga.v) -> MiSTer HPS framebuffer path
	output wire [19:0] video_start_addr,
	output wire  [8:0] video_width,
	output wire [10:0] video_height,
	output wire  [8:0] video_stride,
	output wire  [3:0] video_flags,
	output wire        video_off,
	output wire  [7:0] video_pal_a,
	output wire [17:0] video_pal_d,
	output wire        video_pal_we,

	input         clk_audio,		// 24.576Mhz
	output  [8:0] sample_cms_l,
	output  [8:0] sample_cms_r,
	output [15:0] sample_sb_l,
	output [15:0] sample_sb_r,
	output [15:0] sample_opl_l,
	output [15:0] sample_opl_r,
	input         sound_fm_mode,	// 0 = OPL2, 1 = OPL3
	input         sound_cms_en,	    // Creative CM-S music enable

	output        speaker_out,
	output        sbp,
	
	output  [4:0] vol_master_l,
	output  [4:0] vol_master_r,
	output  [4:0] vol_voice_l,
	output  [4:0] vol_voice_r,
	output  [4:0] vol_cd_l,
	output  [4:0] vol_cd_r,
	output  [4:0] vol_midi_l,
	output  [4:0] vol_midi_r,
	output  [4:0] vol_line_l,
	output  [4:0] vol_line_r,
	output  [1:0] vol_spk,
	output  [4:0] vol_en,

    // Debug outputs for LEDs
    output reg [2:0]  debug_boot_stage,
    output reg    debug_sd_error,
	output        debug_bios_loaded,
	output        debug_vga_bios_sig_bad,
	output        debug_vga_bios_sig_checked,
	output        debug_first_instruction,
    output reg [7:0]  debug_post_code,
    output reg        debug_post_write,

    // CPU state outputs (for simulation monitoring)
    output            cpu_pe,
    output            cpu_vm,
    output     [15:0] cpu_cs,
    output     [31:0] cpu_eip,
    output     [31:0] cpu_cs_base
);

parameter SYS_FREQ = 50_000_000;
parameter SDRAM_HAS_DQM = 1'b1;
parameter SDRAM_FAST_GRADE = 1'b1;
parameter DCACHE_SET_BITS = 8;   // dcache size: 8 = 16KB, 7 = 8KB
parameter ICACHE_SET_BITS = 8;   // icache size: 8 = 16KB, 7 = 8KB
parameter ENABLE_X87 = 1'b0;
parameter ENABLE_CMS = 1'b1;
localparam [6:0] CPU_CLOCK_MHZ = SYS_FREQ / 1_000_000;

assign cpu_pe      = debug_cpu_pe;
assign cpu_vm      = debug_cpu_vm;
assign cpu_cs      = debug_cpu_cs;
assign cpu_eip     = debug_cpu_eip;
assign cpu_cs_base = debug_cpu_cs_base;

// reset duplication to reduce fanout
reg [15:0] rst /* synthesis syn_preserve = "true" */;
always @(posedge clk_sys)
	rst <= {16{reset}};

wire ide0_reset = rst[3];
wire ide1_reset = rst[5];

wire        a20_enable;
wire  [7:0] dma_floppy_readdata;
wire        dma_floppy_tc;
wire  [7:0] dma_floppy_writedata;
wire        dma_floppy_req;
wire        dma_floppy_ack;
wire        dma_sb_req_8;
wire        dma_sb_req_16;
wire        dma_sb_ack_8;
wire        dma_sb_ack_16;
wire  [7:0] dma_sb_readdata_8;
wire [15:0] dma_sb_readdata_16;
wire [15:0] dma_sb_writedata;
wire [15:0] dma_readdata;
wire        dma_waitrequest;
wire [23:0] dma_address;
wire        dma_read;
wire        dma_readdatavalid;
wire        dma_write;
wire [15:0] dma_writedata;
wire        dma_16bit;

// Boot loader signals
reg [3:0]   boot_state;
reg [31:0]  boot_addr;
reg         boot_done = 1'b0;
reg         cpu_reset_n;
reg  [3:0]  cpu_warm_reset_count;
reg [63:0]  boot_read_data;
reg [31:0]  boot_dest_addr;
reg  [1:0]  boot_write_phase;
reg         ddram_rd_r;

// Debug registers for LED indicators
reg         bios_loaded = 1'b0;
reg         vga_bios_sig_bad;
reg         first_instruction_executed;
reg [15:0]  vga_bios_first_word;
reg         vga_bios_sig_checked;
reg  [31:0] watchdog_eip_last;
reg  [15:0] watchdog_cs_last;
reg  [31:0] watchdog_cpu_stall_count;
reg  [31:0] watchdog_mm_stall_count;
reg  [31:0] watchdog_bus_stall_count;
reg  [31:0] watchdog_x87_stall_count;
reg         watchdog_cpu_reported;
reg         watchdog_mm_reported;
reg         watchdog_bus_reported;
reg         watchdog_x87_reported;
reg         watchdog_uart_active;
reg   [1:0] watchdog_uart_msg;
reg   [5:0] watchdog_uart_index;
reg   [7:0] watchdog_uart_byte;
reg         watchdog_uart_we;
reg  [15:0] watchdog_cs_snapshot;
reg  [31:0] watchdog_eip_snapshot;
reg  [31:0] watchdog_x87_snapshot;

// Debug signals from CPU
wire [31:0] debug_cpu_eip;
wire [15:0] debug_cpu_cs;
wire [31:0] debug_cpu_cs_base;
wire        debug_cpu_pe;
wire        debug_cpu_vm;
wire [31:0] debug_x87_state;

localparam BOOT_IDLE       = 0;
localparam BOOT_DDR_REQ    = 1;
localparam BOOT_DDR_WAIT   = 2;
localparam BOOT_WRITE_COPY = 3;
localparam BOOT_COMPLETE   = 4;

localparam [31:0] BIOS_MIRROR_BASE = 32'h00FC0000;

wire [15:0] mgmt_fdd_readdata;
wire [15:0] mgmt_ide0_readdata;
wire [15:0] mgmt_ide1_readdata;
wire        mgmt_ide0_cs;
wire        mgmt_ide1_cs;
wire        mgmt_fdd_cs;
wire        mgmt_rtc_cs;

wire        interrupt_done;
wire        interrupt_do;
wire  [7:0] interrupt_vector;
reg  [15:0] interrupt;
wire        irq_0, irq_1, irq_2, irq_3, irq_4, 
		    irq_5 /* verilator public */, 
			irq_6, 
			irq_7 /* verilator public */, 
			irq_8, irq_9, irq_10, irq_12, irq_14, irq_15;

// z386 CPU bus signals (ready/valid)
wire [31:2] cpu_addr;
wire  [3:0] cpu_be;
wire  [7:0] cpu_burstcount;
wire [31:0] cpu_din_z;
wire [31:0] cpu_dout_z;
wire        cpu_valid, cpu_write;
wire        cpu_io_sig;
wire        cpu_ready;
wire        cpu_resp_valid;
wire        cpu_intr;
wire        cpu_inta;

// IO bus adapter outputs (peripheral-facing)
wire [15:0] iobus_address;
wire        iobus_write;
wire        iobus_read;
wire  [7:0] iobus_writedata_byte;

// IO bus adapter IDE 32-bit interface
wire  [3:0] iobus_ide_address;
wire        iobus_ide_read;
wire        iobus_ide_write;
wire [31:0] iobus_ide_writedata;
wire        iobus_ide_32;

// IO bus adapter ready/dout
wire [31:0] io_bus_dout;
wire        io_bus_ready;

// PIC INTA bridge signals
wire [31:0] inta_din;
wire        inta_ready;

reg         ide0_cs;
reg         ide1_cs;
reg         floppy0_cs;
reg         dma_master_cs;
reg         dma_page_cs;
reg         dma_slave_cs;
reg         pic_master_cs;
reg         pic_slave_cs;
reg         pit_cs;
reg         ps2_io_cs;
reg         ps2_ctl_cs;
reg         joy_cs;
reg         rtc_cs;
reg         fm_cs;
reg         sb_cs;
reg         uart1_cs;
reg         uart2_cs;
reg         mpu_cs;
reg         vga_b_cs;
reg         vga_c_cs;
reg         vga_d_cs;
reg         debug_port_cs;
reg         speedctl_cs;
reg   [7:0] ctlport = 0;
reg   [7:0] speedctl_low = 0;

wire        fdd0_inserted;

wire  [7:0] sound_readdata;
wire  [7:0] floppy0_readdata;
wire [31:0] ide0_readdata;
wire [31:0] ide1_readdata;
wire  [7:0] joystick_readdata;
wire  [7:0] pit_readdata;
wire  [7:0] ps2_readdata;
wire  [7:0] rtc_readdata;
wire  [7:0] uart1_readdata;
wire  [7:0] uart2_readdata;
wire  [7:0] mpu_readdata;
wire  [7:0] dma_io_readdata;
wire  [7:0] pic_readdata;
wire  [7:0] vga_io_readdata;

// CPU-facing external memory request bundle. z386 owns the L1 internally, so
// this is the cache-fill/write-through bus, not a SoC-side cache request.
wire [31:0] avm_address;           // byte address
wire [31:0] avm_writedata;
wire [31:0] avm_readdata;
wire  [3:0] avm_byteenable;
wire        avm_write;
wire        avm_valid;
wire        avm_ready;
wire        avm_readdatavalid;
wire        mem_bus_ready;

// main_memory to SDRAM (valid/ready)
wire [31:0] mem_address;
wire [31:0] mem_din;
wire [31:0] mem_dout;
wire        mem_resp_valid;
wire [3:0]  mem_be;
wire [7:0]  mem_burstcount;
wire        mem_ready;
wire        mem_valid;
wire        mem_we;

wire [16:0] vga_address;
wire  [7:0] vga_readdata;
wire  [7:0] vga_writedata;
wire        vga_read;
wire        vga_write;
wire  [2:0] vga_memmode;
wire  [5:0] video_wr_seg;
wire  [5:0] video_rd_seg;
wire        video_chain4;
wire  [3:0] video_map_mask;
wire  [1:0] video_read_plane;
wire  [1:0] video_write_mode;
// SVGA framebuffer descriptor wires (video_*) are now module outputs.

// ============================================================================
// z386 CPU
// ============================================================================
wire [31:0] dma_snoop_addr;
wire        dma_snoop_valid;
wire        cpu_triple_fault_reset;

z386 #(
    .PROTECT_UMA_ROM(1),
    .DCACHE_SET_BITS(DCACHE_SET_BITS),
    .ICACHE_SET_BITS(ICACHE_SET_BITS),
    .ENABLE_X87(ENABLE_X87),
    .CLOCK_RATE_MHZ(CPU_CLOCK_MHZ)
) z386_cpu (
    .clk               (clk_sys),
    .reset_n           (cpu_reset_n),
    .addr              (cpu_addr),
    .be                (cpu_be),
    .burstcount        (cpu_burstcount),
    .din               (cpu_din_z),
    .dout              (cpu_dout_z),
    .valid             (cpu_valid),
    .write             (cpu_write),
    .io                (cpu_io_sig),
    .ready             (cpu_ready),
    .resp_valid        (cpu_resp_valid),
    .intr              (cpu_intr),
    .nmi               (1'b0),
    .inta              (cpu_inta),
    .snoop_addr        (dma_snoop_addr),
    .snoop_valid       (dma_snoop_valid),
    .a20_enable        (a20_enable),
	.cpu_speed_sel     (ctlport[7] ? ctlport[1:0] : cpu_speed_osd),
    .single_step       (1'b0),
    .dbg_CS            (debug_cpu_cs),
    .dbg_EIP           (debug_cpu_eip),
    .dbg_CS_base       (debug_cpu_cs_base),
    .dbg_pe            (debug_cpu_pe),
    .dbg_vm            (debug_cpu_vm),
    .dbg_x87_state     (debug_x87_state),
    .triple_fault_reset(cpu_triple_fault_reset)
);

// CPU data in mux: INTA > IO > Memory
assign cpu_din_z = cpu_inta ? inta_din :
                   cpu_io_sig ? io_bus_dout :
                   (boot_done ? avm_readdata : mm_dout);
// ready: acceptance handshake
assign cpu_ready = cpu_inta ? inta_ready :
                   cpu_io_sig ? io_bus_ready :
                   mem_bus_ready;
// resp_valid: read data available
assign cpu_resp_valid = cpu_inta ? inta_ready :
                        cpu_io_sig ? io_bus_ready :
                        mem_bus_resp_valid;

// ============================================================================
// PIC INTA Bridge
// ============================================================================
pic_inta_bridge inta_bridge (
    .clk                (clk_sys),
    .reset_n            (~rst[0]),
    .pic_interrupt_do   (interrupt_do),
    .pic_interrupt_vector(interrupt_vector),
    .pic_interrupt_done (interrupt_done),
    .cpu_intr           (cpu_intr),
    .cpu_inta           (cpu_inta),
    .cpu_inta_din       (inta_din),
    .cpu_inta_ready     (inta_ready)
);

// ============================================================================
// z386 → main_memory (ready/valid)
// ============================================================================
wire cpu_mem_valid = cpu_valid && !cpu_io_sig && !cpu_inta;
wire cpu_mem_write = cpu_write;

// A20 gating now lives inside z386_cpu (masked BEFORE the L1 caches via a20_mask),
// so cpu_addr is already A20-gated here — no second mask needed.
wire [31:0] cpu_byte_addr_raw = {cpu_addr, 2'b00};
// Mirror the high 256 KiB reset-vector region to the copied ROM image.
wire is_bios_mirror_alias = &cpu_byte_addr_raw[31:18];    // 0xFFFC0000+
wire [31:0] cpu_byte_addr = is_bios_mirror_alias
                          ? (BIOS_MIRROR_BASE + {14'd0, cpu_byte_addr_raw[17:0]})
                          : cpu_byte_addr_raw;

// z386 owns the L1 internally, so UMA write-protect is handled at the CPU/cache
// boundary through PROTECT_UMA_ROM. Nothing is bypassed here.
wire cpu_mem_bypass = 1'b0;

// Pass CPU external memory signals to main_memory. z386 has already handled
// cache lookup and fill sequencing internally.
assign avm_address     = cpu_byte_addr;
assign avm_writedata   = cpu_dout_z;
assign avm_readdata    = mm_dout;
assign avm_byteenable  = cpu_be;
assign avm_valid       = boot_done && cpu_mem_valid && !cpu_mem_bypass;
assign avm_write       = cpu_mem_write;
assign avm_ready       = boot_done ? mm_ready : 1'b0;
assign avm_readdatavalid = boot_done ? mm_resp_valid : 1'b0;

reg mem_rom_wr_ready;
always @(posedge clk_sys) begin
    if (reset)
        mem_rom_wr_ready <= 1'b0;
    else
        mem_rom_wr_ready <= cpu_mem_bypass;
end

wire vga_wr_done;    // unused in ready path, still connected to main_memory output
wire mem_bus_resp_valid = avm_readdatavalid;
assign mem_bus_ready = avm_ready | mem_rom_wr_ready;

// Main memory wires. During boot the SD boot writer owns this port; after boot
// it is driven by z386's external cache-fill/write-through bus.
wire [31:0] mm_addr, mm_din, mm_dout;
wire  [3:0] mm_be;
wire  [7:0] mm_burstcount;
wire        mm_valid, mm_write, mm_ready, mm_resp_valid;
wire        dma_mem_ready;  // forward declaration (used in snoop_valid below)

// Mux: during boot, the SD boot writer goes directly to main_memory; after
// boot, CPU memory traffic reaches main_memory directly.
assign mm_addr       = boot_done ? avm_address       : sd_avm_address;
assign mm_din        = boot_done ? avm_writedata     : sd_avm_writedata;
assign mm_be         = boot_done ? avm_byteenable    : sd_avm_byteenable;
assign mm_burstcount = boot_done ? cpu_burstcount    : 8'd1;
assign mm_valid      = boot_done ? avm_valid         : sd_avm_write;
assign mm_write      = boot_done ? avm_write         : 1'b1;

// SVGA framebuffer: enable + DDR3 write port (from main_memory, muxed onto ddram below).
// fb_en = ET4000 linear hi-depth (8/16/24/32bpp), i.e. ~PELWIDTH & depth>0.
wire        vga_fb_en = ~video_flags[2] && |video_flags[1:0];
wire [28:0] fb_ddram_addr;
wire [63:0] fb_ddram_din;
wire  [7:0] fb_ddram_be;
wire        fb_ddram_we;
wire        fb_ddram_rd;
wire  [7:0] fb_ddram_burstcnt;

// Main memory (SDRAM + VGA hole)
main_memory main_memory (
    .clk               (clk_sys),
    .reset             (reset),

    .cpu_addr          (mm_addr),
    .cpu_din           (mm_din),
    .cpu_dout          (mm_dout),
    .cpu_resp_valid    (mm_resp_valid),
    .cpu_be            (mm_be),
    .cpu_burstcount    (mm_burstcount),
    .cpu_ready         (mm_ready),
    .cpu_valid         (mm_valid),
    .cpu_write         (mm_write),
    .ram_size          (ram_size),

    // SDRAM interface (valid/ready)
	.mem_addr          (mem_address),
	.mem_din           (mem_din),
	.mem_dout          (mem_dout),
	.mem_resp_valid    (mem_resp_valid),
	.mem_be            (mem_be),
	.mem_burstcount    (mem_burstcount),
	.mem_ready         (mem_ready),
	.mem_valid         (mem_valid),
	.mem_write         (mem_we),

    // VGA interface - cpu accessing mapped VGA memory goes through here to vga.v
	.vga_address       (vga_address),
	.vga_readdata      (vga_readdata),
	.vga_writedata     (vga_writedata),
	.vga_read          (vga_read),
	.vga_write         (vga_write),
	.vga_memmode       (vga_memmode),
	.vga_wr_seg        (video_wr_seg),
	.vga_rd_seg        (video_rd_seg),
	.vga_fb_en         (vga_fb_en),
	.vga_chain4        (video_chain4),
	.vga_map_mask      (video_map_mask),
	.vga_read_plane    (video_read_plane),
	.vga_write_mode    (video_write_mode),
	.vga_wr_done       (vga_wr_done),

	// DDR3 SVGA framebuffer read/write port (muxed onto ddram_* after boot)
	.fb_ddram_addr        (fb_ddram_addr),
	.fb_ddram_din         (fb_ddram_din),
	.fb_ddram_be          (fb_ddram_be),
	.fb_ddram_we          (fb_ddram_we),
	.fb_ddram_rd          (fb_ddram_rd),
	.fb_ddram_dout        (ddram_dout),
	.fb_ddram_dout_ready  (ddram_dout_ready),
	.fb_ddram_burstcnt    (fb_ddram_burstcnt),
	.fb_ddram_busy        (ddram_busy)
);

// CPU → SDRAM port 0: main_memory holds signals stable until accepted
wire        mem_busy;    // SDRAM initialization busy (used by boot loader)
wire [26:0] mem_addr_word = mem_address[26:0];

// DMA → SDRAM port 1
// (dma_mem_ready declared above, before l1_cache)
//
// Hold register: dma.v outputs mem_read/mem_write as registered signals that may
// only be high for 1 cycle. The SDRAM valid/ready protocol requires valid to stay
// high until ready. This hold register captures the DMA request and keeps it
// asserted until the SDRAM accepts it.
reg         dma_held_valid;
reg         dma_held_wr;
reg  [23:0] dma_held_addr;
reg  [15:0] dma_held_data;
reg         dma_held_16bit;
assign dma_snoop_addr = {8'h0, dma_held_addr};
// Invalidate while a DMA write is pending, not only in the exact SDRAM accept
// cycle. This is conservative and keeps SDRAM port arbitration out of the cache
// preread invalidation path.
assign dma_snoop_valid = boot_done && dma_held_valid && dma_held_wr;

always @(posedge clk_sys) begin
    if (rst[0]) begin
        dma_held_valid <= 0;
    end else if (dma_held_valid && dma_mem_ready) begin
        // SDRAM accepted — release hold
        dma_held_valid <= 0;
    end else if ((dma_read | dma_write) && !dma_held_valid) begin
        // New DMA request — capture and hold
        dma_held_valid <= 1;
        dma_held_wr    <= dma_write;
        dma_held_addr  <= dma_address;
        dma_held_data  <= dma_writedata;
        dma_held_16bit <= dma_16bit;
    end
end

reg         dma_mem_wr;          // latches write flag on acceptance for resp_valid
wire [31:0] dma_mem_dout;
wire        dma_mem_resp_valid;
wire [3:0]  dma_mem_be = dma_held_16bit ?
    (dma_held_addr[1] ? 4'b1100 : 4'b0011) :
    (4'b0001 << dma_held_addr[1:0]);
wire [31:0] dma_mem_din = dma_held_16bit ?
    (dma_held_addr[1] ? {dma_held_data, 16'h0000} : {16'h0000, dma_held_data}) :
    ({24'h0, dma_held_data[7:0]} << {dma_held_addr[1:0], 3'b000});

sdram #(
    .FREQ(SYS_FREQ),
    .HAS_DQM(SDRAM_HAS_DQM),
    .FAST_GRADE(SDRAM_FAST_GRADE)
) sdram (
	.clk               (clk_sys),
	.nce               (1'b0),
	.resetn            (~reset),
	.refresh_allowed   (1'b1),
	.busy              (mem_busy),
	.sdram_size        (sdram_size),

	// port 0 - CPU (via main_memory, valid/ready)
	.valid0            (mem_valid),
	.ready0            (mem_ready),
	.wr0               (mem_we),
	.addr0             (mem_addr_word),
	.din0              (mem_din),
	.dout0             (mem_dout),
	.resp_valid0       (mem_resp_valid),
	.be0               (mem_be),
	.burst_cnt0        (mem_burstcount[3:0]),
	.burst_done0       (),

	// port 1 - DMA (valid/ready with hold register)
	.valid1            (dma_held_valid),
	.ready1            (dma_mem_ready),
	.wr1               (dma_held_wr),
	.addr1             ({3'b000, dma_held_addr}),
	.din1              (dma_mem_din),
	.dout1             (dma_mem_dout),
	.resp_valid1       (dma_mem_resp_valid),
	.be1               (dma_mem_be),
	.burst_cnt1        (4'd1),
	.burst_done1       (),

	// port 2 - unused
	.valid2            (1'b0),
	.ready2            (),
	.wr2               (1'b0),
	.addr2             (27'd0),
	.din2              (32'd0),
	.dout2             (),
	.resp_valid2       (),
	.be2               (4'd0),
	.burst_cnt2        (4'd0),
	.burst_done2       (),

	// SDRAM side interface
    .SDRAM_DQ          (sdram_dq),
    .SDRAM_A           (sdram_a),
    .SDRAM_DQM         (sdram_dqm),
    .SDRAM_BA          (sdram_ba),
    .SDRAM_nWE         (sdram_nwe),
    .SDRAM_nRAS        (sdram_nras),
    .SDRAM_nCAS        (sdram_ncas),
    .SDRAM_nCS         (sdram_ncs),
    .SDRAM_CKE         (sdram_cke)
);

// DMA → SDRAM port 1: Avalon-MM master holds signals stable while waitrequest
// Latch write flag on acceptance for resp_valid tracking
always @(posedge clk_sys) begin
    if (rst[0])
        dma_mem_wr <= 1'b0;
    else if (dma_mem_ready)
        dma_mem_wr <= dma_held_wr;
end

assign dma_waitrequest   = dma_held_valid && !dma_mem_ready;
assign dma_readdatavalid = dma_mem_resp_valid && !dma_mem_wr;
// Select correct byte/word from 32-bit memory response based on byte address
assign dma_readdata      = dma_held_16bit ?
    (dma_held_addr[1] ? dma_mem_dout[31:16] : dma_mem_dout[15:0]) :
    (dma_held_addr[1] ? {8'h0, dma_held_addr[0] ? dma_mem_dout[31:24] : dma_mem_dout[23:16]}
                      : {8'h0, dma_held_addr[0] ? dma_mem_dout[15:8]  : dma_mem_dout[7:0]});

wire [7:0] iobus_readdata8 =
	( ide0_cs|ide1_cs                        ) ? (ide0_cs ? ide0_readdata[7:0] : ide1_readdata[7:0]) :
	( floppy0_cs                             ) ? floppy0_readdata  :
	( dma_master_cs|dma_slave_cs|dma_page_cs ) ? dma_io_readdata   :
	( pic_master_cs|pic_slave_cs             ) ? pic_readdata      :
	( pit_cs                                 ) ? pit_readdata      :
	( ps2_io_cs|ps2_ctl_cs                   ) ? ps2_readdata      :
	( rtc_cs                                 ) ? rtc_readdata      :
	( sb_cs|fm_cs                            ) ? sound_readdata    :
	( mpu_cs                                 ) ? mpu_readdata      :
	( joy_cs                                 ) ? joystick_readdata :
	( vga_b_cs|vga_c_cs|vga_d_cs             ) ? vga_io_readdata   :
	( debug_port_cs                          ) ? 8'hE9             :
	                                             8'hFF;

// ============================================================================
// IO Bus Adapter (z386 IO cycles → byte-sequential peripheral bus)
// ============================================================================
iobus_adapter iobus_adapter (
    .clk               (clk_sys),
    .reset_n           (~rst[0]),
    // z386 bus
    .cpu_addr          (cpu_addr),
    .cpu_be            (cpu_be),
    .cpu_din           (cpu_dout_z),
    .cpu_dout          (io_bus_dout),
    .cpu_io_rd         (cpu_valid && !cpu_write && cpu_io_sig && !cpu_inta),
    .cpu_io_wr         (cpu_valid && cpu_write && cpu_io_sig && !cpu_inta),
    .cpu_io_ready      (io_bus_ready),
    // Peripheral byte bus
    .io_address        (iobus_address),
    .io_read           (iobus_read),
    .io_write          (iobus_write),
    .io_writedata      (iobus_writedata_byte),
    .io_readdata       (iobus_readdata8),
    // IDE 32-bit
    .ide_address       (iobus_ide_address),
    .ide_read          (iobus_ide_read),
    .ide_write         (iobus_ide_write),
    .ide_writedata     (iobus_ide_writedata),
    .ide_readdata      (ide0_cs ? ide0_readdata : ide1_readdata),
    .ide_32            (iobus_ide_32),
    // Direct-handled (unused)
    .direct_readdata   (8'hFF),
    .direct_handled    (1'b0)
);

// Chip-selects must be combinational (iobus_adapter asserts io_write/io_read
// for only 1 cycle, so registered CS would arrive 1 cycle late)
always @(*) begin
	ide0_cs       = ({iobus_address[15:3], 3'd0} == 16'h01F0) || ({iobus_address[15:0]} == 16'h03F6);
	ide1_cs       = ({iobus_address[15:3], 3'd0} == 16'h0170) || ({iobus_address[15:0]} == 16'h0376);
	joy_cs        = ({iobus_address[15:0]      } == 16'h0201);
	floppy0_cs    = ({iobus_address[15:2], 2'd0} == 16'h03F0) || ({iobus_address[15:1], 1'd0} == 16'h03F4) || ({iobus_address[15:0]} == 16'h03F7) ;
	dma_master_cs = ({iobus_address[15:5], 5'd0} == 16'h00C0);
	dma_page_cs   = ({iobus_address[15:4], 4'd0} == 16'h0080);
	dma_slave_cs  = ({iobus_address[15:4], 4'd0} == 16'h0000);
	pic_master_cs = ({iobus_address[15:1], 1'd0} == 16'h0020);
	pic_slave_cs  = ({iobus_address[15:1], 1'd0} == 16'h00A0);
	pit_cs        = ({iobus_address[15:2], 2'd0} == 16'h0040) || (iobus_address == 16'h0061);
	ps2_io_cs     = ({iobus_address[15:3], 3'd0} == 16'h0060);
	ps2_ctl_cs    = ({iobus_address[15:4], 4'd0} == 16'h0090);
	rtc_cs        = ({iobus_address[15:1], 1'd0} == 16'h0070);
	fm_cs         = ({iobus_address[15:2], 2'd0} == 16'h0388);
	sb_cs         = ({iobus_address[15:4], 4'd0} == 16'h0220);
	uart1_cs      = ({iobus_address[15:3], 3'd0} == 16'h03F8); // COM1
	uart2_cs      = ({iobus_address[15:3], 3'd0} == 16'h02F8); // COM2
	mpu_cs        = ({iobus_address[15:1], 1'd0} == 16'h0330); // MPU-401 330/331
	vga_b_cs      = ({iobus_address[15:4], 4'd0} == 16'h03B0);
	vga_c_cs      = ({iobus_address[15:4], 4'd0} == 16'h03C0);
	vga_d_cs      = ({iobus_address[15:4], 4'd0} == 16'h03D0);
	debug_port_cs = ({iobus_address[15:0]      } == 16'h0402);
	speedctl_cs   = ({iobus_address[15:1], 1'b0} == 16'h8888);
end

always @(posedge clk_sys) begin
	if(reset) begin
		ctlport <= 0;
		speedctl_low <= 0;
	end
	else if(iobus_write && speedctl_cs) begin
		if(!iobus_address[0])
			speedctl_low <= iobus_writedata_byte;
		else if(iobus_writedata_byte == 8'hA1)
			ctlport <= speedctl_low;
	end
end

assign syscfg = ctlport;

// iobus_adapter instantiated above (replaces old iobus module)

dma dma
(
	.clk               (clk_sys),
	.rst_n             (~rst[1]),

	.mem_address       (dma_address),
	.mem_16bit         (dma_16bit),
	.mem_waitrequest   (dma_waitrequest),
	.mem_read          (dma_read),
	.mem_readdatavalid (dma_readdatavalid),
	.mem_readdata      (dma_readdata),
	.mem_write         (dma_write),
	.mem_writedata     (dma_writedata),

	.io_address        (iobus_address[4:0]),
	.io_writedata      (iobus_writedata_byte),
	.io_read           (iobus_read),
	.io_write          (iobus_write),
	.io_readdata       (dma_io_readdata),
	.io_master_cs      (dma_master_cs),
	.io_slave_cs       (dma_slave_cs),
	.io_page_cs        (dma_page_cs),

	.dma_2_req         (dma_floppy_req),
	.dma_2_ack         (dma_floppy_ack),
	.dma_2_tc          (dma_floppy_tc),
	.dma_2_readdata    (dma_floppy_readdata),
	.dma_2_writedata   (dma_floppy_writedata),

	.dma_1_req         (dma_sb_req_8),
	.dma_1_ack         (dma_sb_ack_8),
	.dma_1_readdata    (dma_sb_readdata_8),
	.dma_1_writedata   (dma_sb_writedata[7:0]),

	.dma_5_req         (dma_sb_req_16),
	.dma_5_ack         (dma_sb_ack_16),
	.dma_5_readdata    (dma_sb_readdata_16),
	.dma_5_writedata   (dma_sb_writedata)
);

floppy floppy
(
	.clk               (clk_sys),
	.rst_n             (~rst[2]),

	.clock_rate        (clock_rate),

	.io_address        (iobus_address[2:0]),
	.io_writedata      (iobus_writedata_byte),
	.io_read           (iobus_read & floppy0_cs),
	.io_write          (iobus_write & floppy0_cs),
	.io_readdata       (floppy0_readdata),

	.fdd0_inserted     (fdd0_inserted),

	.dma_req           (dma_floppy_req),
	.dma_ack           (dma_floppy_ack),
	.dma_tc            (dma_floppy_tc),
	.dma_readdata      (dma_floppy_readdata),
	.dma_writedata     (dma_floppy_writedata),

	.mgmt_address      (mgmt_address[3:0]),
	.mgmt_fddn         (mgmt_address[7]),
	.mgmt_writedata    (mgmt_writedata),
	.mgmt_readdata     (mgmt_fdd_readdata),
	.mgmt_write        (mgmt_write & mgmt_fdd_cs),
	.mgmt_read         (mgmt_read & mgmt_fdd_cs),

	.wp                (floppy_wp),

	.request           (fdd_request),
	.irq               (irq_6)
);


// PC gameport / joystick interface at I/O port 201h.
// Derived from ao486 joystick module.
joystick joystick
(
    .rst_n             (~rst[0]),
    .clk               (clk_sys),
    .clock_rate        (clock_rate),

    .read              (iobus_read & joy_cs),
    .write             (iobus_write & joy_cs),
    .readdata          (joystick_readdata),

    .dis               (joystick_dis),
    .dig_1             (joystick_dig_1),
    .dig_2             (joystick_dig_2),
    .ana_1             (joystick_ana_1),
    .ana_2             (joystick_ana_2),
    .mode              (joystick_mode),
    .timed             (joystick_timed)
);

// IDE address: byte-sequential adapter provides 8-bit access via iobus_address,
// while iobus_adapter provides 32-bit IDE access via iobus_ide_* signals.
wire [3:0] ide_address = {iobus_address[9],iobus_address[2:0]};

reg  [31:0] sd_avm_address;
reg  [31:0] sd_avm_writedata;
reg   [3:0] sd_avm_byteenable;
reg         sd_avm_write;
wire [31:0] boot_ddr_byte_addr = 32'h000C0000 + boot_addr;

assign dbg_sd_avm_address   = sd_avm_address;
assign dbg_sd_avm_writedata = sd_avm_writedata;
assign dbg_sd_avm_write     = sd_avm_write;
assign dbg_sd_avm_wait      = boot_done ? 1'b0 : (sd_avm_write && !mm_ready);
assign dbg_sd_avm_accept    = sd_avm_write && !dbg_sd_avm_wait;
assign ioctl_wait           = 1'b0;

// ddram is time-shared: boot loader reads the RAM image (pre-boot), then the SVGA
// framebuffer owns it for writes (post-boot). boot_done is the arbiter (mutually exclusive).
assign ddram_burstcnt       = boot_done ? fb_ddram_burstcnt : 8'd1;
assign ddram_addr           = boot_done ? fb_ddram_addr     : {4'h3, boot_ddr_byte_addr[27:3]};
assign ddram_rd             = boot_done ? fb_ddram_rd        : ddram_rd_r;
assign ddram_din            = boot_done ? fb_ddram_din      : 64'd0;
assign ddram_be             = boot_done ? fb_ddram_be       : 8'hFF;
assign ddram_we             = boot_done ? fb_ddram_we       : 1'b0;

assign dbg_mm_addr          = mm_addr;
assign dbg_mm_din           = mm_din;
assign dbg_mm_dout          = mm_dout;
assign dbg_mm_valid         = mm_valid;
assign dbg_mm_write         = mm_write;
assign dbg_mm_ready         = mm_ready;
assign dbg_mm_resp_valid    = mm_resp_valid;

assign dbg_mem_address      = mem_address;
assign dbg_mem_din          = mem_din;
assign dbg_mem_dout         = mem_dout;
assign dbg_mem_valid        = mem_valid;
assign dbg_mem_we           = mem_we;
assign dbg_mem_ready        = mem_ready;
assign dbg_mem_resp_valid   = mem_resp_valid;

assign dbg_avm_address      = avm_address;
assign dbg_avm_readdata     = avm_readdata;
assign dbg_avm_ready        = avm_ready;
assign dbg_avm_resp_valid   = avm_readdatavalid;
assign dbg_cpu_din_z        = cpu_din_z;

// IDE0: mux between byte-sequential (iobus_address) and 32-bit (iobus_ide_*) paths
wire        ide0_io_read  = (iobus_read & ide0_cs) | (iobus_ide_read & ide0_cs);
wire        ide0_io_write = (iobus_write & ide0_cs) | (iobus_ide_write & ide0_cs);
wire [3:0]  ide0_io_addr  = (iobus_ide_read | iobus_ide_write) ? iobus_ide_address : ide_address;
wire [31:0] ide0_io_wdata = (iobus_ide_read | iobus_ide_write) ? iobus_ide_writedata : {24'h0, iobus_writedata_byte};
wire        ide0_io_32    = (iobus_ide_read | iobus_ide_write) ? iobus_ide_32 : 1'b0;

ide ide0
(
	.clk               (clk_sys),
	.rst_n             (~ide0_reset),

	.io_address        (ide0_io_addr),
	.io_writedata      (ide0_io_wdata),
	.io_read           (ide0_io_read),
	.io_write          (ide0_io_write),
	.io_readdata       (ide0_readdata),
	.io_32             (ide0_io_32),

	.use_fast          (1'b0),
	.no_data           (),
    .drive_en          (),
    .io_wait           (),

	.mgmt_address      (mgmt_address[3:0]),
	.mgmt_writedata    (mgmt_writedata),
	.mgmt_readdata     (mgmt_ide0_readdata),
	.mgmt_write        (mgmt_write & mgmt_ide0_cs),
	.mgmt_read         (mgmt_read & mgmt_ide0_cs),

	.request           (ide0_request),
	.irq               (irq_14)
);

wire        ide1_io_read  = (iobus_read & ide1_cs) | (iobus_ide_read & ide1_cs);
wire        ide1_io_write = (iobus_write & ide1_cs) | (iobus_ide_write & ide1_cs);
wire [3:0]  ide1_io_addr  = (iobus_ide_read | iobus_ide_write) ? iobus_ide_address : ide_address;
wire [31:0] ide1_io_wdata = (iobus_ide_read | iobus_ide_write) ? iobus_ide_writedata : {24'h0, iobus_writedata_byte};
wire        ide1_io_32    = (iobus_ide_read | iobus_ide_write) ? iobus_ide_32 : 1'b0;

ide ide1
(
	.clk               (clk_sys),
	.rst_n             (~ide1_reset),

	.io_address        (ide1_io_addr),
	.io_writedata      (ide1_io_wdata),
	.io_read           (ide1_io_read),
	.io_write          (ide1_io_write),
	.io_readdata       (ide1_readdata),
	.io_32             (ide1_io_32),

	.use_fast          (1'b0),
	.no_data           (),
    .drive_en          (),
    .io_wait           (),

	.mgmt_address      (mgmt_address[3:0]),
	.mgmt_writedata    (mgmt_writedata),
	.mgmt_readdata     (mgmt_ide1_readdata),
	.mgmt_write        (mgmt_write & mgmt_ide1_cs),
	.mgmt_read         (mgmt_read & mgmt_ide1_cs),

	.request           (ide1_request),
	.irq               (irq_15)
);

// timers
pit pit
(
	.clk               (clk_sys),
	.rst_n             (~rst[6]),

	.clock_rate        (clock_rate),

	.io_address        ({iobus_address[5],iobus_address[1:0]}),
	.io_writedata      (iobus_writedata_byte),
	.io_readdata       (pit_readdata),
	.io_read           (iobus_read & pit_cs),
	.io_write          (iobus_write & pit_cs),

	.speaker_out       (speaker_out),
	.irq               (irq_0)
);

// Internal PS/2 wires from keyboard device to controller
wire kbd_ps2_clk;
wire kbd_ps2_dat;
// Internal PS/2 wires from mouse device to controller
wire mouse_ps2_clk;
wire mouse_ps2_dat;
wire ps2_reset_n;
assign software_reset = ~ps2_reset_n;

ps2 ps2
(
	.clk               (clk_sys),
	.rst_n             (~rst[7]),

	.io_address        (iobus_address[3:0]),
	.io_writedata      (iobus_writedata_byte),
	.io_read           (iobus_read),
	.io_write          (iobus_write),
	.io_readdata       (ps2_readdata),
	.io_cs             (ps2_io_cs),
	.ctl_cs            (ps2_ctl_cs),

	.ps2_kbclk         (kbd_ps2_clk),
	.ps2_kbdat         (kbd_ps2_dat),
	.ps2_kbclk_out     (ps2_kbclk_out),
	.ps2_kbdat_out     (ps2_kbdat_out),

	// Route mouse via internal PS/2 device generator
	.ps2_mouseclk      (mouse_ps2_clk),
	.ps2_mousedat      (mouse_ps2_dat),
	.ps2_mouseclk_out  (ps2_mouseclk_out),
	.ps2_mousedat_out  (ps2_mousedat_out),

	.output_a20_enable (),
	.output_reset_n    (ps2_reset_n),
	.a20_enable        (a20_enable),

	.irq_keyb          (irq_1),
	.irq_mouse         (irq_12)
);

rtc rtc
(
	.clk               (clk_sys),
	.rst_n             (~rst[8]),

	.clock_rate        (clock_rate),

	.io_address        (iobus_address[0]),
	.io_writedata      (iobus_writedata_byte),
	.io_read           (iobus_read & rtc_cs),
	.io_write          (iobus_write & rtc_cs),
	.io_readdata       (rtc_readdata),

	.mgmt_address      (mgmt_address[7:0]),
	.mgmt_write        (mgmt_write & mgmt_rtc_cs),
	.mgmt_writedata    (mgmt_writedata[7:0]),

	.bootcfg           ({bootcfg[5:2], bootcfg[1:0] ? bootcfg[1:0] : {~fdd0_inserted, fdd0_inserted}}),
	.ram_size          (ram_size),

	.irq               (irq_8)
);

sound #(
	.ENABLE_CMS(ENABLE_CMS)
) sound
(
	.clk               (clk_sys),
	.clk_audio         (clk_audio),
	.rst_n             (~rst[15]),

	.clock_rate        (clock_rate),

	.address           (iobus_address[3:0]),
	.writedata         (iobus_writedata_byte),
	.read              (iobus_read),
	.write             (iobus_write),
	.readdata          (sound_readdata),
	.sb_cs             (sb_cs),
	.fm_cs             (fm_cs),

	.dma_req8          (dma_sb_req_8),
	.dma_req16         (dma_sb_req_16),
	.dma_ack           (dma_sb_ack_16 | dma_sb_ack_8),
	.dma_readdata      (dma_sb_req_16 ? dma_sb_readdata_16 : dma_sb_readdata_8),
	.dma_writedata     (dma_sb_writedata),

	.sbp               (sbp),

	.vol_master_l      (vol_master_l),
	.vol_master_r      (vol_master_r),
	.vol_voice_l       (vol_voice_l),
	.vol_voice_r       (vol_voice_r),
	.vol_cd_l          (vol_cd_l),
	.vol_cd_r          (vol_cd_r),
	.vol_midi_l        (vol_midi_l),
	.vol_midi_r        (vol_midi_r),
	.vol_line_l        (vol_line_l),
	.vol_line_r        (vol_line_r),
	.vol_spk           (vol_spk),
	.vol_en            (vol_en),

	.sample_cms_l      (sample_cms_l),
	.sample_cms_r      (sample_cms_r),
	.sample_sb_l       (sample_sb_l),
	.sample_sb_r       (sample_sb_r),
	.sample_opl_l      (sample_opl_l),
	.sample_opl_r      (sample_opl_r),

	.fm_mode           (sound_fm_mode),
	.cms_en            (sound_cms_en),

	.irq_5             (irq_5),
	.irq_7             (irq_7),
	.irq_10            (irq_10)
);

// MiSTer uses a normal streaming VGA source, so use the original ao486 vga.v
vga vga_inst
(
	.clk_sys           (clk_sys),
	.rst_n             (~rst[9]),
	.clk_vga           (clk_sys),
	.clock_rate_vga    (clock_rate),

	.io_address        (iobus_address[3:0]),
	.io_read           (iobus_read),
	.io_readdata       (vga_io_readdata),
	.io_write          (iobus_write),
	.io_writedata      (iobus_writedata_byte),
	.io_b_cs           (vga_b_cs),
	.io_c_cs           (vga_c_cs),
	.io_d_cs           (vga_d_cs),

	.mem_address       (vga_address),
	.mem_read          (vga_read),
	.mem_readdata      (vga_readdata),
	.mem_write         (vga_write),
	.mem_writedata     (vga_writedata),

	.irq               (irq_2),
	.vga_ce            (video_ce),
	.vga_blank_n       (video_blank_n),
	.vga_horiz_sync    (video_hsync),
	.vga_vert_sync     (video_vsync),
	.vga_r             (video_r),
	.vga_g             (video_g),
	.vga_b             (video_b),
	.vga_f60           (1'b1),
	.vga_memmode       (vga_memmode),
	.vga_pal_a         (video_pal_a),
	.vga_pal_d         (video_pal_d),
	.vga_pal_we        (video_pal_we),
	.vga_start_addr    (video_start_addr),
	.vga_wr_seg        (video_wr_seg),
	.vga_rd_seg        (video_rd_seg),
	.vga_width         (video_width),
	.vga_height        (video_height),
	.vga_flags         (video_flags),
	.vga_chain4        (video_chain4),
	.vga_map_mask      (video_map_mask),
	.vga_read_plane    (video_read_plane),
	.vga_write_mode    (video_write_mode),
	.vga_stride        (video_stride),
	.vga_off           (video_off),
	.vga_lores         (1'b0),
	.vga_border        (video_border)
);


pic pic
(
	.clk               (clk_sys),
	.rst_n             (~rst[10]),

	.io_address        (iobus_address[0]),
	.io_writedata      (iobus_writedata_byte),
	.io_read           (iobus_read),
	.io_write          (iobus_write),
	.io_readdata       (pic_readdata),
	.io_master_cs      (pic_master_cs),
	.io_slave_cs       (pic_slave_cs),

	.interrupt_vector  (interrupt_vector),
	.interrupt_done    (interrupt_done),
	.interrupt_do      (interrupt_do),
	.interrupt_input   (interrupt)
);

always @* begin
	interrupt = 0;

	interrupt[0]  = irq_0;
	interrupt[1]  = irq_1;
	interrupt[3]  = irq_3;
	interrupt[4]  = irq_4;
	interrupt[5]  = irq_5;
	interrupt[6]  = irq_6;
	interrupt[7]  = irq_7;
	interrupt[8]  = irq_8;
	interrupt[9]  = irq_9 | irq_2;
	interrupt[10] = irq_10;
	interrupt[12] = irq_12;
	interrupt[14] = irq_14;
	interrupt[15] = irq_15;
end

assign mgmt_ide0_cs  = (mgmt_address[15:8] == 8'hF0);
assign mgmt_ide1_cs  = (mgmt_address[15:8] == 8'hF1);
assign mgmt_fdd_cs   = (mgmt_address[15:8] == 8'hF2);
assign mgmt_rtc_cs   = (mgmt_address[15:8] == 8'hF4);
assign mgmt_readdata = mgmt_ide0_cs ? mgmt_ide0_readdata : mgmt_ide1_cs ? mgmt_ide1_readdata : mgmt_fdd_readdata;

// Debug output assignments
assign debug_bios_loaded = bios_loaded;
assign debug_vga_bios_sig_bad = vga_bios_sig_bad;
assign debug_vga_bios_sig_checked = vga_bios_sig_checked;
assign debug_first_instruction = first_instruction_executed;

function [7:0] watchdog_hex(input [3:0] nibble);
begin
    watchdog_hex = (nibble < 4'd10) ? ("0" + nibble) : ("A" + nibble - 4'd10);
end
endfunction

function [7:0] watchdog_msg_char(input [1:0] msg, input [5:0] index);
begin
    // R=0 CPU, R=1 memory manager, R=2 external bus, R=3 x87.
    case (index)
        6'd0: watchdog_msg_char = "Z";
        6'd1: watchdog_msg_char = "3";
        6'd2: watchdog_msg_char = "8";
        6'd3: watchdog_msg_char = "6";
        6'd4: watchdog_msg_char = " ";
        6'd5: watchdog_msg_char = "S";
        6'd6: watchdog_msg_char = "T";
        6'd7: watchdog_msg_char = "A";
        6'd8: watchdog_msg_char = "L";
        6'd9: watchdog_msg_char = "L";
        6'd10: watchdog_msg_char = " ";
        6'd11: watchdog_msg_char = "R";
        6'd12: watchdog_msg_char = "=";
        6'd13: watchdog_msg_char = watchdog_hex({2'b00, msg});
        6'd14: watchdog_msg_char = " ";
        6'd15: watchdog_msg_char = "C";
        6'd16: watchdog_msg_char = "=";
        6'd17: watchdog_msg_char = watchdog_hex(watchdog_cs_snapshot[15:12]);
        6'd18: watchdog_msg_char = watchdog_hex(watchdog_cs_snapshot[11:8]);
        6'd19: watchdog_msg_char = watchdog_hex(watchdog_cs_snapshot[7:4]);
        6'd20: watchdog_msg_char = watchdog_hex(watchdog_cs_snapshot[3:0]);
        6'd21: watchdog_msg_char = " ";
        6'd22: watchdog_msg_char = "E";
        6'd23: watchdog_msg_char = "=";
        6'd24: watchdog_msg_char = watchdog_hex(watchdog_eip_snapshot[31:28]);
        6'd25: watchdog_msg_char = watchdog_hex(watchdog_eip_snapshot[27:24]);
        6'd26: watchdog_msg_char = watchdog_hex(watchdog_eip_snapshot[23:20]);
        6'd27: watchdog_msg_char = watchdog_hex(watchdog_eip_snapshot[19:16]);
        6'd28: watchdog_msg_char = watchdog_hex(watchdog_eip_snapshot[15:12]);
        6'd29: watchdog_msg_char = watchdog_hex(watchdog_eip_snapshot[11:8]);
        6'd30: watchdog_msg_char = watchdog_hex(watchdog_eip_snapshot[7:4]);
        6'd31: watchdog_msg_char = watchdog_hex(watchdog_eip_snapshot[3:0]);
        6'd32: watchdog_msg_char = " ";
        6'd33: watchdog_msg_char = "X";
        6'd34: watchdog_msg_char = "=";
        6'd35: watchdog_msg_char = watchdog_hex(watchdog_x87_snapshot[31:28]);
        6'd36: watchdog_msg_char = watchdog_hex(watchdog_x87_snapshot[27:24]);
        6'd37: watchdog_msg_char = watchdog_hex(watchdog_x87_snapshot[23:20]);
        6'd38: watchdog_msg_char = watchdog_hex(watchdog_x87_snapshot[19:16]);
        6'd39: watchdog_msg_char = watchdog_hex(watchdog_x87_snapshot[15:12]);
        6'd40: watchdog_msg_char = watchdog_hex(watchdog_x87_snapshot[11:8]);
        6'd41: watchdog_msg_char = watchdog_hex(watchdog_x87_snapshot[7:4]);
        6'd42: watchdog_msg_char = watchdog_hex(watchdog_x87_snapshot[3:0]);
        6'd43: watchdog_msg_char = 8'h0D;
        6'd44: watchdog_msg_char = 8'h0A;
        default: watchdog_msg_char = 8'h00;
    endcase
end
endfunction

localparam integer WATCHDOG_STALL_CYCLES = SYS_FREQ / 2;

always @(posedge clk_sys) begin
    watchdog_uart_we <= 1'b0;

    if (reset) begin
        watchdog_eip_last <= 32'd0;
        watchdog_cs_last <= 16'd0;
        watchdog_cpu_stall_count <= 32'd0;
        watchdog_mm_stall_count <= 32'd0;
        watchdog_bus_stall_count <= 32'd0;
        watchdog_x87_stall_count <= 32'd0;
        watchdog_cpu_reported <= 1'b0;
        watchdog_mm_reported <= 1'b0;
        watchdog_bus_reported <= 1'b0;
        watchdog_x87_reported <= 1'b0;
        watchdog_uart_active <= 1'b0;
        watchdog_uart_msg <= 2'd0;
        watchdog_uart_index <= 6'd0;
        watchdog_uart_byte <= 8'd0;
        watchdog_cs_snapshot <= 16'd0;
        watchdog_eip_snapshot <= 32'd0;
        watchdog_x87_snapshot <= 32'd0;
    end else begin
        if (boot_done && cpu_reset_n) begin
            if (debug_cpu_eip != watchdog_eip_last || debug_cpu_cs != watchdog_cs_last) begin
                watchdog_eip_last <= debug_cpu_eip;
                watchdog_cs_last <= debug_cpu_cs;
                watchdog_cpu_stall_count <= 32'd0;
                watchdog_cpu_reported <= 1'b0;
            end else if (watchdog_cpu_stall_count != WATCHDOG_STALL_CYCLES) begin
                watchdog_cpu_stall_count <= watchdog_cpu_stall_count + 32'd1;
            end

            if (mm_valid && !mm_ready) begin
                if (watchdog_mm_stall_count != WATCHDOG_STALL_CYCLES)
                    watchdog_mm_stall_count <= watchdog_mm_stall_count + 32'd1;
            end else begin
                watchdog_mm_stall_count <= 32'd0;
                watchdog_mm_reported <= 1'b0;
            end

            if (cpu_mem_valid && !mem_bus_ready) begin
                if (watchdog_bus_stall_count != WATCHDOG_STALL_CYCLES)
                    watchdog_bus_stall_count <= watchdog_bus_stall_count + 32'd1;
            end else begin
                watchdog_bus_stall_count <= 32'd0;
                watchdog_bus_reported <= 1'b0;
            end

            if (!debug_x87_state[31]) begin
                if (watchdog_x87_stall_count != WATCHDOG_STALL_CYCLES)
                    watchdog_x87_stall_count <= watchdog_x87_stall_count + 32'd1;
            end else begin
                watchdog_x87_stall_count <= 32'd0;
                watchdog_x87_reported <= 1'b0;
            end

            if (!watchdog_uart_active && watchdog_x87_stall_count == WATCHDOG_STALL_CYCLES && !watchdog_x87_reported) begin
                watchdog_uart_active <= 1'b1;
                watchdog_uart_msg <= 2'd3;
                watchdog_uart_index <= 6'd0;
                watchdog_x87_reported <= 1'b1;
                watchdog_cs_snapshot <= debug_cpu_cs;
                watchdog_eip_snapshot <= debug_cpu_eip;
                watchdog_x87_snapshot <= debug_x87_state;
            end else if (!watchdog_uart_active && watchdog_mm_stall_count == WATCHDOG_STALL_CYCLES && !watchdog_mm_reported) begin
                watchdog_uart_active <= 1'b1;
                watchdog_uart_msg <= 2'd1;
                watchdog_uart_index <= 6'd0;
                watchdog_mm_reported <= 1'b1;
                watchdog_cs_snapshot <= debug_cpu_cs;
                watchdog_eip_snapshot <= debug_cpu_eip;
                watchdog_x87_snapshot <= debug_x87_state;
            end else if (!watchdog_uart_active && watchdog_bus_stall_count == WATCHDOG_STALL_CYCLES && !watchdog_bus_reported) begin
                watchdog_uart_active <= 1'b1;
                watchdog_uart_msg <= 2'd2;
                watchdog_uart_index <= 6'd0;
                watchdog_bus_reported <= 1'b1;
                watchdog_cs_snapshot <= debug_cpu_cs;
                watchdog_eip_snapshot <= debug_cpu_eip;
                watchdog_x87_snapshot <= debug_x87_state;
            end else if (!watchdog_uart_active && watchdog_cpu_stall_count == WATCHDOG_STALL_CYCLES && !watchdog_cpu_reported) begin
                watchdog_uart_active <= 1'b1;
                watchdog_uart_msg <= 2'd0;
                watchdog_uart_index <= 6'd0;
                watchdog_cpu_reported <= 1'b1;
                watchdog_cs_snapshot <= debug_cpu_cs;
                watchdog_eip_snapshot <= debug_cpu_eip;
                watchdog_x87_snapshot <= debug_x87_state;
            end
        end else begin
            watchdog_eip_last <= debug_cpu_eip;
            watchdog_cs_last <= debug_cpu_cs;
            watchdog_cpu_stall_count <= 32'd0;
            watchdog_mm_stall_count <= 32'd0;
            watchdog_bus_stall_count <= 32'd0;
            watchdog_x87_stall_count <= 32'd0;
        end

        if (watchdog_uart_active) begin
            watchdog_uart_byte <= watchdog_msg_char(watchdog_uart_msg, watchdog_uart_index);
            if (watchdog_msg_char(watchdog_uart_msg, watchdog_uart_index) == 8'h00) begin
                watchdog_uart_active <= 1'b0;
            end else begin
                watchdog_uart_we <= 1'b1;
                watchdog_uart_index <= watchdog_uart_index + 5'd1;
            end
        end
    end
end

// Detect first instruction execution at reset vector f000:fff0
// exe_eip points to next instruction, so when exe_eip >= 0xFFF1, we're executing at 0xFFF0
always @(posedge clk_sys) begin
    if (reset) begin
        first_instruction_executed <= 0;
    end else if (cpu_reset_n && !first_instruction_executed && debug_cpu_cs == 16'hF000 && debug_cpu_eip >= 32'hFFF1 && debug_cpu_eip <= 32'hFFFF) begin
        first_instruction_executed <= 1;
        $display("DEBUG: First instruction executed at reset vector F000:FFF0 (exe_eip = %08x)", debug_cpu_eip);
    end
end


// Use the external PS/2 wire interface in both hardware and simulation.
assign kbd_ps2_clk  = ps2_kbclk_in;
assign kbd_ps2_dat  = ps2_kbdat_in;

    // PS/2 mouse device: translate UART-injected mouse bytes to PS/2 lines
// Also expose host->device bytes via rdata so we can forward them over UART
// wire [8:0] mouse_host_cmd;
// rd comes from top-level uart2ps2
// reg        mouse_host_cmd_rd;
assign mouse_ps2_clk = ps2_mouseclk_in;
assign mouse_ps2_dat = ps2_mousedat_in;
assign mouse_host_cmd = 9'd0;

assign sd_clk       = 1'b0;
assign sd_cmd       = 1'bz;
assign sd_dat       = 4'bzzzz;
assign img_lba      = 32'd0;
assign img_blk_cnt  = 6'd0;
assign img_rd       = 1'b0;
assign img_wr       = 1'b0;
assign img_buff_addr = 13'd0;
assign img_buff_dout = 16'd0;
assign img_buff_wr   = 1'b0;

//
// Boot loader FSM
// Main_MiSTer stages ROM bytes in the ao486-compatible shared DDR window
// 0x300C0000-0x300FFFFF. On every reset, copy that 256 KiB image into the
// writable low ROM/RAM window and the high reset-vector mirror in SDRAM.
//
always @(posedge clk_sys) begin
    if (rst[13]) begin
        boot_state <= BOOT_IDLE;
        boot_done <= 1'b0;
        cpu_reset_n <= 0;
        cpu_warm_reset_count <= 4'd0;
        boot_addr <= 32'd0;
        boot_read_data <= 64'd0;
        boot_dest_addr <= 32'd0;
        boot_write_phase <= 2'd0;
        ddram_rd_r <= 1'b0;
        sd_avm_address <= 32'd0;
        sd_avm_writedata <= 32'd0;
        sd_avm_byteenable <= 4'd0;
        sd_avm_write <= 1'b0;
		debug_boot_stage <= 0;
        bios_loaded <= 0;
        vga_bios_sig_bad <= 0;
        vga_bios_sig_checked <= 0;
		debug_sd_error <= 0;
        debug_post_code <= 8'd0;
        debug_post_write <= 1'b0;
    end else begin
        debug_post_write <= 1'b0;
        sd_avm_write <= 1'b0;
        ddram_rd_r <= 1'b0;
        
        case (boot_state)
            BOOT_IDLE: if (!mem_busy) begin
                boot_addr <= 32'd0;
                debug_boot_stage <= 1;
                debug_sd_error <= 0;
                $display("BOOT: copying DDR ROM window 0xC0000-0xFFFFF");
                boot_state <= BOOT_DDR_REQ;
            end

            BOOT_DDR_REQ: begin
                if (!ddram_busy) begin
                    ddram_rd_r <= 1'b1;
                    debug_boot_stage <= 2;
                    boot_state <= BOOT_DDR_WAIT;
                end
            end

            BOOT_DDR_WAIT: begin
                if (ddram_dout_ready) begin
                    boot_read_data <= ddram_dout;
                    boot_dest_addr <= 32'h000C0000 + boot_addr;
                    boot_write_phase <= 2'd0;
                    debug_boot_stage <= 3;

                    if (!vga_bios_sig_checked && boot_addr == 32'd0) begin
                        vga_bios_first_word <= ddram_dout[15:0];
                        vga_bios_sig_checked <= 1'b1;
                        vga_bios_sig_bad <= ddram_dout[15:0] != 16'hAA55;
                    end

                    boot_state <= BOOT_WRITE_COPY;
                end
            end

            BOOT_WRITE_COPY: begin
                case (boot_write_phase)
                    2'd0: begin
                        sd_avm_address <= boot_dest_addr;
                        sd_avm_writedata <= boot_read_data[31:0];
                    end
                    2'd1: begin
                        sd_avm_address <= boot_dest_addr + 32'd4;
                        sd_avm_writedata <= boot_read_data[63:32];
                    end
                    2'd2: begin
                        sd_avm_address <= BIOS_MIRROR_BASE + boot_addr;
                        sd_avm_writedata <= boot_read_data[31:0];
                    end
                    default: begin
                        sd_avm_address <= BIOS_MIRROR_BASE + boot_addr + 32'd4;
                        sd_avm_writedata <= boot_read_data[63:32];
                    end
                endcase

                sd_avm_byteenable <= 4'b1111;
                sd_avm_write <= 1'b1;

                if (mm_ready) begin
                    if (boot_write_phase != 2'd3) begin
                        boot_write_phase <= boot_write_phase + 2'd1;
                    end else if (boot_addr == 32'h0003FFF8) begin
                        bios_loaded <= 1'b1;
                        debug_boot_stage <= 4;
                        $display("BOOT: DDR ROM copy complete");
                        boot_state <= BOOT_COMPLETE;
                    end else begin
                        boot_addr <= boot_addr + 32'd8;
                        boot_state <= BOOT_DDR_REQ;
                    end
                end
            end
            
            BOOT_COMPLETE: begin
                boot_done <= 1;

                // A 386 shutdown bus cycle asks the motherboard to pulse the
                // CPU RESET pin. Preserve RAM, CMOS, and peripheral state so
                // the BIOS can follow the warm-reset vector prepared by the
                // software that deliberately caused the triple fault.
                if (cpu_triple_fault_reset) begin
                    cpu_reset_n <= 1'b0;
                    cpu_warm_reset_count <= 4'hf;
                end else if (cpu_warm_reset_count != 4'd0) begin
                    cpu_warm_reset_count <= cpu_warm_reset_count - 4'd1;
                    cpu_reset_n <= cpu_warm_reset_count == 4'd1;
                end else begin
                    cpu_reset_n <= 1'b1;
                end
				debug_boot_stage <= 5;
            end
        endcase

        // BIOS POST/debug progress ports. Bochs BIOS commonly uses 0x80 while
        // the current simulation notes also mention 0x190, so latch both.
        if (iobus_write && (iobus_address == 16'h0080 || iobus_address == 16'h0190)) begin
            debug_post_code <= iobus_writedata_byte;
            debug_post_write <= 1'b1;
        end
    end
end


// -----------------------------------------------------------------------------
// Minimal MPU-401 UART/dumb mode output.
// Writes to port 330h are serialized to MiSTer HPS UART/MidiLink.
// Port 331h is treated as MPU command/status.
// This is not full intelligent MPU-401; it is enough for basic UART-mode MIDI.
// -----------------------------------------------------------------------------

reg  [7:0] mpu_fifo [0:255];
reg  [7:0] mpu_fifo_wr;
reg  [7:0] mpu_fifo_rd;
reg  [8:0] mpu_fifo_count;

reg  [7:0] mpu_tx_data;
reg        mpu_tx_wr;
wire       mpu_tx_busy;

reg        mpu_ack_pending;

wire       mpu_fifo_full  = (mpu_fifo_count == 9'd256);
wire       mpu_fifo_empty = (mpu_fifo_count == 9'd0);

wire       mpu_data_write = iobus_write && mpu_cs && !iobus_address[0] && !mpu_fifo_full;
wire       mpu_cmd_write  = iobus_write && mpu_cs &&  iobus_address[0];
wire       mpu_data_read  = iobus_read  && mpu_cs && !iobus_address[0];
wire       mpu_dequeue    = !mpu_tx_busy && !mpu_fifo_empty && !mpu_tx_wr;

// MPU status register at 331h:
// bit 7 = 0: ACK/data available to host
// bit 7 = 1: no data available
// bit 6 = 0: ready to accept command/data
// bit 6 = 1: FIFO full
assign mpu_readdata = iobus_address[0]
                    ? (mpu_ack_pending ? 8'h00 : (mpu_fifo_full ? 8'hC0 : 8'h80))
                    : 8'hFE;

always @(posedge clk_sys) begin
    mpu_tx_wr <= 1'b0;

    if (reset) begin
        mpu_fifo_wr     <= 8'd0;
        mpu_fifo_rd     <= 8'd0;
        mpu_fifo_count  <= 9'd0;
        mpu_tx_data     <= 8'd0;
        mpu_ack_pending <= 1'b0;
    end else begin
        // Port 331h: MPU command. Return generic ACK 0xFE on port 330h.
        if (mpu_cmd_write) begin
            mpu_ack_pending <= 1'b1;
        end

        // Port 330h read consumes ACK.
        if (mpu_data_read && mpu_ack_pending) begin
            mpu_ack_pending <= 1'b0;
        end

        // Port 330h write: MIDI data byte.
        if (mpu_data_write) begin
            mpu_fifo[mpu_fifo_wr] <= iobus_writedata_byte;
            mpu_fifo_wr <= mpu_fifo_wr + 8'd1;
        end

        // Serialize FIFO to UART.
        if (mpu_dequeue) begin
            mpu_tx_data <= mpu_fifo[mpu_fifo_rd];
            mpu_fifo_rd <= mpu_fifo_rd + 8'd1;
            mpu_tx_wr   <= 1'b1;
        end

        case ({mpu_data_write, mpu_dequeue})
            2'b10: mpu_fifo_count <= mpu_fifo_count + 9'd1;
            2'b01: mpu_fifo_count <= mpu_fifo_count - 9'd1;
            default: mpu_fifo_count <= mpu_fifo_count;
        endcase
    end
end

uart_tx_V2 mpu_uart_tx_i
(
    .clk      (clk_sys),
    .din      (mpu_tx_data),
    .wr_en    (mpu_tx_wr),
    .tx_busy  (mpu_tx_busy),
    .tx_p     (mpu_uart_tx)
);

defparam mpu_uart_tx_i.clk_freq  = SYS_FREQ;
defparam mpu_uart_tx_i.uart_freq = 31250;

// Export debug byte for UART bridge to wrap as type 0x07
wire bios_dbg_write = iobus_write && debug_port_cs;
assign dbg_uart_byte = bios_dbg_write ? iobus_writedata_byte : watchdog_uart_byte;
assign dbg_uart_we   = bios_dbg_write | watchdog_uart_we;

endmodule
