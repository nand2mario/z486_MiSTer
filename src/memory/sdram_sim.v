// Simulation model for sdram.v
// - 3 ports
// - 32-bit interface on 16-bit SDRAM
// - CL2
// - single or burst read, single write
// - +fast_mem: 1-cycle response (behavioral memory, no SDRAM timing)
module sdram
#(
    parameter         FREQ = 50_000_000, // Dummy parameter for compatibility
    parameter         HAS_DQM = 1'b1,    // Kept for interface compatibility with hardware controller
    parameter         FAST_GRADE = 1'b1  // Kept for interface compatibility with hardware controller
)
(
    // SDRAM side interface (dummy pins for simulation)
    inout      [15:0] SDRAM_DQ,
    output     [12:0] SDRAM_A,
    output     [1:0]  SDRAM_DQM,
    output     [1:0]  SDRAM_BA,
    output            SDRAM_nWE,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,
    output            SDRAM_nCS,
    output            SDRAM_CKE,

    // Logic side interface
    input             clk,
    input             resetn,
    input             nce,
    input             refresh_allowed,
    output            busy,
    input       [1:0] sdram_size,

    // Port 0 - higher priority (valid/ready handshake)
    input             valid0,       // request valid (held until ready)
    output            ready0,       // 1-cycle pulse: request accepted
    input             wr0,          // 1: write, 0: read
    input      [26:0] addr0,        // byte address
    input      [31:0] din0,         // data input
    output reg [31:0] dout0,        // data output
    input       [3:0] be0,          // byte enable
    output reg        resp_valid0,  // read data ready
    input       [3:0] burst_cnt0,   // burst count for reads (max 15 - 60 bytes)
    output reg        burst_done0,  // burst done signal

    // Port 1
    input             valid1,
    output            ready1,
    input             wr1,
    input      [26:0] addr1,
    input      [31:0] din1,
    output reg [31:0] dout1,
    input       [3:0] be1,
    output reg        resp_valid1,
    input       [3:0] burst_cnt1,
    output reg        burst_done1,

    // Port 2
    input             valid2,
    output            ready2,
    input             wr2,
    input      [26:0] addr2,
    input      [31:0] din2,
    output reg [31:0] dout2,
    input       [3:0] be2,
    output reg        resp_valid2,
    input       [3:0] burst_cnt2,
    output reg        burst_done2
);

// Expose for Verilator C++ testbench via hierarchy access
reg [15:0] mem [0:64*1024*1024-1] /* verilator public_flat_rw */ ;  // 128MB maximum

// Real SDRAM has undefined contents after power-up. Keep the normal zeroed
// simulation behavior for reproducible tests, but allow software to be checked
// against a board-like 16MB random power-up image.
initial if ($test$plusargs("random_sdram")) begin
    for (integer i = 0; i < 8*1024*1024; i = i + 1)
        mem[i] = $urandom;
end

// Fast simulation mode: 1-cycle response, no SDRAM timing
reg fast_mem;
initial fast_mem = $test$plusargs("fast_mem");

reg [2:0] cycle;
reg busy_buf = 1;
assign busy = fast_mem ? 1'b0 : busy_buf;

reg [3:0] start_cnt = 15;
reg [3:0] burst_cnt;

reg [2:0] state;
reg [1:0] port;
localparam IDLE = 0;
localparam RAS = 1;
localparam CAS0 = 2;
localparam CAS1 = 3;

reg [26:1] addr;
reg [31:0] din;
reg wr;
reg [3:0] be;
reg hi;

wire [15:0] din16 = hi ? din[31:16] : din[15:0];

// Accepted pulse registers
reg [2:0] ready_pulse;
assign ready0 = ready_pulse[0];
assign ready1 = ready_pulse[1];
assign ready2 = ready_pulse[2];

// Fast-mode burst state: one active burst at a time
reg        fast_burst_active = 0;
reg [26:0] fast_burst_addr;
reg [3:0]  fast_burst_rem;   // remaining DWORDs (including current)
reg [1:0]  fast_burst_port;

// Fast-mode helper: start a read (burst or single)
task fast_read(input [26:0] a, input [3:0] bcnt, input [1:0] p);
begin
    if (p == 0) begin
        dout0 <= {mem[{a[26:2],1'b1}], mem[{a[26:2],1'b0}]};
        resp_valid0 <= 1;
        burst_done0 <= (bcnt <= 1);
    end else if (p == 1) begin
        dout1 <= {mem[{a[26:2],1'b1}], mem[{a[26:2],1'b0}]};
        resp_valid1 <= 1;
        burst_done1 <= (bcnt <= 1);
    end else begin
        dout2 <= {mem[{a[26:2],1'b1}], mem[{a[26:2],1'b0}]};
        resp_valid2 <= 1;
        burst_done2 <= (bcnt <= 1);
    end
    ready_pulse[p] <= 1;
    if (bcnt > 1) begin
        fast_burst_active <= 1;
        fast_burst_addr <= a + 4;  // next DWORD (byte address +4)
        fast_burst_rem <= bcnt - 1;
        fast_burst_port <= p;
    end
end
endtask

