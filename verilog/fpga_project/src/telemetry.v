`timescale 1ns/1ps
// ============================================================================
// telemetry.v -- 115200 8N1 binary telemetry on the FPGA UART
//                (F12 -> on-board FTDI channel B -> PC COM9).
//
//   Why this exists: uart_txd used to be tied to 1'b1, so the only debugging
//   channel was the 1-digit 7-segment tube and two LEDs -- the balance loop
//   cannot be diagnosed or tuned like that.
//
//   Frame = 15 bytes, sent at RATE_HZ, with a rolling sequence byte so the PC
//   can detect dropped frames:
//
//     [0]      0xA5              sync
//     [1]      seq               rolling 8-bit frame counter
//     [2]      flags             bit0..2 mode (0 STOP 1 JUDGE 2 PUMP 3 BAL)
//                                bit3 wdog (saturation watchdog release window)
//                                bit4 link_ok   bit5 enable(interlock ok)
//                                bit6 braking   bit7 key1 (raw, active low)
//     [3][4]   alpha  int16      centideg, 0 = rod vertical up   (big endian)
//     [5][6]   adot   int16      centideg/s
//     [7][8]   duty   int16      -10000..10000 (duty_x100)
//     [9][10]  adc    uint16     raw angle potentiometer 0..4095
//     [11][12] enc    int16      enc_pos, low 16 bits
//     [13][14] frames uint16     ADC input frames accepted since reset.  The
//                                field/signal keeps the historical `frames` /
//                                `spi_frames` name, but the current source is
//                                the UART ADC link; a stalled link is visible
//                                instead of only showing as a frozen adc
//
//   Handshake: valid is held high while the frame is being walked; uart_tx
//   accepts one byte per `ready` and the index advances on the accepting edge,
//   so the bytes go out back-to-back with no inter-byte gap.
// ============================================================================
module telemetry #(
    parameter integer RATE_HZ = 50
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick_1k,      // 1 kHz master tick
    input  wire [2:0]  mode,
    input  wire        link_ok,
    input  wire        enable,
    input  wire        braking,
    input  wire        key1,
    input  wire        wdog,                 // saturation watchdog release active
    input  wire signed [15:0] alpha,
    input  wire signed [15:0] adot,
    input  wire signed [15:0] duty,
    input  wire [11:0] adc,
    input  wire signed [31:0] enc_pos,
    input  wire [15:0] frames,       // SPI frames received since reset
    output wire        uart_txd
);
    localparam integer DIV  = (1000 / RATE_HZ);
    localparam [3:0]   LAST = 4'd14;         // 15 bytes: 0..14

    reg [7:0]  seq;
    reg [7:0]  div;
    reg [3:0]  idx;
    reg        send;                         // 1 = walking a frame

    // snapshot latched when the frame starts, stable for its whole length
    reg [7:0]  r_flags;
    reg signed [15:0] r_alpha, r_adot, r_duty;
    reg [11:0] r_adc;
    reg [15:0] r_enc;
    reg [15:0] r_frm;

    reg [7:0] tx_data;
    wire      ready;

    uart_tx #(.CLK_HZ(50_000_000), .BAUD(115200)) u_uart (
        .clk   (clk),
        .rst_n (rst_n),
        .data  (tx_data),
        .valid (send),
        .ready (ready),
        .tx    (uart_txd)
    );

    always @(*) begin
        case (idx)
            4'd0:    tx_data = 8'hA5;
            4'd1:    tx_data = seq;
            4'd2:    tx_data = r_flags;
            4'd3:    tx_data = r_alpha[15:8];
            4'd4:    tx_data = r_alpha[7:0];
            4'd5:    tx_data = r_adot[15:8];
            4'd6:    tx_data = r_adot[7:0];
            4'd7:    tx_data = r_duty[15:8];
            4'd8:    tx_data = r_duty[7:0];
            4'd9:    tx_data = {4'b0, r_adc[11:8]};
            4'd10:   tx_data = r_adc[7:0];
            4'd11:   tx_data = r_enc[15:8];
            4'd12:   tx_data = r_enc[7:0];
            4'd13:   tx_data = r_frm[15:8];
            default: tx_data = r_frm[7:0];
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seq     <= 8'd0;
            div     <= 8'd0;
            idx     <= 4'd0;
            send    <= 1'b0;
            r_flags <= 8'd0;
            r_alpha <= 16'sd0;
            r_adot  <= 16'sd0;
            r_duty  <= 16'sd0;
            r_adc   <= 12'd0;
            r_enc   <= 16'd0;
            r_frm   <= 16'd0;
        end
        else if (!send) begin
            if (tick_1k) begin
                if (div >= DIV[7:0] - 8'd1) begin
                    div     <= 8'd0;
                    r_flags <= {key1, braking, enable, link_ok, wdog, mode};
                    r_alpha <= alpha;
                    r_adot  <= adot;
                    r_duty  <= duty;
                    r_adc   <= adc;
                    r_enc   <= enc_pos[15:0];
                    r_frm   <= frames;
                    idx     <= 4'd0;
                    send    <= 1'b1;
                end
                else div <= div + 8'd1;
            end
        end
        else if (ready) begin                  // a byte was just accepted
            if (idx == LAST) begin
                send <= 1'b0;
                seq  <= seq + 8'd1;
            end
            else idx <= idx + 4'd1;
        end
    end

endmodule
