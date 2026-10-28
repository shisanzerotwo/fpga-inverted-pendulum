`timescale 1ns/1ps
// ============================================================================
// uart_rx.v -- minimal 8N1 UART receiver (default 1 Mbaud @ 50 MHz).
//
//   start  : falling edge on rx while idle
//   verify : sample the start bit at its middle (HALF) and abort if high
//   data   : 8 bits, LSB first, each sampled at its middle (full CPB)
//   stop   : wait to the stop-bit middle, then pulse valid with the byte
//
//   The stop bit's LEVEL is not checked (kept minimal, a mis-framed byte is
//   rejected downstream by the seq-increment check in arm_adc_uart.v).
// ============================================================================
module uart_rx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 1_000_000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid
);
    localparam integer CPB  = CLK_HZ / BAUD;      // clocks per bit
    localparam integer HALF = CPB / 2;

    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    reg [1:0]  st;
    reg [15:0] div;
    reg [2:0]  bi;
    reg [7:0]  sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            div   <= 16'd0;
            bi    <= 3'd0;
            sh    <= 8'd0;
            data  <= 8'd0;
            valid <= 1'b0;
        end
        else begin
            valid <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (!rx) begin
                        div <= 16'd0;
                        st  <= S_START;
                    end
                end

                S_START: begin                 // confirm at the middle
                    if (div >= HALF - 1) begin
                        div <= 16'd0;
                        if (!rx) begin
                            st <= S_DATA;
                            bi <= 3'd0;
                        end
                        else begin
                            st <= S_IDLE;      // glitch, not a start
                        end
                    end
                    else begin
                        div <= div + 16'd1;
                    end
                end

                S_DATA: begin                  // one full bit per step
                    if (div >= CPB - 1) begin
                        div <= 16'd0;
                        sh  <= {rx, sh[7:1]};  // LSB first
                        if (bi >= 3'd7) st <= S_STOP;
                        else            bi <= bi + 3'd1;
                    end
                    else begin
                        div <= div + 16'd1;
                    end
                end

                S_STOP: begin
                    if (div >= HALF - 1) begin
                        div   <= 16'd0;
                        st    <= S_IDLE;
                        data  <= sh;
                        valid <= 1'b1;
                    end
                    else begin
                        div <= div + 16'd1;
                    end
                end
            endcase
        end
    end
endmodule
