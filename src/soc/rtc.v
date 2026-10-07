/*
 * Copyright (c) 2014, Aleksander Osman
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 * 
 * * Redistributions of source code must retain the above copyright notice, this
 *   list of conditions and the following disclaimer.
 * 
 * * Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

module rtc #(
	parameter [0:0] FPU_PRESENT = 1'b0
) (
	input             clk,
	input             rst_n,

	output reg        irq,

	//io slave
	input             io_address,
	input             io_read,
	output reg  [7:0] io_readdata,
	input             io_write,
	input       [7:0] io_writedata,

	input       [5:0] bootcfg,
	input       [1:0] ram_size,

	//mgmt slave
	/*
	128.[26:0]: cycles in second
	129.[12:0]: cycles in 122.07031 us
	*/
	input       [7:0] mgmt_address,
	input             mgmt_write,
	input       [7:0] mgmt_writedata,

	input      [27:0] clock_rate
);

reg [27:0] clk_rate;
always @(posedge clk) clk_rate <= clock_rate;

reg ce_8192hz;
reg [27:0] ce_8192hz_sum = 0;   // module scope: a block-local `automatic` accumulator
                                // re-initializes to 0 every clock (Verilator, and per SV
                                // semantics) so ce_8192hz never fired and the RTC froze.
always @(posedge clk) begin
	ce_8192hz = 0;
	ce_8192hz_sum = ce_8192hz_sum + 28'd8192;
	if(ce_8192hz_sum >= clk_rate) begin
		ce_8192hz_sum = ce_8192hz_sum - clk_rate;
		ce_8192hz = 1;
	end
end

//------------------------------------------------------------------------------

