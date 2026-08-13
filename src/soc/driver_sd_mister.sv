// MiSTer-oriented SD/boot bridge for z486.
//
// Exposes the legacy driver_sd register/DMA interface expected by system.sv,
// but sources data from:
// - HPS-uploaded boot ROM windows (boot0/boot1)
// - an HPS-uploaded 3-sector config blob
// - a mounted flat disk image via the standard MiSTer sd_* block interface
//
// Layout intentionally matches the previous synthetic boot-area harness:
//   LBA 0..511   -> 256 KiB boot area
//   LBA 512..514 -> config sectors
//   LBA 576+     -> mounted flat disk image, sector 0+
//
// Write support for the mounted disk is intentionally not implemented yet.
// Boot bringup only needs reads. Write commands currently complete as no-ops.

module driver_sd_mister (
    input               clk,
    input               rst_n,

    input       [1:0]   avs_address,
    input               avs_read,
    output reg  [31:0]  avs_readdata,
    input               avs_write,
    input       [31:0]  avs_writedata,

    output reg  [31:0]  avm_address,
    input               avm_waitrequest,
    output reg          avm_read,
    input       [31:0]  avm_readdata,
    input               avm_readdatavalid,
    output reg          avm_write,
    output reg  [31:0]  avm_writedata,

    input               ioctl_download,
    input       [15:0]  ioctl_index,
    input               ioctl_wr,
    input       [26:0]  ioctl_addr,
    input       [15:0]  ioctl_dout,
    input               img_mounted,
    input               img_readonly,
    input       [63:0]  img_size,
    output reg  [31:0]  img_lba,
    output reg  [5:0]   img_blk_cnt,
    output reg          img_rd,
    output reg          img_wr,
    input               img_ack,
    output reg  [12:0]  img_buff_addr,
    input       [15:0]  img_buff_din,
    output reg  [15:0]  img_buff_dout,
    output reg          img_buff_wr,

    output reg          sd_clk,
    inout               sd_cmd,
    inout       [3:0]   sd_dat
);

localparam [15:0] IOCTL_BOOT0  = 16'd0;
localparam [15:0] IOCTL_BOOT1  = 16'd1;
localparam [15:0] IOCTL_CONFIG = 16'd2;

localparam [31:0] CONFIG_OFFSET   = 32'd262144; // 512 * 512
localparam [31:0] BOOT0_OFFSET_64 = 32'd196608; // 0x30000 -> 0xF0000
localparam [31:0] BOOT0_OFFSET_128 = 32'd131072; // 0x20000 -> 0xE0000
localparam [31:0] BOOT1_OFFSET    = 32'd0;
localparam [31:0] DISK_OFFSET    = 32'd294912; // 288 KiB
localparam [31:0] DISK_LBA_BASE  = DISK_OFFSET >> 9; // 576
localparam integer BOOT0_WORDS   = 65536;
localparam integer BOOT1_WORDS   = 16384;
localparam integer CONFIG_WORDS  = 768; // 3 sectors

localparam [3:0] ST_IDLE        = 4'd0;
localparam [3:0] ST_READ_SYNTH  = 4'd1;
localparam [3:0] ST_READ_REQ    = 4'd2;
localparam [3:0] ST_READ_LO_A   = 4'd3;
localparam [3:0] ST_READ_LO_D   = 4'd4;
localparam [3:0] ST_READ_HI_D   = 4'd5;
localparam [3:0] ST_READ_DMA    = 4'd6;

(* ramstyle = "M9K,no_rw_check" *) reg [15:0] boot0_rom [0:BOOT0_WORDS-1];
(* ramstyle = "M9K,no_rw_check" *) reg [15:0] boot1_rom [0:BOOT1_WORDS-1];
(* ramstyle = "M9K,no_rw_check" *) reg [15:0] cfg_rom   [0:CONFIG_WORDS-1];

reg [3:0]  state;
reg [31:0] base_address;
reg [23:0] sd_sector;
reg [7:0]  sd_sector_count;

reg [23:0] cur_sector;
reg [7:0]  sectors_left;
reg [31:0] cur_address;
reg [8:0]  sector_byte_ofs;
reg [7:0]  hps_word_index;
reg [15:0] read_lo16;
reg [15:0] read_hi16;
reg        ioctl_download_r;
reg        boot0_is_128k;

