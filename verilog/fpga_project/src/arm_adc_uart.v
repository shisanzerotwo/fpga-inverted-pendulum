`timescale 1ns/1ps
// ============================================================================
// arm_adc_uart.v -- GD32 -> FPGA sample link over UART (2026-10-16).
//
// WHY: the SPI link's SCK lane (FPGA ball L12 <-> GD32 PA5) went open
// (diagnosed on the bench: NSS arrives at 20 kSPS but the SPI slave hardware
// counts ZERO clocked frames).  The link therefore moved to the spare
// point-to-point net PA2 (GD32 USART2_TX -> FPGA ball K11).  Same contract
// as arm_adc_link.v, only the transport changed:
//
//   frame = 2 UART bytes, 1 Mbaud 8N1, 20 kSPS:
//       byte1 = {seq[3:0], adc[11:8]}      (first)
//       byte2 = adc[7:0]                   (second)
//   link_ok = the last CNT_OK frames each had the counter advance by exactly
//   one; drops on the first bad frame; also drops after TO_MS without bytes.
//
// PHASE SELF-ALIGNMENT: the receiver may come up mid-stream, so the first
// byte it sees can be a second-of-pair byte.  Pair boundaries are found by
// hunting: 64 consecutive bad pairs -> drop exactly one byte (shift the
// boundary by one) and keep validating; the true phase locks within a few
// milliseconds and a wrong one can never masquerade (the seq check rejects
// it).  A single stray corrupt frame never triggers the hunt (needs 64).
// ============================================================================
module arm_adc_uart #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 1_000_000,
    parameter integer CNT_OK = 8,          // consecutive good frames for link_ok
    parameter integer TO_MS  = 5           // no-byte timeout -> link_ok = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        uart_rx_i,          // from the GD32 (ball K11)
    output reg  [11:0] adc,
    output reg  [3:0]  seq,
    output reg         frame,              // 1-clock pulse per completed pair
    output reg         link_ok,
    // TEMP DEBUG (2026-10-16, link commissioning): raw byte counter and the
    // last two bytes as received -- wired into spare telemetry fields so the
    // wire content is directly observable.  Remove after commissioning.
    output reg  [15:0] dbg_bytecnt,
    output reg  [15:0] dbg_last2
);
    localparam integer TO_CLK = (CLK_HZ / 1000) * TO_MS;

    wire [7:0] bd;
    wire       bvalid;

    uart_rx #(
        .CLK_HZ (CLK_HZ),
        .BAUD   (BAUD)
    ) u_rx (
        .clk   (clk),
        .rst_n (rst_n),
        .rx    (uart_rx_i),
        .data  (bd),
        .valid (bvalid)
    );

    reg        want_hi;        // next byte is the {seq,adc_hi} one
    reg        drop_next;      // boundary-hunt: swallow exactly one byte
    reg [7:0]  hi_b;
    reg [3:0]  prev_seq;
    reg [4:0]  ok_cnt;         // good run toward CNT_OK
    reg [7:0]  hunt_cnt;       // pairs since the last hunt step (unlocked only)
    reg [19:0] stale_cnt;

    wire good = (hi_b[7:4] == prev_seq + 4'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            want_hi   <= 1'b1;
            drop_next <= 1'b0;
            hi_b      <= 8'd0;
            prev_seq  <= 4'd0;
            ok_cnt    <= 5'd0;
            hunt_cnt  <= 8'd0;
            stale_cnt <= 20'd0;
            adc       <= 12'd0;
            seq       <= 4'd0;
            frame     <= 1'b0;
            link_ok   <= 1'b0;
        end
        else begin
            frame <= 1'b0;

            // byte-starvation timeout (a dead sender must not stay linked)
            if (bvalid)    stale_cnt <= 20'd0;
            else if (!(stale_cnt >= TO_CLK[19:0])) stale_cnt <= stale_cnt + 20'd1;
            if (stale_cnt >= TO_CLK[19:0]) link_ok <= 1'b0;

            if (bvalid) begin
                dbg_bytecnt <= dbg_bytecnt + 16'd1;         // TEMP DEBUG
                dbg_last2   <= {dbg_last2[7:0], bd};        // TEMP DEBUG
                if (drop_next) begin
                    drop_next <= 1'b0;             // shift boundary by one byte
                end
                else if (want_hi) begin
                    hi_b    <= bd;
                    want_hi <= 1'b0;
                end
                else begin
                    want_hi <= 1'b1;
                    adc  <= {hi_b[3:0], bd};       // 12-bit sample
                    seq  <= hi_b[7:4];

                    if (good) begin
                        if (ok_cnt < CNT_OK) ok_cnt <= ok_cnt + 5'd1;
                    end
                    else begin
                        ok_cnt <= 5'd0;
                    end

                    // PHASE HUNT: while NOT locked, try a one-byte boundary
                    // shift every 200 pairs.  A plain "64 bads in a row"
                    // trigger does not work: in the wrong phase the garbage
                    // occasionally passes single checks (bench-verified in
                    // sim), resetting any consecutive-bad counter forever.
                    if (link_ok) begin
                        hunt_cnt <= 8'd0;          // aligned: no hunting
                    end
                    else if (hunt_cnt >= 8'd199) begin
                        hunt_cnt  <= 8'd0;
                        drop_next <= 1'b1;
                    end
                    else begin
                        hunt_cnt <= hunt_cnt + 8'd1;
                    end

                    link_ok <= good && (ok_cnt >= CNT_OK - 1);
                    prev_seq <= hi_b[7:4];
                    frame    <= 1'b1;
                end
            end
        end
    end
endmodule
