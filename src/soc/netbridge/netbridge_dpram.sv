// SPDX-License-Identifier: GPL-2.0-or-later
// Dual-port 8-bit RAM, one clock, registered outputs (infers block RAM).
module netbridge_dpram #(parameter AW = 13) (
    input  logic          clk,
    input  logic          we_a,
    input  logic [AW-1:0] addr_a,
    input  logic    [7:0] d_a,
    output logic    [7:0] q_a,
    input  logic          we_b,
    input  logic [AW-1:0] addr_b,
    input  logic    [7:0] d_b,
    output logic    [7:0] q_b
);
logic [7:0] mem [0:(1 << AW) - 1];
always_ff @(posedge clk) begin
    if (we_a) begin mem[addr_a] <= d_a; q_a <= d_a; end
    else q_a <= mem[addr_a];
end
always_ff @(posedge clk) begin
    if (we_b) begin mem[addr_b] <= d_b; q_b <= d_b; end
    else q_b <= mem[addr_b];
end
endmodule
