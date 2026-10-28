`timescale 1ns/1ps
// uart_tx.v -- 115200 8N1 transmitter with a valid/ready handshake.
//
// Ported 2026-10-05 (verbatim) from the archived A-track project, where it was
// hardware-proven on this board: F12 -> on-board FTDI channel B -> PC COM9.
// Its TB (sim/uart_tx_tb.v) is the bench-verified one, also ported.
//
//   valid/ready: a byte is accepted on the clock edge where valid is high
//   and ready is high; ready is low during reset so the upstream never
//   believes a byte was taken while the transmitter was held in reset.
module uart_tx #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       valid,
    output wire       ready,
    output wire       tx
);
    localparam BIT_CLKS = CLK_HZ / BAUD;

    reg [15:0] baud_cnt;
    reg [3:0]  bit_idx;     // 0 = start bit, 1..8 = data bits, 9 = stop bit
    reg [9:0]  shifter;     // {stop, D7..D0, start}, LSB leaves first
    reg        busy;

    assign ready = ~busy & rst_n;   // not accepting while in reset
    assign tx    = busy ? shifter[0] : 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy     <= 1'b0;
            baud_cnt <= 16'd0;
            bit_idx  <= 4'd0;
            shifter  <= 10'h3FF;
        end else if (!busy) begin
            if (valid) begin
                shifter  <= {1'b1, data, 1'b0};
                busy     <= 1'b1;
                baud_cnt <= 16'd0;
                bit_idx  <= 4'd0;
            end
        end else if (baud_cnt == BIT_CLKS - 1) begin
            baud_cnt <= 16'd0;
            if (bit_idx == 4'd9) begin
                busy <= 1'b0;
            end else begin
                bit_idx <= bit_idx + 1'b1;
                shifter <= {1'b1, shifter[9:1]};
            end
        end else begin
            baud_cnt <= baud_cnt + 1'b1;
        end
    end
endmodule
