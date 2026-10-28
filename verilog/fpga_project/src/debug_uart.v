// ============================================================================
// debug_uart.v -- streams the angle-sensor reading over the board UART so the
//                 raw value can be watched on a PC while bring-up is in flight.
//
//   Line format, one line every PERIOD_MS milliseconds, 115200 8N1:
//
//       'A' <adc[11:8]> <adc[7:4]> <adc[3:0]> <seq> <link_ok> CR LF
//
//   e.g.  A7F381 = adc 0x7F3, frame counter 8, link_ok=1
//   The 4-bit frame counter is visible here too: it must keep cycling,
//   a frozen counter means the GD32 stopped answering.
// ============================================================================
module debug_uart #(
    parameter integer CLK_FREQ  = 50_000_000,
    parameter integer BAUD      = 115_200,
    parameter integer PERIOD_MS = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] adc,
    input  wire [3:0]  seq,
    input  wire        link_ok,
    output reg         txd
);
    localparam integer DIV = CLK_FREQ / BAUD;             // 434 at 50 MHz
    localparam [26:0]  GAP = CLK_FREQ / 1000 * PERIOD_MS; // clocks between lines

    function [7:0] hex2ascii;
        input [3:0] v;
        begin
            hex2ascii = (v < 4'hA) ? (8'h30 + {4'd0, v}) : (8'h37 + {4'd0, v});
        end
    endfunction

    reg [26:0] gap_cnt;
    reg [63:0] msg;      // 'A' | hi | mid | lo | seq | link | CR | LF
    reg [2:0]  bidx;     // byte being sent
    reg [3:0]  bitidx;   // 0 = start, 1..8 = data, 9 = stop
    reg [8:0]  baud_cnt;
    reg        busy;

    wire [7:0] cur = msg[63 - bidx*8 -: 8];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gap_cnt  <= 27'd0;
            msg      <= 64'd0;
            bidx     <= 3'd0;
            bitidx   <= 4'd0;
            baud_cnt <= 9'd0;
            busy     <= 1'b0;
            txd      <= 1'b1;
        end
        else if (!busy) begin
            txd <= 1'b1;
            if (gap_cnt >= GAP - 1) begin
                gap_cnt  <= 27'd0;
                msg      <= {8'h41, hex2ascii(adc[11:8]), hex2ascii(adc[7:4]),
                             hex2ascii(adc[3:0]), hex2ascii(seq),
                             link_ok ? 8'h31 : 8'h30, 8'h0D, 8'h0A};
                bidx     <= 3'd0;
                bitidx   <= 4'd0;
                baud_cnt <= 9'd0;
                busy     <= 1'b1;
            end
            else begin
                gap_cnt <= gap_cnt + 27'd1;
            end
        end
        else if (baud_cnt != DIV - 1) begin
            baud_cnt <= baud_cnt + 9'd1;
        end
        else begin
            baud_cnt <= 9'd0;
            case (bitidx)
                4'd0: begin                       // start bit
                    txd    <= 1'b0;
                    bitidx <= 4'd1;
                end
                4'd9: begin                       // stop bit
                    txd <= 1'b1;
                    if (bidx == 3'd7) busy <= 1'b0;
                    else begin
                        bidx   <= bidx + 3'd1;
                        bitidx <= 4'd0;
                    end
                end
                default: begin                    // data, LSB first
                    txd    <= cur[bitidx - 1];
                    bitidx <= bitidx + 4'd1;
                end
            endcase
        end
    end

endmodule
