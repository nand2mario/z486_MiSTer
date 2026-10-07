`timescale 1ns/1ps

module tb_iobus_adapter;
    reg clk = 1'b0;
    reg reset_n = 1'b0;
    always #5 clk = ~clk;

    reg [31:2] cpu_addr = '0;
    reg [3:0] cpu_be = '0;
    reg [31:0] cpu_din = '0;
    wire [31:0] cpu_dout;
    reg cpu_io_rd = 1'b0;
    reg cpu_io_wr = 1'b0;
    wire cpu_io_ready;
    wire [15:0] io_address;
    wire io_read;
    wire io_write;
    wire [7:0] io_writedata;

    iobus_adapter dut (
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
        .io_readdata(8'hff),
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

    integer write_count = 0;
    reg previous_write = 1'b0;
    always @(posedge clk) begin
        if (io_write) begin
            if (previous_write)
                $fatal(1, "adjacent bytes were merged into one io_write level");
            case (write_count)
                0: if (io_address != 16'h0388 || io_writedata != 8'haa)
                       $fatal(1, "first byte mismatch: %04x=%02x", io_address, io_writedata);
                1: if (io_address != 16'h0389 || io_writedata != 8'h55)
                       $fatal(1, "second byte mismatch: %04x=%02x", io_address, io_writedata);
                default: $fatal(1, "unexpected extra write pulse");
            endcase
            write_count <= write_count + 1;
        end
        previous_write <= io_write;
    end

    initial begin
        repeat (4) @(posedge clk);
        reset_n = 1'b1;

        @(negedge clk);
        cpu_addr = 16'h0388 >> 2;
        cpu_be = 4'b0011;
        cpu_din = 32'h0000_55aa;
        cpu_io_wr = 1'b1;
        do @(posedge clk); while (!cpu_io_ready);
        @(negedge clk);
        cpu_io_wr = 1'b0;
        repeat (3) @(posedge clk);

        if (write_count != 2)
            $fatal(1, "expected two byte-write pulses, got %0d", write_count);
        $display("iobus_adapter wide-write pulse test passed");
        $finish;
    end
endmodule