wire [63:0] img_sectors = img_size[63:9] + |img_size[8:0];

assign sd_cmd = 1'bz;
assign sd_dat = 4'bzzzz;

function automatic [7:0] synthetic_byte(input [31:0] byte_addr);
    reg [31:0] rel;
    begin
        synthetic_byte = 8'h00;
        if (byte_addr < 32'd32768) begin
            rel = byte_addr - BOOT1_OFFSET;
            synthetic_byte = rel[0] ? boot1_rom[rel[14:1]][15:8] : boot1_rom[rel[14:1]][7:0];
        end else if (boot0_is_128k && byte_addr >= BOOT0_OFFSET_128 && byte_addr < BOOT0_OFFSET_128 + 32'd131072) begin
            rel = byte_addr - BOOT0_OFFSET_128;
            synthetic_byte = rel[0] ? boot0_rom[rel[16:1]][15:8] : boot0_rom[rel[16:1]][7:0];
        end else if (!boot0_is_128k && byte_addr >= BOOT0_OFFSET_64 && byte_addr < BOOT0_OFFSET_64 + 32'd65536) begin
            rel = byte_addr - BOOT0_OFFSET_64;
            synthetic_byte = rel[0] ? boot0_rom[rel[15:1]][15:8] : boot0_rom[rel[15:1]][7:0];
        end else if (byte_addr >= CONFIG_OFFSET && byte_addr < CONFIG_OFFSET + 32'd1536) begin
            rel = byte_addr - CONFIG_OFFSET;
            synthetic_byte = rel[0] ? cfg_rom[rel[10:1]][15:8] : cfg_rom[rel[10:1]][7:0];
        end
    end
endfunction

function automatic [31:0] synthetic_dword(input [23:0] lba, input [8:0] byte_ofs);
    reg [31:0] byte_addr;
    begin
        byte_addr = {8'd0, lba, 9'd0} + byte_ofs;
        synthetic_dword = {
            synthetic_byte(byte_addr + 32'd3),
            synthetic_byte(byte_addr + 32'd2),
            synthetic_byte(byte_addr + 32'd1),
            synthetic_byte(byte_addr + 32'd0)
        };
    end
endfunction

task automatic advance_sector;
    begin
        cur_sector <= cur_sector + 24'd1;
        sectors_left <= sectors_left - 8'd1;
        cur_address <= cur_address + 32'd512;
        sector_byte_ofs <= 9'd0;
    end
endtask

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= ST_IDLE;
        avs_readdata <= 32'd0;
        avm_address <= 32'd0;
        avm_read <= 1'b0;
        avm_write <= 1'b0;
        avm_writedata <= 32'd0;
        base_address <= 32'd0;
        sd_sector <= 24'd0;
        sd_sector_count <= 8'd0;
        cur_sector <= 24'd0;
        sectors_left <= 8'd0;
        cur_address <= 32'd0;
        sector_byte_ofs <= 9'd0;
        hps_word_index <= 8'd0;
        read_lo16 <= 16'd0;
        read_hi16 <= 16'd0;
        ioctl_download_r <= 1'b0;
        boot0_is_128k <= 1'b0;
        sd_clk <= 1'b0;
        img_lba <= 32'd0;
        img_blk_cnt <= 6'd1;
        img_rd <= 1'b0;
        img_wr <= 1'b0;
        img_buff_addr <= 13'd0;
        img_buff_dout <= 16'd0;
        img_buff_wr <= 1'b0;
    end else begin
        ioctl_download_r <= ioctl_download;
        sd_clk <= ~sd_clk;
        avm_read <= 1'b0;
        avm_write <= 1'b0;
        img_buff_wr <= 1'b0;

        if (ioctl_download && !ioctl_download_r && ioctl_index == IOCTL_BOOT0)
            boot0_is_128k <= 1'b0;
        if (ioctl_wr && ioctl_index == IOCTL_BOOT0 && ioctl_addr[16])
            boot0_is_128k <= 1'b1;

        if (avs_read) begin
            avs_readdata <= 32'd0;
            if (avs_address == 2'd0) begin
                case (state)
                    ST_IDLE: avs_readdata <= 32'd2;
                    default: avs_readdata <= 32'd3;
                endcase
            end else if (avs_address == 2'd2) begin
                avs_readdata <= 32'd2;
            end
        end

        case (state)
            ST_IDLE: begin
                img_rd <= 1'b0;
                img_wr <= 1'b0;

                if (avs_write) begin
                    case (avs_address)
                        2'd0: base_address <= avs_writedata;
                        2'd1: sd_sector <= avs_writedata[23:0];
                        2'd2: sd_sector_count <= avs_writedata[7:0];
                        2'd3: begin
                            cur_sector <= sd_sector;
                            sectors_left <= sd_sector_count;
                            cur_address <= base_address;
                            sector_byte_ofs <= 9'd0;
                            hps_word_index <= 8'd0;

                            if (avs_writedata == 32'd2 && sd_sector_count != 8'd0) begin
                                if (sd_sector < DISK_LBA_BASE) state <= ST_READ_SYNTH;
                                else state <= ST_READ_REQ;
                            end
                            // Write support is deferred. Treat it as a completed no-op for now.
                        end
                    endcase
                end
            end

            ST_READ_SYNTH: begin
                avm_address <= cur_address + sector_byte_ofs;
                avm_writedata <= synthetic_dword(cur_sector, sector_byte_ofs);
                avm_write <= 1'b1;

                if (!avm_waitrequest) begin
                    if (sector_byte_ofs == 9'd508) begin
                        if (sectors_left == 8'd1) begin
                            state <= ST_IDLE;
                        end else begin
                            advance_sector();
                            if (cur_sector + 24'd1 >= DISK_LBA_BASE)
                                state <= ST_READ_REQ;
                        end
                    end else begin
                        sector_byte_ofs <= sector_byte_ofs + 9'd4;
                    end
                end
            end

            ST_READ_REQ: begin
                if (!img_mounted || (cur_sector - DISK_LBA_BASE) >= img_sectors[23:0]) begin
                    state <= ST_READ_SYNTH;
                end else begin
                    img_lba <= cur_sector - DISK_LBA_BASE;
                    img_blk_cnt <= 6'd1;
                    img_rd <= 1'b1;
                    if (img_ack) begin
                        img_rd <= 1'b0;
                        img_buff_addr <= 13'd0;
                        hps_word_index <= 8'd0;
                        state <= ST_READ_LO_A;
                    end
                end
            end

            ST_READ_LO_A: begin
                img_buff_addr <= {5'd0, hps_word_index};
                state <= ST_READ_LO_D;
            end

            ST_READ_LO_D: begin
                read_lo16 <= img_buff_din;
                img_buff_addr <= {5'd0, hps_word_index + 8'd1};
                state <= ST_READ_HI_D;
            end

            ST_READ_HI_D: begin
                read_hi16 <= img_buff_din;
                state <= ST_READ_DMA;
            end

            ST_READ_DMA: begin
                avm_address <= cur_address + {23'd0, hps_word_index, 1'b0};
                avm_writedata <= {read_hi16, read_lo16};
                avm_write <= 1'b1;

                if (!avm_waitrequest) begin
                    if (hps_word_index == 8'd254) begin
                        if (sectors_left == 8'd1) begin
                            state <= ST_IDLE;
                        end else begin
                            advance_sector();
                            state <= (cur_sector + 24'd1 < DISK_LBA_BASE) ? ST_READ_SYNTH : ST_READ_REQ;
                        end
                    end else begin
                        hps_word_index <= hps_word_index + 8'd2;
                        state <= ST_READ_LO_A;
                    end
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

always @(posedge clk) begin
    if (ioctl_wr) begin
        if (ioctl_index == IOCTL_BOOT0 && ioctl_addr[16:1] < BOOT0_WORDS)
            boot0_rom[ioctl_addr[15:1]] <= ioctl_dout;
        if (ioctl_index == IOCTL_BOOT1 && ioctl_addr[15:1] < BOOT1_WORDS)
            boot1_rom[ioctl_addr[14:1]] <= ioctl_dout;
        if (ioctl_index == IOCTL_CONFIG && ioctl_addr[11:1] < CONFIG_WORDS)
            cfg_rom[ioctl_addr[10:1]] <= ioctl_dout;
    end
end

endmodule
