// 16550A-compatible serial port for the z486 I/O bus.
//
// The divisor is referenced to 115200 baud, as on a 1.8432 MHz PC UART. When
// the HPS link runs faster, a guest divisor of 1 selects the link speed (turbo).
// Peripheral reads are registered: io_read performs the side effect on the same
// edge that captures io_readdata.
module uart16550 #(
    parameter int CLK_HZ = 85_000_000
) (
    input  logic        clk,
    input  logic        reset,
    input  logic [31:0] uart_speed,

    input  logic  [2:0] io_address,
    input  logic        io_read,
    input  logic        io_write,
    input  logic        io_cs,
    input  logic  [7:0] io_writedata,
    output logic  [7:0] io_readdata = 8'hff,
    output logic        irq,

    input  logic        rx,
    output logic        tx,
    input  logic        cts_n,
    input  logic        dsr_n,
    input  logic        dcd_n,
    input  logic        ri_n,
    output logic        rts_n,
    output logic        dtr_n
);

localparam int MAX_BASE = CLK_HZ / 8;

// Register file
logic  [3:0] ier;
logic  [3:0] iir_id;
logic  [7:0] lcr;
logic  [4:0] mcr;
logic  [7:0] scr;
logic [15:0] divisor;
logic        fifo_en;
logic  [1:0] rx_trigger_sel;

wire        dlab    = lcr[7];
wire        reg_rd  = io_read && io_cs;
wire        reg_wr  = io_write && io_cs;
wire        wr_thr  = reg_wr && io_address == 3'd0 && !dlab;
wire        wr_dll  = reg_wr && io_address == 3'd0 && dlab;
wire        wr_ier  = reg_wr && io_address == 3'd1 && !dlab;
wire        wr_dlm  = reg_wr && io_address == 3'd1 && dlab;
wire        wr_fcr  = reg_wr && io_address == 3'd2;
wire        rd_rbr  = reg_rd && io_address == 3'd0 && !dlab;
wire        rd_iir  = reg_rd && io_address == 3'd2;
wire        rd_lsr  = reg_rd && io_address == 3'd5;
wire        rd_msr  = reg_rd && io_address == 3'd6;
wire        rx_clear = wr_fcr && (io_writedata[1] || (io_writedata[0] != fifo_en));
wire        tx_clear = wr_fcr && (io_writedata[2] || (io_writedata[0] != fifo_en));

// Frame format
wire  [3:0] data_bits = 4'd5 + {2'd0, lcr[1:0]};
wire        parity_en = lcr[3];
wire  [3:0] frame_bits = 4'd1 + data_bits + {3'd0, parity_en} + (lcr[2] ? 4'd2 : 4'd1);

// 8x baud tick. Each step takes one adder, so the rate needs no divider.
logic [23:0] base_speed = 24'd115200;
logic [28:0] baud_acc = '0;
logic [15:0] divisor_count = 16'd1;
logic        baud_tick = 1'b0;