task fast_write(input [26:0] a, input [31:0] d, input [3:0] b, input [1:0] p);
begin
    if (b[0]) mem[{a[26:2],1'b0}][7:0]  <= d[7:0];
    if (b[1]) mem[{a[26:2],1'b0}][15:8] <= d[15:8];
    if (b[2]) mem[{a[26:2],1'b1}][7:0]  <= d[23:16];
    if (b[3]) mem[{a[26:2],1'b1}][15:8] <= d[31:24];
    // Debug: trace writes to BIOS code area 0xF6480-0xF649F
    if ({a[26:2],1'b0} >= 26'h07B240 && {a[26:2],1'b0} <= 26'h07B24F)
        $display("%0t: SDRAM FAST_WRITE addr=0x%06X data=0x%08X be=%04b port=%0d",
                 $time, {a[26:2],2'b00}, d, b, p);
    ready_pulse[p] <= 1;
end
endtask

always @(posedge clk) begin
    start_cnt <= start_cnt == 0 ? 0 : start_cnt - 1;
    if (start_cnt == 1)
        busy_buf <= 0;

    resp_valid0 <= 0; resp_valid1 <= 0; resp_valid2 <= 0;
    burst_done0 <= 0; burst_done1 <= 0; burst_done2 <= 0;
    ready_pulse <= 3'b000;

    if (fast_mem) begin
        // ---- Fast mode: 1-cycle response, service all ports in parallel ----
        // Continue active burst first (1 DWORD per cycle)
        if (fast_burst_active) begin
            if (fast_burst_port == 0) begin
                dout0 <= {mem[{fast_burst_addr[26:2],1'b1}], mem[{fast_burst_addr[26:2],1'b0}]};
                resp_valid0 <= 1;
                burst_done0 <= (fast_burst_rem <= 1);
            end else if (fast_burst_port == 1) begin
                dout1 <= {mem[{fast_burst_addr[26:2],1'b1}], mem[{fast_burst_addr[26:2],1'b0}]};
                resp_valid1 <= 1;
                burst_done1 <= (fast_burst_rem <= 1);
            end else begin
                dout2 <= {mem[{fast_burst_addr[26:2],1'b1}], mem[{fast_burst_addr[26:2],1'b0}]};
                resp_valid2 <= 1;
                burst_done2 <= (fast_burst_rem <= 1);
            end
            fast_burst_addr <= fast_burst_addr + 4;
            fast_burst_rem <= fast_burst_rem - 1;
            if (fast_burst_rem <= 1)
                fast_burst_active <= 0;
        end
        // New requests (only when no burst in progress)
        if (!fast_burst_active) begin
            if (valid0) begin
                if (wr0) fast_write(addr0, din0, be0, 2'd0);
                else     fast_read(addr0, burst_cnt0, 2'd0);
            end
            if (valid1) begin
                if (wr1) fast_write(addr1, din1, be1, 2'd1);
                else     fast_read(addr1, burst_cnt1, 2'd1);
            end
            if (valid2) begin
                if (wr2) fast_write(addr2, din2, be2, 2'd2);
                else     fast_read(addr2, burst_cnt2, 2'd2);
            end
        end
    end else begin
    // ---- Normal mode: SDRAM timing simulation ----
    case (state)
    IDLE: begin
        if (valid0) begin
            addr <= {addr0[26:2],1'b0};  // convert to 16-bit word address
            din <= din0;
            wr <= wr0;
            be <= be0;
            burst_cnt <= burst_cnt0;
            port <= 0;
            busy_buf <= 1;
            ready_pulse[0] <= 1;
            state <= RAS;
        end else if (valid1) begin
            addr <= {addr1[26:2],1'b0};
            din <= din1;
            wr <= wr1;
            be <= be1;
            burst_cnt <= burst_cnt1;
            port <= 1;
            busy_buf <= 1;
            ready_pulse[1] <= 1;
            state <= RAS;
        end else if (valid2) begin
            addr <= {addr2[26:2],1'b0};
            din <= din2;
            wr <= wr2;
            be <= be2;
            port <= 2;
            busy_buf <= 1;
            ready_pulse[2] <= 1;
            state <= RAS;
        end
    end

    RAS: state <= CAS0;

    CAS0: begin          // leading wait cycle
        hi <= 0;         // start from lower 16-bit
        state <= CAS1;
    end

    CAS1: begin          // process one 16-bit word per cycle
        if (wr) begin
            if (be[{hi,1'b0}]) begin
                mem[addr][7:0] <= din16[7:0];
            end
            if (be[{hi,1'b1}]) begin
                mem[addr][15:8] <= din16[15:8];
            end
            // Debug: trace writes to BIOS code area 0xF6480-0xF649F
            // (16-bit word addresses 0x7B240-0x7B24F)
            if (addr >= 24'h07B240 && addr <= 24'h07B24F)
                $display("%0t: SDRAM WRITE addr=0x%06X data=0x%04X be=%b hi=%b port=%0d",
                         $time, addr, din16, be, hi, port);
        end else begin
            if (port == 0) begin
                if (hi) dout0[31:16] <= mem[addr];
                else    dout0[15:0] <= mem[addr];
                if (hi) resp_valid0 <= 1;
                if (hi && burst_cnt <= 1) burst_done0 <= 1;
            end else if (port == 1) begin
                if (hi) dout1[31:16] <= mem[addr];
                else    dout1[15:0] <= mem[addr];
                if (hi) resp_valid1 <= 1;
                if (hi && burst_cnt <= 1) burst_done1 <= 1;
            end else begin
                if (hi) dout2[31:16] <= mem[addr];
                else    dout2[15:0] <= mem[addr];
                if (hi) resp_valid2 <= 1;
                if (hi && burst_cnt <= 1) burst_done2 <= 1;
            end
        end
        addr <= addr + 1;
        if (hi) begin
            if (burst_cnt <= 1 || wr) begin  // all done
                state <= IDLE;
                busy_buf <= 0;
            end
            burst_cnt <= burst_cnt - 1;
        end
        hi <= ~hi;
    end

    default: ;
    endcase
    end // !fast_mem
end

endmodule
