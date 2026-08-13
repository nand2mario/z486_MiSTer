// PIC INTA Bridge: ao486 PIC handshake to z486 INTA bus cycles
//
// ao486 PIC uses: interrupt_do (request), interrupt_vector (8-bit), interrupt_done (ack)
// z486 uses: intr (level input), inta (2-cycle bus sequence), din (vector on 2nd INTA)
//
// Protocol:
//   PIC.interrupt_do to z486.intr
//   z486.inta (1st cycle) to dummy response (ready + din=0)
//   z486.inta (2nd cycle) to return interrupt_vector, pulse interrupt_done
//
`timescale 1ns/1ns

module pic_inta_bridge (
    input              clk,
    input              reset_n,

    // PIC interface
    input              pic_interrupt_do,       // PIC has pending interrupt
    input       [7:0]  pic_interrupt_vector,   // Interrupt vector number
    output reg         pic_interrupt_done,     // Acknowledge to PIC

    // z486 interface
    output reg         cpu_intr,               // Interrupt request to CPU
    input              cpu_inta,               // INTA bus cycle from CPU
    output reg [31:0]  cpu_inta_din,           // Data to CPU during INTA
    output reg         cpu_inta_ready          // Ready signal during INTA
);

// State machine
localparam S_IDLE  = 2'd0;
localparam S_INTA1 = 2'd1;  // First INTA cycle (dummy)
localparam S_INTA2 = 2'd2;  // Second INTA cycle (vector)

reg [1:0] state;
reg inta_responded;  // Guard against double-fire (BIU holds inta for 2 posedges)

always @(posedge clk) begin
    if (!reset_n) begin
        state <= S_IDLE;
        cpu_intr <= 1'b0;
        pic_interrupt_done <= 1'b0;
        cpu_inta_ready <= 1'b0;
        cpu_inta_din <= 32'h0;
        inta_responded <= 1'b0;
    end else begin
        // Default: deassert one-cycle signals
        pic_interrupt_done <= 1'b0;
        cpu_inta_ready <= 1'b0;

        // Forward PIC interrupt request to CPU
        // (will be cleared when we pulse interrupt_done)
        cpu_intr <= pic_interrupt_do;

        case (state)
            S_IDLE: begin
                if (cpu_inta && !inta_responded) begin
                    // First INTA cycle: acknowledge bus handshake but don't
                    // assert resp_valid — no data for OPR_R on this cycle.
                    cpu_inta_din <= 32'h0;
                    cpu_inta_ready <= 1'b1;
                    inta_responded <= 1'b1;
                    state <= S_INTA1;
                end
            end

            S_INTA1: begin
                // Wait for inta to deassert (BIU releases between cycles)
                if (!cpu_inta) begin
                    inta_responded <= 1'b0;
                    state <= S_INTA2;
                end
            end

            S_INTA2: begin
                if (cpu_inta && !inta_responded) begin
                    // Second INTA cycle: return vector, acknowledge PIC
                    cpu_inta_din <= {24'h0, pic_interrupt_vector};
                    cpu_inta_ready <= 1'b1;
                    pic_interrupt_done <= 1'b1;
                    inta_responded <= 1'b1;
                    state <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase

        // Clear inta_responded when inta deasserts
        if (!cpu_inta)
            inta_responded <= 1'b0;
    end
end

endmodule