wire rtc_clock_running = ~(crb_freeze || divider[2:1] == 2'b11);
wire rtc_update_in_progress = rtc_clock_running && second_major <= 13'd1;
wire rtc_second_update = rtc_clock_running && ce_8192hz && second_major == 13'd0;

// HPS-written CMOS values the synthesized registers below are corrected
// against. Like the CMOS RAM they hold configuration, not core state: a core
// reset after the HPS wrote them must not clear them, or 2Eh/2Fh no longer
// match 10h-2Dh and Windows 95's ESDI_506 falls back to compatibility mode.
reg [7:0] mgmt_ext_mem_lsb = 8'h00;
reg [7:0] mgmt_ext_mem_msb = 8'h3C;
reg [7:0] mgmt_equipment = 8'h00;
reg [15:0] mgmt_checksum = 16'd0;

always @(posedge clk) begin
	if(mgmt_write) begin
		if(mgmt_address == 8'h17) mgmt_ext_mem_lsb <= mgmt_writedata;
		if(mgmt_address == 8'h18) mgmt_ext_mem_msb <= mgmt_writedata;
		if(mgmt_address == 8'h14) mgmt_equipment <= mgmt_writedata;
		if(mgmt_address == 8'h2E) mgmt_checksum[15:8] <= mgmt_writedata;
		if(mgmt_address == 8'h2F) mgmt_checksum[7:0] <= mgmt_writedata;
	end
end

// CMOS 17h/18h and 30h/31h report KiB above 1MB (capped at
// 65535). 34h/35h report 64KB blocks above 16MB.
reg [15:0] configured_ext_mem;
reg [15:0] configured_ext_mem_64k;
always @* begin
	case (ram_size)
	2'd0: begin configured_ext_mem = 16'h3C00; configured_ext_mem_64k = 16'h0000; end
	2'd1: begin configured_ext_mem = 16'h7C00; configured_ext_mem_64k = 16'h0100; end
	2'd2: begin configured_ext_mem = 16'hFC00; configured_ext_mem_64k = 16'h0300; end
	default: begin configured_ext_mem = 16'hFFFF; configured_ext_mem_64k = 16'h0700; end
	endcase
end
wire [15:0] configured_checksum =
    mgmt_checksum + {8'd0, configured_ext_mem[7:0]} + {8'd0, configured_ext_mem[15:8]}
                  - {8'd0, mgmt_ext_mem_lsb} - {8'd0, mgmt_ext_mem_msb};
// The integrated 8042 always exposes a PS/2 pointing-device port. BIOS INT
// 11h copies CMOS equipment bit 2 into the BDA, and DOS mouse drivers check
// that bit before calling the INT 15h/C2 services. Keep both synthesized
// equipment bits reflected in the checksum when absent from the HPS value.
wire [7:0] configured_equipment = mgmt_equipment |
    {5'd0, 1'b1, FPU_PRESENT, 1'b0};
wire [15:0] configured_checksum_with_equipment = configured_checksum +
    {13'd0, ~mgmt_equipment[2], FPU_PRESENT && ~mgmt_equipment[1], 1'b0};

reg io_read_last;
always @(posedge clk) begin if(rst_n == 1'b0) io_read_last <= 1'b0; else if(io_read_last) io_read_last <= 1'b0; else io_read_last <= io_read; end 
wire io_read_valid = io_read && io_read_last == 1'b0;

//------------------------------------------------------------------------------ io read

wire [7:0] io_readdata_next =
    (io_address == 1'b0)   ? 8'hFF :
    (ram_address == 7'h00) ? rtc_second :
    (ram_address == 7'h01) ? alarm_second :
    (ram_address == 7'h02) ? rtc_minute :
    (ram_address == 7'h03) ? alarm_minute :
    (ram_address == 7'h04) ? rtc_hour :
    (ram_address == 7'h05) ? alarm_hour :
    (ram_address == 7'h06) ? rtc_dayofweek :
    (ram_address == 7'h07) ? rtc_dayofmonth :
    (ram_address == 7'h08) ? rtc_month :
    (ram_address == 7'h09) ? rtc_year :
    (ram_address == 7'h0A) ? { rtc_update_in_progress, divider, periodic_rate } :
    (ram_address == 7'h0B) ? { crb_freeze, crb_int_periodic_ena, crb_int_alarm_ena, crb_int_update_ena,
                               1'b0, crb_binarymode, crb_24hour, crb_daylightsaving } :
    (ram_address == 7'h0C) ? { irq, periodic_interrupt, alarm_interrupt, update_interrupt, 4'd0 } :
    (ram_address == 7'h0D) ? 8'h80 :
    (ram_address == 7'h38) ? {2'b00, bootcfg[5:4], 4'h1} :
    (ram_address == 7'h3D) ? {2'b00, bootcfg[3:2], 2'b00, bootcfg[1:0]} :
    (ram_address == 7'h32) ? rtc_century :
    (ram_address == 7'h37) ? rtc_century :
    (ram_address == 7'h14) ? configured_equipment :
    (ram_address == 7'h17) ? configured_ext_mem[7:0] :
    (ram_address == 7'h18) ? configured_ext_mem[15:8] :
    (ram_address == 7'h2E) ? configured_checksum_with_equipment[15:8] :
    (ram_address == 7'h2F) ? configured_checksum_with_equipment[7:0] :
    (ram_address == 7'h30) ? configured_ext_mem[7:0] :
    (ram_address == 7'h31) ? configured_ext_mem[15:8] :
    (ram_address == 7'h34) ? configured_ext_mem_64k[7:0] :
    (ram_address == 7'h35) ? configured_ext_mem_64k[15:8] :
                             ram_q;

always @(posedge clk) begin
    io_readdata <= io_readdata_next;
end

//------------------------------------------------------------------------------ irq

wire interrupt_start = irq == 1'b0 && (
    (crb_int_periodic_ena && periodic_interrupt) ||
    (crb_int_alarm_ena    && alarm_interrupt) ||
    (crb_int_update_ena   && update_interrupt) );

always @(posedge clk) begin
    if(rst_n == 1'b0)                                                       irq <= 1'b0;
    else if(io_read_valid && io_address == 1'b1 && ram_address == 7'h0C)    irq <= 1'b0;
    else if(interrupt_start)                                                irq <= 1'b1;
end

//------------------------------------------------------------------------------ once per second state machine

// UIP should be high for about 244us before the RTC registers update.
// Count 8192Hz ticks so the second cadence and UIP window are independent.
reg [12:0] second_major;
always @(posedge clk) begin
    if(rst_n == 1'b0)             second_major <= 13'd8191;
    else if(~rtc_clock_running)   second_major <= 13'd8191;
    else if(ce_8192hz) begin
        if(second_major == 13'd0) second_major <= 13'd8191;
        else                      second_major <= second_major - 13'd1;
    end
end

reg update_interrupt;
always @(posedge clk) begin
    if(rst_n == 1'b0)                                                       update_interrupt <= 1'b0;
    else if(io_read_valid && io_address == 1'b1 && ram_address == 7'h0C)    update_interrupt <= 1'b0;
    else if(rtc_second_update)                                              update_interrupt <= 1'b1;
end

//------------------------------------------------------------------------------

wire max_second = 
    (crb_binarymode && rtc_second >= 8'd59) ||
    (~(crb_binarymode) && (rtc_second[7:4] >= 4'd6 || (rtc_second[7:4] == 4'd5 && rtc_second[3:0] >= 4'd9)));

wire [7:0] next_second =
    (max_second)?                                       8'd0 :
    (~(crb_binarymode) && rtc_second[3:0] >= 4'd9)?     { rtc_second[7:4] + 4'd1, 4'd0 } :
                                                        rtc_second + 8'd1;

wire max_minute = 
    (crb_binarymode && rtc_minute >= 8'd59) ||
    (~(crb_binarymode) && (rtc_minute[7:4] >= 4'd6 || (rtc_minute[7:4] == 4'd5 && rtc_minute[3:0] >= 4'd9)));

wire [7:0] next_minute =
    (max_minute)?                                       8'd0 :
    (~(crb_binarymode) && rtc_minute[3:0] >= 4'd9)?     { rtc_minute[7:4] + 4'd1, 4'd0 } :
                                                        rtc_minute + 8'd1;

wire dst_april   = crb_daylightsaving && rtc_dayofweek == 8'd1 && rtc_month == 8'd4 &&
    ((crb_binarymode && rtc_dayofmonth >= 8'd24) || (~(crb_binarymode) && rtc_dayofmonth[7:4] >= 4'd2 && rtc_dayofmonth[3:0] >= 4'd4)) &&
    rtc_hour == 8'd1;

wire dst_october = crb_daylightsaving && rtc_dayofweek == 8'd1 &&
    ((crb_binarymode && rtc_month == 8'd10) || (~(crb_binarymode) && rtc_month[7:4] == 4'd1 && rtc_month[3:0] == 4'd0)) &&
    ((crb_binarymode && rtc_dayofmonth >= 8'd25) || (~(crb_binarymode) && rtc_dayofmonth[7:4] >= 4'd2 && rtc_dayofmonth[3:0] >= 4'd5)) &&
    rtc_hour == 8'd1;
    
wire max_hour =
    (~(crb_24hour) && crb_binarymode    && rtc_hour[7] && rtc_hour[6:0] >= 7'd12) ||
    (crb_24hour    && crb_binarymode    && rtc_hour >= 8'd23) ||
    (~(crb_24hour) && ~(crb_binarymode) && rtc_hour[7] && (rtc_hour[6:4] >= 3'd2 || (rtc_hour[6:4] == 3'd1 && rtc_hour[3:0] >= 4'd2))) ||
    (crb_24hour    && ~(crb_binarymode) && (rtc_hour[7:4] >= 4'd3 || (rtc_hour[7:4] == 4'd2 && rtc_hour[3:0] >= 4'd3)));

wire [7:0] next_hour =
    (dst_april)?                                                                                8'd3 :
    (dst_october)?                                                                              8'd1 :
    (~(crb_24hour) && max_hour)?                                                                8'd1 :
    (crb_24hour    && max_hour)?                                                                8'd0 :
    (~(crb_24hour) && crb_binarymode    && rtc_hour[6:0] >= 7'd12)?                             8'h81 :
    (~(crb_24hour) && ~(crb_binarymode) && rtc_hour[6:4] == 3'd1 && rtc_hour[3:0] >= 4'd2)?     8'h81 :
    (~(crb_24hour) && ~(crb_binarymode) && rtc_hour[6:4] == 3'd0 && rtc_hour[3:0] >= 4'd9)?     { rtc_hour[7], 3'b1, 4'd0 }  :
    (crb_24hour    && ~(crb_binarymode) && rtc_hour[3:0] >= 4'd9)?                              { rtc_hour[7:4] + 4'd1, 4'd0 } :
                                                                                                rtc_hour + 8'd1;

wire max_dayofweek = rtc_dayofweek >= 8'd7;

wire [7:0] next_dayofweek =
    (max_dayofweek)?    8'd1 :
                        rtc_dayofweek + 8'd1;

//simplified leap year condition
wire leap_year =
    (crb_binarymode    && rtc_year[1:0] == 2'b00) ||
    (~(crb_binarymode) && ((rtc_year[1:0] == 2'b00 && rtc_year[4] == 1'b0) || (rtc_year[1:0] == 2'b10 && rtc_year[4] == 1'b1)));

wire max_dayofmonth = 
    (crb_binarymode && (
        (rtc_month <= 8'd1  && rtc_dayofmonth >= 8'd31) ||
        (rtc_month == 8'd2  && ((~(leap_year) && rtc_dayofmonth >= 8'd28) || (leap_year && rtc_dayofmonth >= 8'd29))) ||
        (rtc_month == 8'd3  && rtc_dayofmonth >= 8'd31) ||
        (rtc_month == 8'd4  && rtc_dayofmonth >= 8'd30) ||
        (rtc_month == 8'd5  && rtc_dayofmonth >= 8'd31) ||
        (rtc_month == 8'd6  && rtc_dayofmonth >= 8'd30) ||
        (rtc_month == 8'd7  && rtc_dayofmonth >= 8'd31) ||
        (rtc_month == 8'd8  && rtc_dayofmonth >= 8'd31) ||
        (rtc_month == 8'd9  && rtc_dayofmonth >= 8'd30) ||
        (rtc_month == 8'd10 && rtc_dayofmonth >= 8'd31) ||
        (rtc_month == 8'd11 && rtc_dayofmonth >= 8'd30) ||
        (rtc_month >= 8'd12 && rtc_dayofmonth >= 8'd31))
    ) ||
    (~(crb_binarymode) && (
        (rtc_month <= 8'h01 && (rtc_dayofmonth[7:4] >= 4'd4 || (rtc_dayofmonth[7:4] == 4'd3 && rtc_dayofmonth[3:0] >= 4'd1))) ||
        (rtc_month == 8'h02 && ((~(leap_year) && (rtc_dayofmonth[7:4] >= 4'd3 || (rtc_dayofmonth[7:4] == 4'd2 && rtc_dayofmonth[3:0] >= 4'd8))) ||
                               (leap_year    && (rtc_dayofmonth[7:4] >= 4'd3 || (rtc_dayofmonth[7:4] == 4'd2 && rtc_dayofmonth[3:0] >= 4'd9))))) ||
        (rtc_month == 8'h03 && (rtc_dayofmonth[7:4] >= 4'd4 || (rtc_dayofmonth[7:4] == 4'd3 && rtc_dayofmonth[3:0] >= 4'd1))) ||
        (rtc_month == 8'h04 && (rtc_dayofmonth[7:4] >= 4'd4 || (rtc_dayofmonth[7:4] == 4'd3))) ||
        (rtc_month == 8'h05 && (rtc_dayofmonth[7:4] >= 4'd4 || (rtc_dayofmonth[7:4] == 4'd3 && rtc_dayofmonth[3:0] >= 4'd1))) ||
        (rtc_month == 8'h06 && (rtc_dayofmonth[7:4] >= 4'd4 || (rtc_dayofmonth[7:4] == 4'd3))) ||
        (rtc_month == 8'h07 && (rtc_dayofmonth[7:4] >= 4'd4 || (rtc_dayofmonth[7:4] == 4'd3 && rtc_dayofmonth[3:0] >= 4'd1))) ||
        (rtc_month == 8'h08 && (rtc_dayofmonth[7:4] >= 4'd4 || (rtc_dayofmonth[7:4] == 4'd3 && rtc_dayofmonth[3:0] >= 4'd1))) ||
        (rtc_month == 8'h09 && (rtc_dayofmonth[7:4] >= 4'd4 || (rtc_dayofmonth[7:4] == 4'd3))) ||
        (rtc_month == 8'h10 && (rtc_dayofmonth[7:4] >= 4'd4 || (rtc_dayofmonth[7:4] == 4'd3 && rtc_dayofmonth[3:0] >= 4'd1))) ||
        (rtc_month == 8'h11 && (rtc_dayofmonth[7:4] >= 4'd4 || (rtc_dayofmonth[7:4] == 4'd3))) ||
        (rtc_month >= 8'h12 && (rtc_dayofmonth[7:4] >= 4'd4 || (rtc_dayofmonth[7:4] == 4'd3 && rtc_dayofmonth[3:0] >= 4'd1))))
    );

wire [7:0] next_dayofmonth =
    (max_dayofmonth)?                                       8'd1 :
    (~(crb_binarymode) && rtc_dayofmonth[3:0] >= 4'd9)?     { rtc_dayofmonth[7:4] + 4'd1, 4'd0 } :
                                                            rtc_dayofmonth + 8'd1;

wire max_month =
    (crb_binarymode && rtc_month >= 8'd12) || (~(crb_binarymode) && (rtc_month[7:4] >= 4'd2 || (rtc_month[7:4] == 4'd1 && rtc_month[3:0] >= 4'd2)));

wire [7:0] next_month =
    (max_month)?                                    8'd1 :
    (~(crb_binarymode) && rtc_month[3:0] >= 4'd9)?  { rtc_month[7:4] + 4'd1, 4'd0 } :
                                                    rtc_month + 8'd1;
    
wire max_year =
    (crb_binarymode && rtc_year >= 8'd99) || (~(crb_binarymode) && (rtc_year[7:4] >= 4'd10 || (rtc_year[7:4] == 4'd9 && rtc_year[3:0] >= 4'd9)));

wire [7:0] next_year =
    (max_year)?                                     8'd0 :
    (~(crb_binarymode) && rtc_year[3:0] >= 4'd9)?   { rtc_year[7:4] + 4'd1, 4'd0 } :
                                                    rtc_year + 8'd1;

wire max_century =
    (crb_binarymode && rtc_century >= 8'd99) || (~(crb_binarymode) && (rtc_century[7:4] >= 4'd10 || (rtc_century[7:4] == 4'd9 && rtc_century[3:0] >= 4'd9)));

wire [7:0] next_century =
    (max_century)?                                      8'd0 :
    (~(crb_binarymode) && rtc_century[3:0] >= 4'd9)?    { rtc_century[7:4] + 4'd1, 4'd0 } :
                                                        rtc_century + 8'd1;
    
//------------------------------------------------------------------------------

wire rtc_minute_update = rtc_second_update && max_second;
wire rtc_hour_update   = rtc_minute_update && max_minute;
wire rtc_day_update    = rtc_hour_update   && max_hour;
wire rtc_month_update  = rtc_day_update    && max_dayofmonth;
wire rtc_year_update   = rtc_month_update  && max_month;
wire rtc_century_update= rtc_year_update   && max_year;

//------------------------------------------------------------------------------

reg [7:0] rtc_second;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h00)                             rtc_second <= mgmt_writedata[7:0];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h00)     rtc_second <= io_writedata;
    else if(rtc_second_update)                                          rtc_second <= next_second; 
end

reg [7:0] rtc_minute;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h02)                             rtc_minute <= mgmt_writedata[7:0];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h02)     rtc_minute <= io_writedata;
    else if(rtc_minute_update)                                          rtc_minute <= next_minute;
end

reg [7:0] rtc_hour;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h04)                             rtc_hour <= mgmt_writedata[7:0];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h04)     rtc_hour <= io_writedata;
    else if(rtc_hour_update)                                            rtc_hour <= next_hour;
end

reg [7:0] rtc_dayofweek;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h06)                             rtc_dayofweek <= mgmt_writedata[7:0];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h06)     rtc_dayofweek <= io_writedata;
    else if(rtc_day_update)                                             rtc_dayofweek <= next_dayofweek;
end

reg [7:0] rtc_dayofmonth;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h07)                             rtc_dayofmonth <= mgmt_writedata[7:0];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h07)     rtc_dayofmonth <= io_writedata;
    else if(rtc_day_update)                                             rtc_dayofmonth <= next_dayofmonth;
end

reg [7:0] rtc_month;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h08)                             rtc_month <= mgmt_writedata[7:0];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h08)     rtc_month <= io_writedata;
    else if(rtc_month_update)                                           rtc_month <= next_month;
end

reg [7:0] rtc_year;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h09)                             rtc_year <= mgmt_writedata[7:0];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h09)     rtc_year <= io_writedata;
    else if(rtc_year_update)                                            rtc_year <= next_year;
end

reg [7:0] rtc_century;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h32)                             rtc_century <= mgmt_writedata[7:0];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h32)     rtc_century <= io_writedata;
    else if(io_write && io_address == 1'b1 && ram_address == 7'h37)     rtc_century <= io_writedata;
    else if(rtc_century_update)                                         rtc_century <= next_century;
end

//------------------------------------------------------------------------------

reg [7:0] alarm_second;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h01)                             alarm_second <= mgmt_writedata[7:0];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h01)     alarm_second <= io_writedata;
end

reg [7:0] alarm_minute;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h03)                             alarm_minute <= mgmt_writedata[7:0];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h03)     alarm_minute <= io_writedata;
end

reg [7:0] alarm_hour;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h05)                             alarm_hour <= mgmt_writedata[7:0];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h05)     alarm_hour <= io_writedata;
end

wire alarm_interrupt_activate =
    (alarm_second[7:6] == 2'b11 || (rtc_second_update && next_second == alarm_second)) &&
    (alarm_minute[7:6] == 2'b11 || (rtc_minute_update && next_minute == alarm_minute) || (~(rtc_minute_update) && rtc_minute == alarm_minute)) &&
    (alarm_hour[7:6] == 2'b11   || (rtc_hour_update && next_hour == alarm_hour)       || (~(rtc_hour_update)   && rtc_hour == alarm_hour));

reg alarm_interrupt;
always @(posedge clk) begin
    if(rst_n == 1'b0)                                                   alarm_interrupt <= 1'b0;
    else if(io_read_valid && io_address == 1'b1 && ram_address == 7'h0C)alarm_interrupt <= 1'b0;
    else if(rtc_second_update && alarm_interrupt_activate)              alarm_interrupt <= 1'b1;
end

//------------------------------------------------------------------------------

/*
crb_freeze 1: no update, no alarm
*/

reg crb_freeze;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h0B)                             crb_freeze <= mgmt_writedata[7];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h0B)     crb_freeze <= io_writedata[7];
end

reg crb_int_periodic_ena;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h0B)                             crb_int_periodic_ena <= mgmt_writedata[6];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h0B)     crb_int_periodic_ena <= io_writedata[6];
end

reg crb_int_alarm_ena;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h0B)                             crb_int_alarm_ena <= mgmt_writedata[5];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h0B)     crb_int_alarm_ena <= io_writedata[5];
end

reg crb_int_update_ena;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h0B)                             crb_int_update_ena <= ~(mgmt_writedata[7]) & mgmt_writedata[4];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h0B)     crb_int_update_ena <= ~(io_writedata[7]) & io_writedata[4];
end

reg crb_binarymode;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h0B)                             crb_binarymode <= mgmt_writedata[2];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h0B)     crb_binarymode <= io_writedata[2];
end

reg crb_24hour;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h0B)                             crb_24hour <= mgmt_writedata[1];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h0B)     crb_24hour <= io_writedata[1];
end

reg crb_daylightsaving;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h0B)                             crb_daylightsaving <= mgmt_writedata[0];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h0B)     crb_daylightsaving <= io_writedata[0]; 
end

//------------------------------------------------------------------------------

/*
divider 00x : no periodic
divider 11x : no update, no alarm
*/

reg [2:0] divider;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h0A)                             divider <= mgmt_writedata[6:4];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h0A)     divider <= io_writedata[6:4];
end

reg [3:0] periodic_rate;
always @(posedge clk) begin
    if(mgmt_write && mgmt_address == 8'h0A)                             periodic_rate <= mgmt_writedata[3:0];
    else if(io_write && io_address == 1'b1 && ram_address == 7'h0A)     periodic_rate <= io_writedata[3:0];
end

wire periodic_enabled = divider[2:1] != 2'b00 && periodic_rate != 4'd0;
wire periodic_start   = periodic_enabled && (
                            (ce_8192hz && periodic_major == 13'd0) ||
                            (ce_8192hz && periodic_major == 13'd1));

wire [12:0] periodic_major_initial = {
    periodic_rate == 4'd15, periodic_rate == 4'd14, periodic_rate == 4'd13, periodic_rate == 4'd12,
    periodic_rate == 4'd11, periodic_rate == 4'd10, periodic_rate == 4'd9 || periodic_rate == 4'd2,  periodic_rate == 4'd8 || periodic_rate == 4'd1,  
    periodic_rate == 4'd7,  periodic_rate == 4'd6,  periodic_rate == 4'd5,  periodic_rate == 4'd4,
    periodic_rate == 4'd3 };

reg [12:0] periodic_major;
always @(posedge clk) begin
    if(rst_n == 1'b0)                                         periodic_major <= 13'd0;
    else if(~periodic_enabled)                                periodic_major <= 13'd0;
    else if(periodic_start)                                   periodic_major <= periodic_major_initial;
    else if(periodic_enabled && periodic_major && ce_8192hz) periodic_major <= periodic_major - 13'd1;
end

reg periodic_interrupt;
always @(posedge clk) begin
    if(rst_n == 1'b0)                                                    periodic_interrupt <= 1'b0;
    else if(io_read_valid && io_address == 1'b1 && ram_address == 7'h0C) periodic_interrupt <= 1'b0;
    else if(periodic_enabled && ce_8192hz && periodic_major == 13'd1)    periodic_interrupt <= 1'b1;
end

//------------------------------------------------------------------------------

reg [6:0] ram_address;
always @(posedge clk) begin
    if(rst_n == 1'b0)                       ram_address <= 7'd0;
    else if(io_write && io_address == 1'b0) ram_address <= io_writedata[6:0];
end

//------------------------------------------------------------------------------

wire [7:0] ram_q;

simple_ram #(
    .width      (8),
    .widthad    (7)
)
rtc_ram_inst(
    .clk                (clk),
    
    .wraddress          ((mgmt_write && mgmt_address[7] == 1'b0)?   mgmt_address[6:0] : ram_address),
    .wren               ((mgmt_write && mgmt_address[7] == 1'b0) || (io_write && io_address == 1'b1)),
    .data               ((mgmt_write && mgmt_address[7] == 1'b0)?   mgmt_writedata[7:0] : io_writedata),
    
    .rdaddress          ((io_write && io_address == 1'b0)?  io_writedata[6:0] : ram_address),
    .q                  (ram_q)
);


//------------------------------------------------------------------------------

endmodule
