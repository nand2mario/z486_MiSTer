// PS2 device (keyboard or mouse) emulator from MiSTer
module z486_ps2_device #(parameter PS2_FIFO_BITS=5)
(
    input        clk_sys,
    input        reset,

	input  [7:0] wdata,
	input        we,

	input        ps2_clk,
	output reg   ps2_clk_out,
	output reg   ps2_dat_out,
	output reg   tx_empty,

	input        ps2_clk_in,
	input        ps2_dat_in,

	output [8:0] rdata,         // [8] has_data, [7:0] data
	input        rd             // rd=1: reset rdata[8]
);

reg [7:0] fifo[1<<PS2_FIFO_BITS];

reg [PS2_FIFO_BITS-1:0] wptr;
reg [PS2_FIFO_BITS-1:0] rptr;

reg [2:0] rx_state = 0;
reg [3:0] tx_state = 0;

reg       has_data;
reg [7:0] data;
assign    rdata = {has_data, data};

always@(posedge clk_sys) begin
    reg [7:0] tx_byte;
    reg parity;
    reg r_inc;
    reg old_clk;
    reg [1:0] timeout;

    reg [3:0] rx_cnt;

    reg c1,c2,d1;

    if (reset) begin
        // synchronous reset: release lines and clear state/FIFOs
        ps2_clk_out <= 1'b1;
        ps2_dat_out <= 1'b1;
        tx_empty    <= 1'b1;

        wptr        <= {PS2_FIFO_BITS{1'b0}};
        rptr        <= {PS2_FIFO_BITS{1'b0}};

        rx_state    <= 3'd0;
        tx_state    <= 4'd0;

        has_data    <= 1'b0;
        data        <= 8'h00;

        // locals declared below get reset here
        // Note: defaults reflect idle, pulled-up PS/2 bus
        tx_byte     <= 8'h00;
        parity      <= 1'b1;
        r_inc       <= 1'b0;
        old_clk     <= 1'b0;
        timeout     <= 2'b00;
        rx_cnt      <= 4'd0;
        c1          <= 1'b1;
        c2          <= 1'b1;
        d1          <= 1'b1;
    end else begin

		tx_empty <= ((wptr == rptr) && (tx_state == 0));

		if(we && !has_data) begin
			fifo[wptr] <= wdata;
			wptr <= wptr + 1'd1;
		end

		if(rd) has_data <= 0;

		c1 <= ps2_clk_in;
		c2 <= c1;
		d1 <= ps2_dat_in;
		if(!rx_state && !tx_state && ~c2 && c1 && ~d1) begin
			rx_state <= rx_state + 1'b1;
			ps2_dat_out <= 1;
		end

		old_clk <= ps2_clk;
		if(~old_clk & ps2_clk) begin

			if(rx_state) begin
				case(rx_state)
					1: begin
							rx_state <= rx_state + 1'b1;
							rx_cnt <= 0;
						end

					2: begin
							if(rx_cnt <= 7) data <= {d1, data[7:1]};
							else rx_state <= rx_state + 1'b1;
							rx_cnt <= rx_cnt + 1'b1;
						end

					3: if(d1) begin
							rx_state <= rx_state + 1'b1;
							ps2_dat_out <= 0;
						end

					4: begin
							ps2_dat_out <= 1;
							has_data <= 1;
							rx_state <= 0;
							rptr     <= 0;
							wptr     <= 0;
						end
				endcase
			end else begin

				// transmitter is idle?
				if(tx_state == 0) begin
					// data in fifo present?
					if(c2 && c1 && d1 && wptr != rptr) begin

						timeout <= timeout - 1'd1;
						if(!timeout) begin
							tx_byte <= fifo[rptr];
							rptr <= rptr + 1'd1;

							// reset parity
							parity <= 1;

							// start transmitter
							tx_state <= 1;

							// put start bit on data line
							ps2_dat_out <= 0;			// start bit is 0
						end
					end
				end else begin

					// transmission of 8 data bits
					if((tx_state >= 1)&&(tx_state < 9)) begin
						ps2_dat_out <= tx_byte[0];	          // data bits
						tx_byte[6:0] <= tx_byte[7:1]; // shift down
						if(tx_byte[0])
							parity <= !parity;
					end

					// transmission of parity
					if(tx_state == 9) ps2_dat_out <= parity;

					// transmission of stop bit
					if(tx_state == 10) ps2_dat_out <= 1;    // stop bit is 1

					// advance state machine
					if(tx_state < 11) tx_state <= tx_state + 1'd1;
						else tx_state <= 0;
				end
			end
		end

		if(~old_clk & ps2_clk) ps2_clk_out <= 1;
		if(old_clk & ~ps2_clk) ps2_clk_out <= ((tx_state == 0) && (rx_state<2));
    end
end

endmodule
