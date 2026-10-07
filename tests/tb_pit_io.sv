`timescale 1ns/1ps

module tb_pit_io;
    reg clk = 1'b0;
    reg reset_n = 1'b0;
    always #5 clk = ~clk;

    reg [31:2] cpu_addr;
    reg [3:0] cpu_be;
    reg [31:0] cpu_din;
    wire [31:0] cpu_dout;
    reg cpu_io_rd;
    reg cpu_io_wr;
    wire cpu_io_ready;

    wire [15:0] io_address;
    wire io_read;
    wire io_write;
    wire [7:0] io_writedata;
    wire [7:0] pit_readdata;

    iobus_adapter adapter (
        .clk(clk),
        .reset_n(reset_n),
        .cpu_addr(cpu_addr),
        .cpu_be(cpu_be),
        .cpu_din(cpu_din),
        .cpu_dout(cpu_dout),
        .cpu_io_rd(cpu_io_rd),
        .cpu_io_wr(cpu_io_wr),
        .cpu_io_ready(cpu_io_ready),
        .io_address(io_address),
        .io_read(io_read),
        .io_write(io_write),
        .io_writedata(io_writedata),
        .io_readdata(pit_readdata),
        .ide_address(),
        .ide_read(),
        .ide_write(),
        .ide_writedata(),
        .ide_readdata(32'h0),
        .ide_32(),
        .ide_hold(1'b0),
        .direct_readdata(8'hff),
        .direct_handled(1'b0)
    );

    wire pit_cs = ({io_address[15:2], 2'b00} == 16'h0040) ||
                  (io_address == 16'h0061);

    pit dut (
        .clk(clk),
        .rst_n(reset_n),
        .irq(),
        .io_address({io_address[5], io_address[1:0]}),
        .io_read(io_read && pit_cs),
        .io_readdata(pit_readdata),
        .io_write(io_write && pit_cs),
        .io_writedata(io_writedata),
        .speaker_out(),
        .clock_rate(28'd85000000)
    );

    task automatic io_write8(input [15:0] port, input [7:0] value);
        begin
            @(negedge clk);
            cpu_addr = port[15:2];
            cpu_be = 4'b0001 << port[1:0];
            cpu_din = {4{value}};
            cpu_io_wr = 1'b1;
            do @(posedge clk); while (!cpu_io_ready);
            @(negedge clk);
            cpu_io_wr = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic io_read8(input [15:0] port, output [7:0] value);
        begin
            @(negedge clk);
            cpu_addr = port[15:2];
            cpu_be = 4'b0001 << port[1:0];
            cpu_io_rd = 1'b1;
            do @(posedge clk); while (!cpu_io_ready);
            value = cpu_dout >> (port[1:0] * 8);
            @(negedge clk);
            cpu_io_rd = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    reg [7:0] count_l;
    reg [7:0] count_h;
    initial begin
        cpu_addr = 0;
        cpu_be = 0;
        cpu_din = 0;
        cpu_io_rd = 0;
        cpu_io_wr = 0;
        repeat (4) @(posedge clk);
        reset_n = 1'b1;

        // Channel 0, LSB/MSB, mode 2, binary; reload 0x4000.
        io_write8(16'h0043, 8'h34);
        io_write8(16'h0040, 8'h00);
        io_write8(16'h0040, 8'h40);
        repeat (1000) @(posedge clk);

        // Latch and read one coherent 16-bit count.
        io_write8(16'h0043, 8'h00);
        io_read8(16'h0040, count_l);
        io_read8(16'h0040, count_h);
        $display("PIT latched count read: %02x%02x", count_h, count_l);
        if ({count_h, count_l} < 16'h3fe0 || {count_h, count_l} > 16'h3fff)
            $fatal(1, "PIT count bytes are stale or incoherent");
        $finish;
    end
endmodule
