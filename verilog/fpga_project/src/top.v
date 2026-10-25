// ============================================================================
// top.v -- LCKFB LogicPi FPGA-G1 + 江协倒立摆配件, FPGA only (no MCU in the loop)
//
//   Stage 4: real control chain.  The GD32 on this board is a remote ADC
//   (option B); everything else -- decoding, filtering, the cascade PID,
//   the swing-up pump and the safety interlock -- lives here, in the FPGA.
//
//   On-board indicators:
//       led   R9 : 1 Hz heartbeat                           -> FPGA alive
//       led2  N6 : lit 0.25 s after any encoder movement    -> turn the arm
//       seg  7-seg (1 digit, common anode), DECIMAL:
//                  link_ok = 0  ->  "-"                     -> ADC UART link dead
//                  link_ok = 1  ->  0..9 = pendulum angle zone (33 deg each)
//                                     0 = rod low end, 9 = rod high end
//       PWMA + AIN1/AIN2 : KEY1 (F10) press toggles run; release does not stop:
//                  |alpha| > SWING_TH -> swing-up pump (+/-35 %, 100 ms)
//                  |alpha| < BAL_TH   -> balance PID (200 Hz) + pos trim (20 Hz)
//                  interlock (!run_latch / !link_ok / STOP)
//                  zeroes the PWM in the same clock cycle.
//
//   Signal chain: 电位器 -> GD32 PB0/ADC -> USART1/PA2 UART -> arm_adc_uart
//                 -> pendulum_ctrl (cascade PID + interlock) -> TB6612
//
//   Encoder: 11 PPR Hall AB, gear 2783/300 -> 408 edges per arm revolution.
//   Board: sys_clk T7 50 MHz, rst_n D11 KEY0, key1 F10 KEY1 (active low).
//   NOTE: English comments only -- the Gowin editor garbles Chinese.
// ============================================================================
module top (
    input  wire sys_clk,        // T7   50 MHz
    input  wire rst_n,          // D11  KEY0, active low
    input  wire key1,           // F10  KEY1, active low = press toggles run
    input  wire [1:0] kbtn,     // kit K1/K2 (N10/M11, bank 2 = 2.5V): position +/-
    // ---- on-board UART debug link (F12 / F13) ----
    input  wire uart_rxd,
    output wire uart_txd,
    // ---- on-board LEDs (active low) ----
    output wire led,            // R9  heartbeat
    output wire led2,           // N6  encoder movement
    // ---- driver board: motor PWM + direction (bank 0) ----
    output wire PWMA,           // G15  20 kHz PWM
    output wire AIN1,           // G14
    output wire AIN2,           // G16
    // ---- driver board: encoder input (bank 0) ----
    input  wire EA,             // J15   E1A
    input  wire EB,             // K16   E1B
    // ---- FPGA <-> on-board GD32, SPI0 (bank 1) ----
    output wire SPI_NSS,        // E15   GD32 PA4   (idle now: see link rescue)
    output wire SPI_SCK,        // L12   GD32 PA5   (SCK lane OPEN on this board)
    output wire SPI_MOSI,       // L16   GD32 PA7
    input  wire SPI_MISO,       // L13   GD32 PA6
    // ---- link rescue 2026-10-16: sample link moved to this spare net ----
    input  wire uart2_rxd,      // K11   GD32 PA2 / USART2_TX, 1 Mbaud UART
    // ---- on-board 1-digit common-anode 7-segment tube ----
    output wire [7:0] seg       // [0]=A .. [6]=G, [7]=DP ; active low
);

    // ------------------------------------------------------------------
    // 1 Hz heartbeat: toggle every 0.5 s at 50 MHz
    // ------------------------------------------------------------------
    localparam [25:0] BLINK_MAX = 26'd24_999_999;

    reg [25:0] blink_cnt;
    reg        led_r;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            blink_cnt <= 26'd0;
            led_r     <= 1'b0;
        end
        else if (blink_cnt >= BLINK_MAX) begin
            blink_cnt <= 26'd0;
            led_r     <= ~led_r;
        end
        else begin
            blink_cnt <= blink_cnt + 26'd1;
        end
    end

    assign led = ~led_r;                 // active low

    // ------------------------------------------------------------------
    // 1 kHz control tick (single-clock strobe)
    // ------------------------------------------------------------------
    reg [15:0] tick_cnt;
    reg        tick;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= 16'd0;
            tick     <= 1'b0;
        end
        else begin
            tick <= 1'b0;
            if (tick_cnt >= 16'd49_999) begin
                tick_cnt <= 16'd0;
                tick     <= 1'b1;
            end
            else begin
                tick_cnt <= tick_cnt + 16'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Encoder: 4x quadrature decode, position + per-tick delta
    // ------------------------------------------------------------------
    wire signed [31:0] enc_pos;
    wire signed [31:0] enc_delta;
    wire               enc_dir;

    enc_decoder #(
        .FILTER     (4),        // 4 clocks = 80 ns at 50 MHz
        .DIR_INVERT (1'b0),     // flip here if the arm counts backwards
        .DW         (32)
    ) u_enc (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .tick  (tick),
        .EA    (EA),
        .EB    (EB),
        .pos   (enc_pos),
        .delta (enc_delta),
        .dir   (enc_dir)
    );

    // movement indicator: led2 lit for 0.25 s after the last movement
    reg signed [31:0] pos_prev;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)     pos_prev <= 32'sd0;
        else if (tick)  pos_prev <= enc_pos;
    end

    wire moved = (enc_pos != pos_prev) | (enc_delta != 32'sd0);

    localparam [23:0] HOLD_MAX = 24'd12_499_999;    // 0.25 s at 50 MHz

    reg [23:0] hold;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)             hold <= 24'd0;
        else if (moved)         hold <= HOLD_MAX;
        else if (hold != 24'd0) hold <= hold - 24'd1;
    end

    assign led2 = (hold == 24'd0);       // active low: lit while hold != 0

    // ------------------------------------------------------------------
    // Angle sensor: the GD32 on this board is our remote ADC.
    // 2026-10-16 LINK RESCUE: the SPI SCK lane (ball L12 <-> GD32 PA5) went
    // OPEN on this board (bench-diagnosed: NSS arrives at 20 kSPS while the
    // SPI slave hardware counts zero clocked frames -- DIAGNOSIS.md sec.10).
    // The link moved to the spare net PA2 (GD32 USART2_TX -> ball K11) as a
    // 1 Mbaud UART with the SAME frame contract (seq4|adc12, 20 kSPS,
    // 8-frame increment lock).  The three old SPI pins are parked at their
    // idle levels: there is nothing on those lanes that can respond.
    // ------------------------------------------------------------------
    assign SPI_NSS  = 1'b1;
    assign SPI_SCK  = 1'b0;
    assign SPI_MOSI = 1'b0;

    wire [11:0] adc;
    wire [3:0]  adc_seq;
    wire        adc_frame;
    wire        link_ok;
    wire [15:0] dbg_bytecnt;   // TEMP DEBUG (link commissioning)
    wire [15:0] dbg_last2;

    arm_adc_uart #(
        .CLK_HZ (50_000_000),
        .BAUD   (1_000_000),
        .CNT_OK (8)
    ) u_adc (
        .clk         (sys_clk),
        .rst_n       (rst_n),
        .uart_rx_i   (uart2_rxd),
        .adc         (adc),
        .seq         (adc_seq),
        .frame       (adc_frame),
        .link_ok     (link_ok),
        .dbg_bytecnt (dbg_bytecnt),
        .dbg_last2   (dbg_last2)
    );

    // ------------------------------------------------------------------
    // Cascade control: swing-up pump + balance PID + same-cycle interlock
    // ------------------------------------------------------------------
    // position target buttons: kit K1/K2, active low, bank 2 = 2.5V LVCMOS25
    // edge-detect to single-clock strobes for loc_target_gen
    reg [1:0] kbtn_d;
    reg       kb_up_s, kb_dn_s;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            kbtn_d  <= 2'b11;
            kb_up_s <= 1'b0;
            kb_dn_s <= 1'b0;
        end
        else begin
            kbtn_d  <= kbtn;
            kb_up_s <= 1'b0;
            kb_dn_s <= 1'b0;
            if (kbtn_d[0] && !kbtn[0]) kb_up_s <= 1'b1;   // K1 fell
            if (kbtn_d[1] && !kbtn[1]) kb_dn_s <= 1'b1;   // K2 fell
        end
    end

    wire signed [31:0] loc_target;
    wire               loc_moving;
    loc_target_gen #(
        .STEP_HZ   (2),         // 2 revolutions/s while ramping
        .REV_COUNT (408),
        .LIMIT     (4080)
    ) u_ltg (
        .clk      (sys_clk),
        .rst_n    (rst_n),
        .tick_1k  (tick),
        .btn_up   (kb_up_s),
        .btn_down (kb_dn_s),
        .run      (ctrl_en),
        .target   (loc_target),
        .moving   (loc_moving)
    );

    wire signed [15:0] duty;         // -10000..10000
    wire signed [15:0] alpha;        // centideg, 0 = rod up (debug)
    wire signed [15:0] adot_dbg;     // centideg/s (telemetry)
    wire [2:0]         ctrl_mode;    // 0 STOP, 1 JUDGE, 2 PUMP, 3 BAL (debug)
    wire               ctrl_en;      // 0 = interlocked
    wire               ctrl_wdog;    // 1 = saturation watchdog release window
    wire [13:0]        duty_mag;     // 0..10000 after motor front-end
    wire               braking;      // 1 = short brake held

    pendulum_ctrl #(
        .ANG_OFFSET (2057),     // 2026-10-24 new-board 3-pose calib: upright median 2057
                                // (hanging = 0 = travel end-stop, upright span 37)
        .ANG_INVERT (1'b0),     // bench: invert=1 breaks swing-up entirely, so 0 is right
        .CENTER_WIN (4100),     // +/-40.6 deg = reference CENTER_RANGE 500 cnt
        .PUMP_DUTY  (6000),     // 60 % judge pump.  Bench 10-07: at 45 % the
                                // envelope stalled at 158 deg (injection ==
                                // dissipation); raise per-run energy.
        .PULSE_MS   (90),       // 4x90 = 360 ms pump cycle.  HISTORY: 130 ms
                                // (520 ms cycle) was tuned for the HEAVY rod,
                                // where the long-angle half period was ~660 ms.
                                // The rod was lightened on 2026-10-11, which
                                // raises the swing frequency and SHORTENS the
                                // half period -- a 520 ms cycle then lands
                                // past the half period and every pump fires at
                                // the wrong phase, so net energy injection
                                // collapses to ~0 and the envelope stalls
                                // short of vertical (that is the "never
                                // reaches 180 deg" symptom).  360 ms keeps the
                                // cycle below one half period with margin at
                                // every angle above ~60 deg.  Bench 10-07:
                                // 4x150 ms (600 ms) locked the rod in a
                                // -65..-99 deg limit ring for 88 s -- the same
                                // over-long-cycle failure mode, confirmed.
        .POS_TRIM   (1000),     // was 2000: tlm_run3's 6.9 s BALANCE died of
                                // POSITION-LOOP SATURATION -- enc drifted
                                // -452 counts while the loop clamp pinned
                                // ang_sp at -20 deg, so the rod balanced at
                                // +35 deg instead of vertical; a full-output
                                // swing then pushed it past +68 deg and out.
                                // Halving the clamp lets the angle loop hold
                                // the rod near vertical; the position loop
                                // stays a slow outer trim.  (RTL default
                                // still 2000, ctrl_tb context untouched.)
        .DUTY_LIM   (10000),    // back to full authority (2026-10-07): the
                                // 3000 cap was a band-aid for the ground-bounce
                                // alpha corruption, which the alpha slew limiter
                                // now handles properly.  Bench: captures now
                                // land in-window every run, but BAL at
                                // soft-start*3000 = 1500 (15 %) cannot fight
                                // gravity -- the rod free-falls out at
                                // ~210 deg/s.  Full torque + 100 ms soft start
                                // retained.
        //
        // ---- 2026-10-24 jitter retune: JiangXie V1.1 factory equivalents ----
        // The old RTL defaults (Kp 1.85 / Kd 18 / pos 40|400) were bench-stiff
        // on the GLITCHY old-board ADC; on the clean new board (2026-10-24
        // 3-pose span 37) they pump a +/-15 deg limit cycle: run1/run3 BAL
        // alpha std ~1550 cdeg, with 30 deg/20 ms jumps -- far past the rod's
        // physical speed, i.e. loop-induced arm chatter.  Same motor, same
        // pot, same 5 ms/50 ms ticks as the reference kit, so drop in the
        // factory set ("no retune needed after ship"), unit-converted:
        //   angle: duty_x100/cdeg = PWM_per_count * 100 / 8.12988
        //          (8.12988 cdeg per ADC count = 33300/4096)
        //   position: cdeg/count  = counts_per_count * 8.12988
        .KP_ANG     (32'sd201528),   // 3.075  = 0.25  PWM/cnt  (was 1.85)
        .KI_ANG     (32'sd7255),     // 0.1107 = 0.009 PWM/cnt  (was 0.0615)
        .KD_ANG     (32'sd330506),   // 5.043  = 0.41  PWM/cnt  (was 18 = 3.6x)
        .KP_POS     (32'sd277056),   // 4.228 cdeg/cnt = 0.52   (was 40 = 9.5x)
        .KD_POS     (32'sd2429568)   // 37.07 cdeg/cnt = 4.56   (was 400 = 10.8x)
    ) u_ctrl (
        .clk      (sys_clk),
        .rst_n    (rst_n),
        .tick_1k  (tick),
        .key_run  (key1),       // press toggles run; next press stops
        .link_ok  (link_ok),
        .adc      (adc),
        .enc_pos  (enc_pos),
        .loc_target (loc_target),
        .duty     (duty),
        .enable   (ctrl_en),
        .alpha    (alpha),
        .adot_dbg (adot_dbg),
        .wdog     (ctrl_wdog),
        .mode     (ctrl_mode)
    );

    // motor front-end: signed duty -> TB6612 (brake-aware, min-drive)
    motor_driver #(
        .DEADBAND (80)          // 0.8 % min-drive lift (JiangXie "PWM offset").
                                // 2026-10-25 bench: 150 (1.5 %) left a 0.18 s
                                // period high-frequency wobble (JiangXie pid-3:
                                // "offset too LARGE -> high-frequency wobble");
                                // halve the over-zero torque step.  Was 150 as
                                // a pure deadband-to-brake before the rework.
    ) u_motor (
        .clk      (sys_clk),
        .rst_n    (rst_n),
        .enable   (ctrl_en),
        .duty_in  (duty),
        .duty_mag (duty_mag),
        .AIN1     (AIN1),
        .AIN2     (AIN2),
        .braking  (braking)
    );

    // PWM magnitude = duty_mag from the motor front-end
    pwm_gen #(
        .CLK_FREQ (50_000_000),
        .PWM_FREQ (20_000)
    ) u_pwm_gen (
        .clk       (sys_clk),
        .rst_n     (rst_n),
        .duty_x100 (duty_mag),
        .pwm_out   (PWMA)
    );

    // ------------------------------------------------------------------
    // 1-digit common-anode 7-segment display, DECIMAL:
    //   link dead -> "-"
    //   SHOW_ENC=1 (bring-up): encoder zone 0..9, 1 rev = 408 counts split
    //              into 10 zones of ~41 counts (36 deg of arm each);
    //              DP segment LIT to mark "this digit is the encoder".
    //   SHOW_ENC=0: pendulum angle zone 0..9 (33.3 deg each), DP off.
    // ------------------------------------------------------------------
    localparam SHOW_ENC = 1;    // set 0 after bring-up to show alpha again

    // encoder zone walker (extracted to enc_zone.v -- signedness-trap history)
    wire [3:0] ezone;
    enc_zone #(
        .ZONE     (41),
        .ZONE_MAX (9)
    ) u_ezone (
        .clk   (sys_clk),
        .rst_n (rst_n),
        .pos   (enc_pos),
        .ezone (ezone)
    );

    // display refresh: sample the zone sources at 4 Hz.  Feeding the tube a
    // live value paints a superposition of digits while the arm spins
    // (persistence of vision); a latched snapshot stays readable.
    reg [24:0] disp_cnt;
    reg [3:0]  ezone_disp;
    reg [3:0]  zone_disp;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            disp_cnt   <= 25'd0;
            ezone_disp <= 4'd0;
            zone_disp  <= 4'd4;             // alpha 0 -> middle zone
        end
        else if (disp_cnt >= 25'd12_499_999) begin   // 0.25 s
            disp_cnt   <= 25'd0;
            ezone_disp <= ezone;
            zone_disp  <= zone;
        end
        else begin
            disp_cnt <= disp_cnt + 25'd1;
        end
    end

    reg [7:0] seg_r;
    reg [3:0] zone;

    always @(*) begin
        // alpha zone = (alpha + 16650) / 3330, 0..9 -- comparator ladder
        if      (alpha < -16'sd13320) zone = 4'd0;
        else if (alpha <  -16'sd9990) zone = 4'd1;
        else if (alpha <  -16'sd6660) zone = 4'd2;
        else if (alpha <  -16'sd3330) zone = 4'd3;
        else if (alpha <   16'sd0)    zone = 4'd4;
        else if (alpha <   16'sd3330) zone = 4'd5;
        else if (alpha <   16'sd6660) zone = 4'd6;
        else if (alpha <   16'sd9990) zone = 4'd7;
        else if (alpha <   16'sd13320) zone = 4'd8;
        else                           zone = 4'd9;
    end

    always @(*) begin
        if (!link_ok) begin
            seg_r[6:0] = 7'b011_1111;           // only segment G -> "-"
            seg_r[7]   = 1'b1;                  // DP off
        end
        else if (SHOW_ENC != 0) begin
            seg_r[7] = 1'b0;                    // DP LIT: encoder zone
            case (ezone_disp)
                4'd0: seg_r[6:0] = 7'b100_0000;
                4'd1: seg_r[6:0] = 7'b100_1111;
                4'd2: seg_r[6:0] = 7'b010_0100;
                4'd3: seg_r[6:0] = 7'b011_0000;
                4'd4: seg_r[6:0] = 7'b001_1001;
                4'd5: seg_r[6:0] = 7'b001_0010;
                4'd6: seg_r[6:0] = 7'b000_0010;
                4'd7: seg_r[6:0] = 7'b111_1000;
                4'd8: seg_r[6:0] = 7'b000_0000;
                default: seg_r[6:0] = 7'b001_0000;
            endcase
        end
        else begin
            seg_r[7] = 1'b1;                    // DP off: alpha zone
            case (zone_disp)
                4'd0: seg_r[6:0] = 7'b100_0000;
                4'd1: seg_r[6:0] = 7'b100_1111;
                4'd2: seg_r[6:0] = 7'b010_0100;
                4'd3: seg_r[6:0] = 7'b011_0000;
                4'd4: seg_r[6:0] = 7'b001_1001;
                4'd5: seg_r[6:0] = 7'b001_0010;
                4'd6: seg_r[6:0] = 7'b000_0010;
                4'd7: seg_r[6:0] = 7'b111_1000;
                4'd8: seg_r[6:0] = 7'b000_0000;
                default: seg_r[6:0] = 7'b001_0000;
            endcase
        end
    end

    assign seg = seg_r;

    // ------------------------------------------------------------------
    // Telemetry: 15-byte binary frame at 50 Hz on the on-board UART
    // (F12 -> FTDI channel B -> PC COM9).  Was `assign uart_txd = 1'b1;`
    // (idle high, silent) so the bench had no data channel at all.
    // Frame layout: see src/telemetry.v.
    // ------------------------------------------------------------------
    // SPI frame counter: at 20 kSPS it advances ~400 per telemetry frame, so a
    // stall of the FPGA<->GD32 link is directly visible on the PC even while
    // `adc` keeps returning its last value (measured 2026-10-05).
    reg [15:0] spi_frames;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)                    spi_frames <= 16'd0;
        else if (adc_frame)            spi_frames <= spi_frames + 16'd1;
    end

    telemetry #(
        .RATE_HZ (50)
    ) u_tlm (
        .clk      (sys_clk),
        .rst_n    (rst_n),
        .tick_1k  (tick),
        .mode     (ctrl_mode),
        .link_ok  (link_ok),
        .enable   (ctrl_en),
        .braking  (braking),
        .key1     (key1),
        .wdog     (ctrl_wdog),
        .alpha    (alpha),
        .adot     (adot_dbg),
        .duty     (duty),
        .adc      (adc),
        .enc_pos  (enc_pos),
        .frames   (spi_frames),
        .uart_txd (uart_txd)
    );

endmodule