wire         base_tick = !baud_acc[28];
wire  [26:0] base_inc = {base_speed, 3'd0};

always_ff @(posedge clk) begin
    base_speed <= (uart_speed <= 32'd115200) ? 24'd115200 :
                  (uart_speed >= 32'(MAX_BASE)) ? 24'(MAX_BASE) : uart_speed[23:0];
    baud_acc <= baud_acc + {2'd0, base_inc} - (base_tick ? 29'(CLK_HZ) : 29'd0);

    baud_tick <= 1'b0;
    if (reset || wr_dll || wr_dlm) begin
        divisor_count <= 16'd1;
    end else if (base_tick && divisor != 16'd0) begin
        if (divisor_count <= 16'd1) begin
            divisor_count <= divisor;
            baud_tick <= 1'b1;
        end else begin
            divisor_count <= divisor_count - 16'd1;
        end
    end
end

// Transmit FIFO and shifter
logic  [7:0] tx_mem [0:15];
logic  [3:0] tx_wr, tx_rd;
logic  [4:0] tx_count;
logic [10:0] tx_shift;
logic  [6:0] tx_ticks;
logic  [2:0] tx_phase;
logic        tx_line;
logic        tx_busy;
logic        thre_pending;

wire        thre = tx_count == 5'd0;
wire  [7:0] tx_head = tx_mem[tx_rd];
wire  [7:0] tx_data = tx_head & (8'hff >> (4'd8 - data_bits));
wire        tx_parity = lcr[5] ? !lcr[4] : (^tx_data) ^ !lcr[4];
wire [10:0] tx_frame_word = tx_frame(tx_data, data_bits, parity_en, tx_parity);
wire        tx_load = baud_tick && !tx_busy && !thre;
wire        tx_push = wr_thr && (fifo_en ? tx_count != 5'd16 : thre);
wire        tx_pop  = tx_load;

function automatic logic [10:0] tx_frame(input logic [7:0] data, input logic [3:0] bits,
                                         input logic has_parity, input logic parity);
    logic [10:0] frame;
    frame = 11'h7fe;
    frame[1 +: 8] = data | (8'hff << bits);
    if (has_parity) frame[bits + 4'd1] = parity;
    return frame;
endfunction

always_ff @(posedge clk) begin
    if (reset) begin
        tx_wr        <= '0;
        tx_rd        <= '0;
        tx_count     <= '0;
        tx_line      <= 1'b1;
        tx_busy      <= 1'b0;
        thre_pending <= 1'b0;
    end else begin
        if (wr_thr) begin
            // Without FIFOs a second write replaces the holding register.
            tx_mem[(fifo_en || thre) ? tx_wr : tx_rd] <= io_writedata;
            thre_pending <= 1'b0;
        end

        if (tx_clear) begin
            tx_wr <= '0;
            tx_rd <= '0;
            tx_count <= '0;
            thre_pending <= ier[1];
        end else begin
            if (tx_push) tx_wr <= tx_wr + 4'd1;
            if (tx_pop) tx_rd <= tx_rd + 4'd1;
            tx_count <= tx_count + {4'd0, tx_push} - {4'd0, tx_pop};
            if (tx_pop && tx_count == 5'd1 && !tx_push) thre_pending <= 1'b1;
        end

        if (wr_ier && io_writedata[1] && !ier[1] && thre) thre_pending <= 1'b1;
        if (rd_iir && iir_id == 4'b0010) thre_pending <= 1'b0;

        if (baud_tick) begin
            if (tx_busy) begin
                tx_phase <= tx_phase + 3'd1;
                tx_ticks <= tx_ticks - 7'd1;
                if (tx_phase == 3'd7) begin
                    tx_line  <= tx_shift[0];
                    tx_shift <= {1'b1, tx_shift[10:1]};
                end
                if (tx_ticks == 7'd1) begin
                    tx_busy <= 1'b0;
                    tx_line <= 1'b1;
                end
            end else if (!thre) begin
                tx_busy  <= 1'b1;
                tx_line  <= 1'b0;
                tx_shift <= {1'b1, tx_frame_word[10:1]};
                tx_phase <= 3'd1;
                // 1.5 stop bits apply to 5-bit characters when LCR[2] is set.
                tx_ticks <= {frame_bits, 3'd0} - ((lcr[2] && lcr[1:0] == 2'd0) ? 7'd4 : 7'd0) - 7'd1;
            end
        end
    end
end

// Receive shifter
localparam RX_IDLE  = 2'd0;
localparam RX_START = 2'd1;
localparam RX_DATA  = 2'd2;
localparam RX_BREAK = 2'd3; // Framing error at a space: wait for mark.

logic  [1:0] rx_sync = 2'b11;
logic  [1:0] rx_state;
logic  [2:0] rx_phase;
logic  [3:0] rx_bit;
logic  [7:0] rx_shift;
logic        rx_parity_bit;

wire        rx_in = mcr[4] ? tx_line : rx_sync[1];
wire  [3:0] rx_stop_bit = data_bits + {3'd0, parity_en};
wire        rx_sample = baud_tick && rx_state == RX_DATA && rx_phase == 3'd7;
wire        rx_done = rx_sample && rx_bit == rx_stop_bit;
wire  [7:0] rx_data = rx_shift >> (4'd8 - data_bits);
wire        rx_parity_want = lcr[5] ? !lcr[4] : (^rx_data) ^ !lcr[4];
wire        rx_parity_err = parity_en && rx_parity_bit != rx_parity_want;
wire        rx_frame_err = !rx_in;
wire        rx_break = !rx_in && !rx_parity_bit && rx_data == 8'd0;

// Receive FIFO: {break, framing, parity, data}
logic [10:0] rx_mem [0:15];
logic  [3:0] rx_wr, rx_rd;
logic  [4:0] rx_count;
logic  [4:0] rx_err_count;
logic        rx_overrun;
logic  [2:0] rx_err_latch;
logic        rx_err_read;
logic  [8:0] rx_timer;
logic        rx_timeout;

wire [10:0] rx_head = rx_mem[rx_rd];
wire        rx_empty = rx_count == 5'd0;
wire  [2:0] rx_head_err = (rx_empty || rx_err_read) ? 3'd0 : rx_head[10:8];
wire  [2:0] rx_lsr_err = rx_err_latch | rx_head_err;
wire [10:0] rx_word = {rx_break, rx_frame_err, rx_parity_err, rx_data};
wire        rx_pop = rd_rbr && !rx_empty;
wire        rx_room = fifo_en ? rx_count != 5'd16 : rx_empty;
wire        rx_push = rx_done && rx_room;
wire        rx_replace = rx_done && !fifo_en && !rx_empty; // 16450 overwrites RBR.
wire        rx_head_has_err = |rx_head[10:8];
wire        rx_word_has_err = |rx_word[10:8];
wire  [8:0] rx_timeout_ticks = {frame_bits, 5'd0}; // Four character times.

always_ff @(posedge clk) begin
    rx_sync <= {rx_sync[0], rx};

    if (reset) begin
        rx_state <= RX_IDLE;
    end else if (baud_tick) begin
        rx_phase <= rx_phase + 3'd1;
        case (rx_state)
            RX_IDLE: if (!rx_in) begin
                rx_state <= RX_START;
                rx_phase <= 3'd1;
            end
            RX_START: if (rx_phase == 3'd3) begin
                rx_state <= rx_in ? RX_IDLE : RX_DATA;
                rx_phase <= 3'd0;
                rx_bit <= 4'd0;
                rx_parity_bit <= 1'b0;
            end
            RX_DATA: if (rx_phase == 3'd7) begin
                rx_bit <= rx_bit + 4'd1;
                if (rx_bit < data_bits) rx_shift <= {rx_in, rx_shift[7:1]};
                else if (rx_bit < rx_stop_bit) rx_parity_bit <= rx_in;
                else rx_state <= rx_in ? RX_IDLE : RX_BREAK;
            end
            default: if (rx_in) rx_state <= RX_IDLE;
        endcase
    end
end

always_ff @(posedge clk) begin
    if (reset) begin
        rx_wr <= '0;
        rx_rd <= '0;
        rx_count <= '0;
        rx_err_count <= '0;
        rx_overrun <= 1'b0;
        rx_err_latch <= '0;
        rx_err_read <= 1'b0;
        rx_timer <= '0;
        rx_timeout <= 1'b0;
    end else begin
        if (rx_done && !rx_room) rx_overrun <= 1'b1;
        if (rd_lsr) begin
            rx_overrun <= rx_done && !rx_room;
            rx_err_latch <= '0;
            if (!rx_empty) rx_err_read <= 1'b1;
        end

        if (rx_push) rx_mem[rx_wr] <= rx_word;
        else if (rx_replace) rx_mem[rx_rd] <= rx_word;

        if (rx_clear) begin
            rx_wr <= '0;
            rx_rd <= '0;
            rx_count <= '0;
            rx_err_count <= '0;
            rx_err_latch <= '0;
            rx_err_read <= 1'b0;
            rx_timer <= '0;
            rx_timeout <= 1'b0;
        end else begin
            if (rx_push) rx_wr <= rx_wr + 4'd1;
            if (rx_pop) begin
                rx_rd <= rx_rd + 4'd1;
                rx_err_read <= 1'b0;
                if (!rd_lsr) rx_err_latch <= rx_err_latch | rx_head_err;
            end
            rx_count <= rx_count + {4'd0, rx_push} - {4'd0, rx_pop};
            rx_err_count <= rx_err_count + {4'd0, rx_push && rx_word_has_err}
                                         - {4'd0, rx_pop && rx_head_has_err};

            if (rx_push || rx_pop) begin
                rx_timer <= '0;
                rx_timeout <= 1'b0;
            end else if (baud_tick && !rx_empty && fifo_en && !rx_timeout) begin
                rx_timer <= rx_timer + 9'd1;
                if (rx_timer + 9'd1 >= rx_timeout_ticks) rx_timeout <= 1'b1;
            end
        end
    end
end

// Modem lines; internally 1 means asserted.
wire  [3:0] modem_in = mcr[4] ? {mcr[3], mcr[2], mcr[0], mcr[1]}
                              : {!dcd_n, !ri_n, !dsr_n, !cts_n};
logic [3:0] modem_prev;
logic [3:0] modem_delta;

always_ff @(posedge clk) begin
    modem_prev <= modem_in;
    if (reset) begin
        modem_delta <= '0;
    end else begin
        modem_delta <= (rd_msr ? 4'd0 : modem_delta) |
                       {modem_in[3] ^ modem_prev[3],
                        modem_prev[2] & !modem_in[2], // TERI: trailing edge only.
                        modem_in[1] ^ modem_prev[1],
                        modem_in[0] ^ modem_prev[0]};
    end
end

// Interrupts
logic [4:0] rx_trigger;
always_comb begin
    case (rx_trigger_sel)
        2'd0: rx_trigger = 5'd1;
        2'd1: rx_trigger = 5'd4;
        2'd2: rx_trigger = 5'd8;
        default: rx_trigger = 5'd14;
    endcase
end

wire  [7:0] lsr = {fifo_en && rx_err_count != 5'd0, thre && !tx_busy, thre,
                   rx_lsr_err[2:0], rx_overrun, !rx_empty};
wire        rx_line_int = ier[2] && |lsr[4:1];
wire        rx_data_int = ier[0] && rx_count >= (fifo_en ? rx_trigger : 5'd1);
wire        rx_timeout_int = ier[0] && rx_timeout;
wire        thre_int = ier[1] && thre_pending;
wire        modem_int = ier[3] && |modem_delta;

always_comb begin
    if (rx_line_int)         iir_id = 4'b0110;
    else if (rx_data_int)    iir_id = 4'b0100;
    else if (rx_timeout_int) iir_id = 4'b1100;
    else if (thre_int)       iir_id = 4'b0010;
    else if (modem_int)      iir_id = 4'b0000;
    else                     iir_id = 4'b0001;
end

// PC serial cards gate the interrupt output with OUT2.
assign irq = mcr[3] && !iir_id[0];

// Register access and external pins
always_ff @(posedge clk) begin
    if (reset) begin
        ier <= '0;
        lcr <= '0;
        mcr <= '0;
        scr <= '0;
        divisor <= 16'd12;
        fifo_en <= 1'b0;
        rx_trigger_sel <= '0;
    end else if (reg_wr) begin
        case (io_address)
            3'd0: if (dlab) divisor[7:0] <= io_writedata;
            3'd1: if (dlab) divisor[15:8] <= io_writedata;
                  else ier <= io_writedata[3:0];
            3'd2: begin
                fifo_en <= io_writedata[0];
                if (io_writedata[0]) rx_trigger_sel <= io_writedata[7:6];
            end
            3'd3: lcr <= io_writedata;
            3'd4: mcr <= io_writedata[4:0];
            3'd7: scr <= io_writedata;
            default: ;
        endcase
    end
end

always_ff @(posedge clk) begin
    if (reg_rd) begin
        case (io_address)
            3'd0: io_readdata <= dlab ? divisor[7:0] : (rx_empty ? 8'd0 : rx_head[7:0]);
            3'd1: io_readdata <= dlab ? divisor[15:8] : {4'd0, ier};
            3'd2: io_readdata <= {{2{fifo_en}}, 2'd0, iir_id};
            3'd3: io_readdata <= lcr;
            3'd4: io_readdata <= {3'd0, mcr};
            3'd5: io_readdata <= lsr;
            3'd6: io_readdata <= {modem_in, modem_delta};
            default: io_readdata <= scr;
        endcase
    end
end

assign tx    = mcr[4] ? 1'b1 : (tx_line && !lcr[6]);
assign rts_n = mcr[4] ? 1'b1 : !mcr[1];
assign dtr_n = mcr[4] ? 1'b1 : !mcr[0];

endmodule
