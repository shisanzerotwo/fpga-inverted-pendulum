`timescale 1ns/1ps
// ============================================================================
// arm_adc_link.v -- reads the angle sensor through the GD32 that is already on
//                   the FPGA board, turning it into a plain "remote ADC".
//
//   The 立创 G1 carries a GD32F303CBT6 hard-wired to the FPGA by 8 nets
//   (GD32 PA0..PA7 = FPGA balls J12 J11 K11 D14 E15 L12 L13 L16), which are
//   the GD32's SPI0 + USART1.  We use SPI0:
//
//       FPGA (master)  SPI_NSS / SPI_SCK / SPI_MOSI  ->  GD32 (slave)
//       FPGA (master)  SPI_MISO                      <-  GD32
//
//   One 16-bit frame carries:  [15:12] 4-bit rolling counter  (integrity)
//                              [11:0]  12-bit ADC value       (angle sensor)
//
//   The GD32 only digitises: it samples the potentiometer on PB0 continuously
//   and keeps the SPI shift register loaded.  Every filter, the decimation and
//   the whole control loop live here, in the FPGA.
//
//   Poll rate  = clk / POLL_DIV   (50 MHz / 2500 = 20 kSPS)
//   SCK        = clk / (2*SCK_DIV) (50 MHz / 8 = 6.25 MHz)
//   link_ok    = high while the last CNT_OK frames each had the counter
//                advance by exactly one; drops on the first bad frame.
// ============================================================================
module arm_adc_link #(
    parameter integer POLL_DIV = 2500,   // clocks between frames
    parameter integer SCK_DIV  = 4,      // SCK half period in clocks
    parameter integer CNT_OK   = 8,      // consecutive good frames for link_ok
    parameter integer TO_MS    = 5       // link timeout: no frame for this long
                                         // -> link_ok = 0 (see note below)
) (
    input  wire        clk,
    input  wire        rst_n,
    // ---- SPI to the on-board GD32 ----
    output reg         SPI_NSS,
    output reg         SPI_SCK,
    output wire        SPI_MOSI,
    input  wire        SPI_MISO,
    // ---- results ----
    output reg  [11:0] adc,        // latest angle-sensor sample
    output reg  [3:0]  seq,        // its rolling counter
    output reg         frame,      // 1-clock pulse per completed read
    output reg         link_ok
);

    // LINK TIMEOUT, added 2026-10-05.
    // The counter check below only runs when a frame COMPLETES, so a link that
    // simply stops delivering frames left `link_ok` frozen at 1 while `adc`
    // kept returning the last value.  Measured on the bench: adc staleness of
    // 60..460 ms with link_ok still high, which made the control FSM capture and
    // balance against a phantom angle.  Now the link is declared dead if no
    // frame arrives for TO_MS.
    localparam integer TO_CLK = (50_000_000 / 1000) * TO_MS;

    localparam S_IDLE  = 1'b0;
    localparam S_SHIFT = 1'b1;

    reg        state;
    reg [15:0] poll_cnt;
    reg [3:0]  bit_cnt;
    reg [3:0]  div_cnt;
    reg [15:0] tx_sr;
    reg [15:0] rx_sr;
    reg [3:0]  prev_seq;
    reg [4:0]  ok_cnt;                 // may need to hold up to CNT_OK
    reg [19:0] stale_cnt;              // clocks since the last completed frame

    wire stale = (stale_cnt >= TO_CLK[19:0]);

    assign SPI_MOSI = tx_sr[15];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            poll_cnt <= 16'd0;
            bit_cnt  <= 4'd0;
            div_cnt  <= 4'd0;
            tx_sr    <= 16'd0;
            rx_sr    <= 16'd0;
            prev_seq <= 4'd0;
            ok_cnt   <= 5'd0;
            stale_cnt<= 20'd0;
            SPI_NSS  <= 1'b1;
            SPI_SCK  <= 1'b0;
            adc      <= 12'd0;
            seq      <= 4'd0;
            frame    <= 1'b0;
            link_ok  <= 1'b0;
        end
        else begin
            frame <= 1'b0;                       // single-clock pulse

            // ---- link timeout: no completed frame for TO_MS ----
            // (placed BEFORE the case so a frame's own verdict wins)
            if (frame)            stale_cnt <= 20'd0;
            else if (!stale)      stale_cnt <= stale_cnt + 20'd1;
            if (stale)            link_ok   <= 1'b0;

            case (state)

                // ---------------------------------------------- wait poll --
                S_IDLE: begin
                    SPI_NSS <= 1'b1;
                    SPI_SCK <= 1'b0;
                    if (poll_cnt >= POLL_DIV - 1) begin
                        poll_cnt <= 16'd0;
                        SPI_NSS  <= 1'b0;        // frame start
                        tx_sr    <= 16'h0000;    // dummy byte, we only read
                        rx_sr    <= 16'd0;
                        bit_cnt  <= 4'd0;
                        div_cnt  <= 4'd0;
                        state    <= S_SHIFT;
                    end
                    else begin
                        poll_cnt <= poll_cnt + 16'd1;
                    end
                end

                // ------------------------------------------- shift 16 bits --
                // CPOL=0 / CPHA=0: MOSI changes on the falling edge and is
                // sampled by the slave on the rising edge; MISO is sampled by
                // us on the same rising edge.
                S_SHIFT: begin
                    if (div_cnt >= SCK_DIV - 1) begin
                        div_cnt <= 4'd0;

                        if (SPI_SCK == 1'b0) begin
                            // rising edge: sample MISO
                            SPI_SCK <= 1'b1;
                            rx_sr   <= {rx_sr[14:0], SPI_MISO};
                        end
                        else begin
                            // falling edge: next bit out
                            SPI_SCK <= 1'b0;
                            if (bit_cnt >= 4'd15) begin
                                // ---- frame complete ----
                                SPI_NSS <= 1'b1;
                                adc     <= rx_sr[11:0];
                                seq     <= rx_sr[15:12];
                                frame   <= 1'b1;

                                if (rx_sr[15:12] == prev_seq + 4'd1)
                                    ok_cnt <= (ok_cnt >= CNT_OK) ? ok_cnt : ok_cnt + 5'd1;
                                else
                                    ok_cnt <= 5'd0;

                                link_ok  <= (ok_cnt >= CNT_OK - 1);
                                prev_seq <= rx_sr[15:12];
                                state    <= S_IDLE;
                            end
                            else begin
                                bit_cnt <= bit_cnt + 4'd1;
                                tx_sr   <= {tx_sr[14:0], 1'b0};
                            end
                        end
                    end
                    else begin
                        div_cnt <= div_cnt + 4'd1;
                    end
                end

            endcase
        end
    end

endmodule
