// SPDX-License-Identifier: GPL-2.0-or-later
// Shares a MiSTer DDRAM_* port between a core's own master (A, with bursts)
// and the network bridge (B, single words).
//
// The port changes hands only between transactions: no read words outstanding
// and no write burst half done. While B wants the port, A sees busy for new
// requests (B moves a word now and then, so A loses little); while A owns it,
// B waits. Both sides must hold a request until they see busy low, as on the
// DDRAM interface itself. All signals are in the DDRAM clock domain.
module netbridge_ddram_arb (
    input  logic        clk,
    input  logic        reset,

    // A: the core's own DDR master
    input  logic [28:0] a_addr,
    input  logic  [7:0] a_burstcnt,
    input  logic        a_rd,
    input  logic        a_we,
    input  logic [63:0] a_din,
    input  logic  [7:0] a_be,
    output logic        a_busy,
    output logic        a_dout_ready,

    // B: the bridge
    input  logic [28:0] b_addr,
    input  logic        b_rd,
    input  logic        b_we,
    input  logic [63:0] b_din,
    input  logic  [7:0] b_be,
    output logic        b_busy,
    output logic        b_dout_ready,

    // to DDRAM_* (DDRAM_DOUT goes to both masters directly)
    output logic [28:0] ddr_addr,
    output logic  [7:0] ddr_burstcnt,
    output logic        ddr_rd,
    output logic        ddr_we,
    output logic [63:0] ddr_din,
    output logic  [7:0] ddr_be,
    input  logic        ddr_busy,
    input  logic        ddr_dout_ready
);

logic       own_b;
logic [8:0] rd_left;               // read words still to come for the owner
logic [7:0] wr_left;               // write beats still to come in a burst

wire a_req   = a_rd | a_we;
wire b_req   = b_rd | b_we;
wire quiet   = rd_left == 9'd0 && wr_left == 8'd0;
wire a_block = !own_b && b_req && wr_left == 8'd0;    // B waiting: A starts nothing new

wire       cur_rd = own_b ? b_rd : (a_rd && !a_block);
wire       cur_we = own_b ? b_we : (a_we && !a_block);
wire [7:0] cur_bc = own_b ? 8'd1 : a_burstcnt;
wire       acc_rd = cur_rd && !ddr_busy;
wire       acc_we = cur_we && !ddr_busy;

assign ddr_addr     = own_b ? b_addr : a_addr;
assign ddr_burstcnt = cur_bc;
assign ddr_rd       = cur_rd;
assign ddr_we       = cur_we;
assign ddr_din      = own_b ? b_din : a_din;
assign ddr_be       = own_b ? b_be  : a_be;

assign a_busy       = ddr_busy | own_b | a_block;
assign b_busy       = ddr_busy | !own_b;
assign a_dout_ready = ddr_dout_ready & !own_b;
assign b_dout_ready = ddr_dout_ready &  own_b;

always_ff @(posedge clk) begin
    if (reset) begin
        own_b <= 1'b0; rd_left <= 9'd0; wr_left <= 8'd0;
    end
    else begin
        rd_left <= rd_left + (acc_rd ? {1'b0, cur_bc} : 9'd0) - (ddr_dout_ready ? 9'd1 : 9'd0);
        if (acc_we) wr_left <= (wr_left == 8'd0) ? cur_bc - 8'd1 : wr_left - 8'd1;
        if (quiet && !acc_rd && !acc_we) begin
            if (!own_b && b_req) own_b <= 1'b1;
            else if (own_b && !b_req && a_req) own_b <= 1'b0;
        end
    end
end

endmodule
