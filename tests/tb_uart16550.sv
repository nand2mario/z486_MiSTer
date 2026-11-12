`timescale 1ns/1ps

module tb_uart16550;
    localparam int CLK_HZ = 85_000_000;

    logic clk = 0;
    always #5.882 clk = ~clk;

    logic reset = 1;
    logic [31:0] uart_speed = 32'd115200;
    logic [2:0] io_address = 0;
    logic io_read = 0, io_write = 0, io_cs = 1;
    logic [7:0] io_writedata = 0;
    wire [7:0] io_readdata;
    wire irq, tx, rts_n, dtr_n;
    logic rx = 1, cts_n = 1, dsr_n = 1, dcd_n = 1, ri_n = 1;
    integer failures = 0;

    uart16550 #(.CLK_HZ(CLK_HZ)) dut (.*);

    task automatic check(input string name, input logic [31:0] got, input logic [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got %h want %h", name, got, want);
            failures++;
        end
    endtask

    task automatic wr(input logic [2:0] a, input logic [7:0] d);
        @(negedge clk);
        io_address = a;
        io_writedata = d;
        io_write = 1;
        @(negedge clk);
        io_write = 0;
    endtask

    task automatic rd(input logic [2:0] a, output logic [7:0] d);
        @(negedge clk);
        io_address = a;
        io_read = 1;
        @(negedge clk);
        io_read = 0;
        d = io_readdata;
    endtask

    task automatic expect_reg(input string name, input logic [2:0] a, input logic [7:0] want);
        logic [7:0] d;
        rd(a, d);
        check(name, d, want);
    endtask

    task automatic set_divisor(input logic [15:0] d, input logic [7:0] format);
        wr(3, 8'h80);
        wr(0, d[7:0]);
        wr(1, d[15:8]);
        wr(3, format);
    endtask

    task automatic wait_lsr(input logic [7:0] mask);
        logic [7:0] d;
        integer n = 0;
        do begin
            rd(5, d);
            n++;
            if (n > 2000000) begin
                $display("FAIL timeout waiting for LSR mask %h", mask);
                $finish(1);
            end
        end while ((d & mask) != mask);
    endtask

    // Drive one 8N1-style frame on the external RX pin.
    task automatic send_bits(input logic [11:0] bits, input integer count, input real bit_ns);
        for (int i = 0; i < count; i++) begin
            rx = bits[i];
            #(bit_ns);
        end
        rx = 1;
    endtask

    logic [7:0] d;
    real t0, t1;
    real bit_ns;

    initial begin
        repeat (8) @(negedge clk);
        reset = 0;

        // Reset state and detection registers.
        expect_reg("IIR reset", 2, 8'h01);
        expect_reg("LSR reset", 5, 8'h60);
        wr(7, 8'h5a);
        expect_reg("SCR", 7, 8'h5a);
        set_divisor(16'h0102, 8'h03);
        wr(3, 8'h83);
        expect_reg("DLL", 0, 8'h02);
        expect_reg("DLM", 1, 8'h01);
        expect_reg("LCR", 3, 8'h83);
        wr(3, 8'h03);

        // BIOS and driver detection use modem loopback.
        wr(4, 8'h1a);
        rd(6, d);
        check("loop CTS/DCD", d[7:4], 4'h9);
        wr(4, 8'h15);
        rd(6, d);
        check("loop DSR/RI", d[7:4], 4'h6);
        wr(4, 8'h10);

        // Character loopback at 57600 baud; the external pin stays marking.
        set_divisor(16'd2, 8'h03);
        wr(4, 8'h10);
        wr(0, 8'ha5);
        wait_lsr(8'h01);
        expect_reg("loop RBR", 0, 8'ha5);
        check("TX pin idle in loopback", tx, 1'b1);

        // FCR identifies a 16550A; trigger level 4 raises IRQ4 only with OUT2.
        wr(2, 8'h47);
        rd(2, d);
        check("IIR FIFO id", d[7:6], 2'b11);
        wr(1, 8'h01);
        wr(4, 8'h10);
        for (int i = 0; i < 4; i++) wr(0, 8'h30 + 8'(i));
        wait_lsr(8'h40);
        check("OUT2 gates IRQ", irq, 1'b0);
        wr(4, 8'h18);
        @(negedge clk);
        check("RX trigger IRQ", irq, 1'b1);
        rd(2, d);
        check("IIR RX data", d, 8'hc4);
        for (int i = 0; i < 4; i++) expect_reg("FIFO order", 0, 8'h30 + 8'(i));
        @(negedge clk);
        check("IRQ clears", irq, 1'b0);

        // Fewer bytes than the trigger level use the character timeout.
        wr(0, 8'h77);
        wait_lsr(8'h41);
        repeat (70000) @(negedge clk);
        check("timeout IRQ", irq, 1'b1);
        rd(2, d);
        check("IIR timeout", d, 8'hcc);
        expect_reg("timeout data", 0, 8'h77);
        @(negedge clk);
        check("timeout clears", irq, 1'b0);

        // THRE interrupt: raised on enable, cleared by IIR.
        wr(1, 8'h02);
        @(negedge clk);
        check("THRE IRQ", irq, 1'b1);
        rd(2, d);
        check("IIR THRE", d, 8'hc2);
        @(negedge clk);
        check("THRE clears", irq, 1'b0);
        wr(1, 8'h00);
        wr(4, 8'h00);

        // TX frame timing and format on the pin: 115200 8E1, 'U' (even parity 0).
        wr(2, 8'h07);
        set_divisor(16'd1, 8'h1b);
        wr(0, 8'h55);
        @(negedge tx);
        t0 = $realtime;
        for (int i = 0; i < 8; i++) begin
            #(1e9 / 115200.0 * (i == 0 ? 1.5 : 1.0));
            check("TX data bit", tx, 1'((8'h55 >> i) & 1));
        end
        #(1e9 / 115200.0);
        check("TX parity", tx, 1'b0);
        #(1e9 / 115200.0);
        check("TX stop", tx, 1'b1);
        wait_lsr(8'h40);

        // External RX with good parity, then a parity error.
        bit_ns = 1e9 / 115200.0;
        send_bits({1'b1, 1'b0, 8'h55, 1'b0}, 11, bit_ns);
        #(bit_ns);
        send_bits({1'b1, 1'b1, 8'h55, 1'b0}, 11, bit_ns);
        #(bit_ns * 2);
        rd(5, d);
        check("first byte clean", d[4:1], 4'd0);
        check("FIFO error flag", d[7], 1'b1);
        expect_reg("RX byte", 0, 8'h55);
        rd(5, d);
        check("parity error", d[2], 1'b1);
        expect_reg("RX byte 2", 0, 8'h55);
        rd(5, d);
        check("parity cleared", d[2], 1'b0);

        // Framing error and break are reported, and the receiver recovers.
        wr(3, 8'h03);
        send_bits({1'b0, 8'h41, 1'b0}, 10, bit_ns);
        #(bit_ns * 2);
        rd(5, d);
        check("framing error", d[3], 1'b1);
        expect_reg("framed byte", 0, 8'h41);
        rx = 0;
        #(bit_ns * 12);
        rx = 1;
        #(bit_ns * 2);
        rd(5, d);
        check("break", d[4], 1'b1);
        expect_reg("break byte", 0, 8'h00);

        // Overrun after 16 bytes; the FIFO contents survive.
        for (int i = 0; i < 17; i++) begin
            send_bits({1'b1, 8'(i), 1'b0}, 10, bit_ns);
            #(bit_ns);
        end
        rd(5, d);
        check("overrun", d[1], 1'b1);
        for (int i = 0; i < 16; i++) expect_reg("full FIFO", 0, 8'(i));

        // 16450 mode: overwriting the holding register keeps only the last byte.
        wr(2, 8'h00);
        send_bits({1'b1, 8'h11, 1'b0}, 10, bit_ns);
        #(bit_ns);
        send_bits({1'b1, 8'h22, 1'b0}, 10, bit_ns);
        #(bit_ns);
        rd(5, d);
        check("16450 overrun", d[1], 1'b1);
        expect_reg("16450 RBR", 0, 8'h22);

        // Modem inputs and outputs.
        wr(4, 8'h03);
        check("RTS pin", rts_n, 1'b0);
        check("DTR pin", dtr_n, 1'b0);
        rd(6, d);
        cts_n = 0;
        dcd_n = 0;
        repeat (4) @(negedge clk);
        rd(6, d);
        check("MSR", d, 8'h99);
        rd(6, d);
        check("MSR delta clear", d, 8'h90);
        wr(1, 8'h08);
        wr(4, 8'h0b);
        cts_n = 1;
        repeat (4) @(negedge clk);
        check("modem IRQ", irq, 1'b1);
        expect_reg("IIR modem", 2, 8'h00);
        rd(6, d);
        @(negedge clk);
        check("modem IRQ clear", irq, 1'b0);
        wr(1, 8'h00);
        wr(4, 8'h00);

        // Turbo: divisor 1 follows a 4 Mbaud HPS link.
        uart_speed = 32'd4000000;
        repeat (4) @(negedge clk);
        wr(3, 8'h03);
        wr(0, 8'h00);
        @(negedge tx);
        t0 = $realtime;
        @(posedge tx);
        t1 = $realtime;
        check("4 Mbaud start+data ns", (t1 - t0) > 2150.0 && (t1 - t0) < 2350.0, 1'b1);
        wait_lsr(8'h40);
        rx = 0;
        #250;
        rx = 1;
        #(2250);
        rd(5, d);
        check("4 Mbaud RX", d[0], 1'b1);
        expect_reg("4 Mbaud data", 0, 8'hff);

        if (failures == 0) $display("uart16550 tests passed");
        $finish(failures != 0);
    end
endmodule
