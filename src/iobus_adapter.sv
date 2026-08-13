// IO Bus Adapter: z486 IO bus to byte-sequential peripheral IO bus
//
// z486 IO cycles can be 1-4 bytes (indicated by be[3:0]).
// ao486 peripherals are 8-bit (except the IDE data ports 0x1F0/0x170, 32-bit).
// This FSM iterates through active byte enables, issues sequential peripheral
// reads/writes, assembles/distributes data, then asserts ready.
//
// Peripheral read data has 1-cycle registered latency: after asserting io_read,
// the peripheral registers io_readdata on the NEXT edge (via NBA), which means
// the adapter can read the updated io_readdata on the edge AFTER that.
// Sequence: ISSUE (assert io_read) → WAIT (peripheral registers data) → CAPTURE
//
`timescale 1ns/1ns

module iobus_adapter (
    input              clk,
    input              reset_n,

    // z486 IO bus interface (directly from CPU)
    input      [31:2]  cpu_addr,
    input       [3:0]  cpu_be,
    input      [31:0]  cpu_din,    // data from CPU (for writes)
    output reg [31:0]  cpu_dout,   // data to CPU (for reads)
    input              cpu_io_rd,
    input              cpu_io_wr,
    output reg         cpu_io_ready,

    // Peripheral IO bus (directly drives all peripherals; muxed externally)
    output reg [15:0]  io_address,
    output reg         io_read,
    output reg         io_write,
    output reg  [7:0]  io_writedata,
    input       [7:0]  io_readdata,

    // IDE 32-bit interface (directly drives IDE module)
    output reg  [3:0]  ide_address,
    output reg         ide_read,
    output reg         ide_write,
    output reg [31:0]  ide_writedata,
    input      [31:0]  ide_readdata,
    output reg         ide_32,

    // (direct_handled removed - all ports go through byte FSM for simplicity)
    input       [7:0]  direct_readdata,   // unused, kept for port compatibility
    input              direct_handled     // unused, kept for port compatibility
);

// FSM: for each byte, reads take 3 cycles (ISSUE → WAIT → CAPTURE),
// writes take an ISSUE cycle followed by a low-strobe gap.  The gap keeps
// adjacent bytes as distinct peripheral transactions; some devices detect
// writes by edge rather than by sampling every cycle that io_write is high.
// Inactive bytes are skipped.
//
// States encode byte index (0-3) and phase:
//   ISSUE: assert io_read/io_write with address and data
//   WAIT:  peripheral registers the response (io_read deasserted by default)
//   CAP:   capture io_readdata into read_accum

localparam S_IDLE     = 5'd0;
localparam S_ISSUE0   = 5'd1;
localparam S_WAIT0    = 5'd2;
localparam S_CAP0     = 5'd3;
localparam S_ISSUE1   = 5'd4;
localparam S_WAIT1    = 5'd5;
localparam S_CAP1     = 5'd6;
localparam S_ISSUE2   = 5'd7;
localparam S_WAIT2    = 5'd8;
localparam S_CAP2     = 5'd9;
localparam S_ISSUE3   = 5'd10;
localparam S_WAIT3    = 5'd11;
localparam S_CAP3     = 5'd12;
localparam S_DONE     = 5'd13;
localparam S_IDE32    = 5'd14;
localparam S_IDE32W   = 5'd15;

reg [4:0] state;
reg [31:0] byte_addr;    // base byte address
reg [3:0]  active_be;    // byte enables to process
reg        is_read;      // 1=read, 0=write
reg [31:0] write_data;   // captured write data
reg [31:0] read_accum;   // accumulated read data
reg        was_active;   // Guard: prevent re-triggering until CPU deasserts IO signals

// Combinational: port address
wire [15:0] base_port = {cpu_addr, 2'b00};

// IDE data port detection: primary 0x1F0 or secondary 0x170 (CD-ROM/ATAPI),
// only when byte lane 0 is active. The secondary data port must take the wide
// (16/32-bit) IDE path too, otherwise INSW/OUTSW on 0x170 would fall into the
// byte FSM and read 0x170 then 0x171 (data low + error reg) -> garbage.
wire ide_data_port = ((base_port == 16'h01F0) || (base_port == 16'h0170)) && cpu_be[0];

always @(posedge clk) begin
    if (!reset_n) begin
        state <= S_IDLE;
        cpu_io_ready <= 1'b0;
        io_read <= 1'b0;
        io_write <= 1'b0;
        ide_read <= 1'b0;
        ide_write <= 1'b0;
        was_active <= 1'b0;
    end else begin
        // Deassert strobes by default
        io_read <= 1'b0;
        io_write <= 1'b0;
        ide_read <= 1'b0;
        ide_write <= 1'b0;
        cpu_io_ready <= 1'b0;

        case (state)
            S_IDLE: begin
                if (was_active && (cpu_io_rd || cpu_io_wr))
                    was_active <= 1'b1;
                else if (was_active)
                    was_active <= 1'b0;
                else if (cpu_io_rd || cpu_io_wr) begin
                    byte_addr <= {16'h0, base_port};
                    active_be <= cpu_be;
                    is_read <= cpu_io_rd;
                    write_data <= cpu_din;
                    read_accum <= 32'hFFFFFFFF;
                    io_address <= base_port;

                    if (ide_data_port) begin
                        ide_address <= 4'd0;
                        ide_32 <= (cpu_be == 4'b1111);
                        if (cpu_io_rd)
                            ide_read <= 1'b1;
                        else begin
                            ide_write <= 1'b1;
                            ide_writedata <= cpu_din;
                        end
                        state <= S_IDE32;
                    end else begin
                        state <= S_ISSUE0;
                    end
                end
            end

            // ================================================================
            // Byte 0
            // ================================================================
            S_ISSUE0: begin
                if (active_be[0]) begin
                    io_address <= byte_addr[15:0];
                    if (is_read)
                        io_read <= 1'b1;
                    else begin
                        io_write <= 1'b1;
                        io_writedata <= write_data[7:0];
                    end
                end
                if (active_be[0])
                    state <= S_WAIT0;
                else
                    state <= S_ISSUE1;
            end

            S_WAIT0: state <= is_read ? S_CAP0 : S_ISSUE1;

            S_CAP0: begin
                read_accum[7:0] <= io_readdata;
                state <= S_ISSUE1;
            end

            // ================================================================
            // Byte 1
            // ================================================================
            S_ISSUE1: begin
                if (active_be[1]) begin
                    io_address <= byte_addr[15:0] + 16'd1;
                    if (is_read)
                        io_read <= 1'b1;
                    else begin
                        io_write <= 1'b1;
                        io_writedata <= write_data[15:8];
                    end
                end
                if (active_be[1])
                    state <= S_WAIT1;
                else
                    state <= S_ISSUE2;
            end

            S_WAIT1: state <= is_read ? S_CAP1 : S_ISSUE2;

            S_CAP1: begin
                read_accum[15:8] <= io_readdata;
                state <= S_ISSUE2;
            end

            // ================================================================
            // Byte 2
            // ================================================================
            S_ISSUE2: begin
                if (active_be[2]) begin
                    io_address <= byte_addr[15:0] + 16'd2;
                    if (is_read)
                        io_read <= 1'b1;
                    else begin
                        io_write <= 1'b1;
                        io_writedata <= write_data[23:16];
                    end
                end
                if (active_be[2])
                    state <= S_WAIT2;
                else
                    state <= S_ISSUE3;
            end

            S_WAIT2: state <= is_read ? S_CAP2 : S_ISSUE3;

            S_CAP2: begin
                read_accum[23:16] <= io_readdata;
                state <= S_ISSUE3;
            end

            // ================================================================
            // Byte 3
            // ================================================================
            S_ISSUE3: begin
                if (active_be[3]) begin
                    io_address <= byte_addr[15:0] + 16'd3;
                    if (is_read)
                        io_read <= 1'b1;
                    else begin
                        io_write <= 1'b1;
                        io_writedata <= write_data[31:24];
                    end
                end
                if (active_be[3])
                    state <= S_WAIT3;
                else
                    state <= S_DONE;
            end

            S_WAIT3: state <= is_read ? S_CAP3 : S_DONE;

            S_CAP3: begin
                read_accum[31:24] <= io_readdata;
                state <= S_DONE;
            end

            // ================================================================
            // Done: return result to CPU
            // ================================================================
            S_DONE: begin
                cpu_dout <= read_accum;
                cpu_io_ready <= 1'b1;
                was_active <= 1'b1;
                state <= S_IDLE;
            end

            // ================================================================
            // IDE 32-bit: wait for registered readdata
            // ide_read asserted at S_IDLE. IDE registers readdata at edge+1.
            // At edge+2 (S_IDE32W), ide_readdata has the valid value.
            // ================================================================
            S_IDE32:    state <= S_IDE32W;
            S_IDE32W: begin
                if (is_read)
                    cpu_dout <= ide_readdata;
                cpu_io_ready <= 1'b1;
                was_active <= 1'b1;
                state <= S_IDLE;
            end
        endcase
    end
end

endmodule
