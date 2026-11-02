`timescale 1ns/1ps
// ============================================================================
// pendulum_ctrl.v -- Furuta pendulum control: faithful RTL port of the proven
//                    江协 16-倒立摆-自动启摆 state machine + same-cycle
//                    safety interlock + TOGGLE key semantics
//                    (按一下=启动自动起摆/再按一下=停止).
//
//   Reference behaviour (STM32, verified on THIS mechanics):
//     * 1 ms master tick (our tick_1k)
//     * STOP      : PWM = 0
//     * JUDGE     : every 40 ms, take an angle sample (3-tap history):
//         - 3 consecutive samples outside CENTER_WIN with the MIDDLE one a
//           local extremum -> the rod just peaked on that side -> apply a
//           double pump pulse pair (+P, wait, -P, wait), each PULSE_MS long
//         - 2 consecutive samples inside CENTER_WIN -> zero the position
//           counter and both PID integrators -> BALANCE
//     * BALANCE   : angle PID 200 Hz (target = center), position PID 20 Hz
//                   in RAW ENCODER COUNTS (sp = loc_target, fb = enc-base),
//                   whose output SUBTRACTS from the center to form the angle
//                   target; rod leaving CENTER_WIN -> STOP
//     * Key press -> toggle run; entering run fires the first pump pulse
//       (escapes the potentiometer's 27-deg dead zone, ref state 21)
//     * Falling while balancing powers the machine OFF (clean restart)
//
//   Units: alpha is signed centideg, 0 = rod vertical-up; the reference's
//   CENTER_RANGE (500 pot counts) maps to ~4065 centideg -> CENTER_WIN.
//   Gains are CONVERTED from reference units (duty% per pot-count) to ours
//   (duty_x100 per centideg): x100 output scale, /8.13 count->cdeg scale.
//
//   Safety interlock (combinational, same cycle): !run || !link_ok || STOP
//   -> duty 0 + enable 0 (motor_driver short-brakes).
// ============================================================================
module pendulum_ctrl #(
    // ---- angle calibration ----
    parameter integer ANG_OFFSET  = 1988,     // adc counts at rod vertical-up
    parameter         ANG_INVERT  = 1'b0,     // flip alpha sign if needed
    parameter integer CENTER_WIN  = 4100,     // capture window (+/-40.6 deg)
    parameter integer FALL_WIN    = 7000,     // fall-detect window (+/-70 deg):
                                              // was 5500 -- bench 10-07: a
                                              // rescued rod swung back over
                                              // vertical and peaked at +49 deg
                                              // (alive!) before tripping out at
                                              // +55.8 deg.  The wider window is
                                              // pure over swing margin; the
                                              // stop is protection only.
    parameter integer PUMP_DUTY   = 3000,     // 30 % judge-pump amplitude
    parameter integer FIRST_PUMP  = 4500,     // 45 % first pump (breaks the dead zone)
    parameter integer PULSE_MS    = 100,      // pump pulse / wait length
    parameter integer POS_TRIM    = 2000,     // position loop clamp, duty_x100
    parameter integer DUTY_LIM    = 10000,    // angle loop clamp, duty_x100
    parameter integer WATCH_MS    = 400,      // saturation watchdog: consecutive
                                              // ms of FULL-authority balance
                                              // output before the release window
                                              // fires (anti-centrifugal-lock)
    parameter integer REL_MS      = 60,       // release window length: output
                                              // forced to 0 (motor short-brakes)
                                              // this long, then the watchdog
                                              // re-arms.  WATCH_MS<=1023,
                                              // REL_MS<=127 (counter widths)
    parameter integer GLITCH_HOLD_MS = 200,   // ADC-glitch freeze timeout: while
                                              // the raw-vs-alpha jump exceeds the
                                              // slew budget the sample is a
                                              // glitch (see the slew block),
                                              // alpha freezes; if the jump
                                              // persists longer than this the
                                              // limiter gives up and follows
                                              // like before (no permanent freeze)
    parameter integer SLEW_BUDGET  = 2000,   // cdeg/ms: per-tick |d_alpha| above
                                             // this = glitch.  Physics caps the
                                             // rod at ~300 deg/s = 30 cdeg/ms,
                                             // so 100 still tracks every real
                                             // motion with 3x margin.
                                             // 2026-10-31: LOWERING this does
                                             // NOT help.  The end-stop bounce
                                             // is ~315 cdeg/ms, so 400 "should"
                                             // reject it -- but 400 also caught
                                             // genuine swings, and because the
                                             // SAME budget caps the follow rate
                                             // alpha then hung: 16.8% frozen
                                             // frames at 400 and 41.4% at 100,
                                             // versus 12.5% at 2000.  Leave it.
    parameter integer PEAK_VMIN    = 0,       // cdeg/s minimum speed on the
                                              // losing side of the adot sign
                                              // flip for a judge pump.
                                              // 2026-10-25 RETUNE FROM THE
                                              // 10-24 SUCCESS RECORDS: their
                                              // winning pumps (#1/#2/#3/#5 in
                                              // factory_run1, ALL THREE in
                                              // run3) fired at adot 68~1462 --
                                              // near-still "retry pumps" at
                                              // the hanging rest position.
                                              // The swing-up WORKS by repeated
                                              // relaunches (rod flung to
                                              // ~150 deg, overshoots the top,
                                              // decays, hangs still, gets
                                              // pumped again) until one
                                              // launch crosses the top slow
                                              // enough to capture.  The old
                                              // 2000 threshold killed every
                                              // retry pump -> one overshoot,
                                              // dead hang, no relaunch, 0/23.
                                              // False peaks (dropout-bounce
                                              // sign flapping) are already
                                              // excluded by the trusted
                                              // judge-sampling gate -- that
                                              // one is doing the real work.
    parameter integer CLEAN_MS     = 60,      // ms of glitch-free signal
                                              // required before JUDGE->BAL
                                              // capture: spans the 40 ms adot
                                              // window + one judge interval,
                                              // so every input of the capture
                                              // decision is real.  Physics
                                              // helps ("slow arm = contact
                                              // good, fast arm = contact
                                              // lost"): at a genuine catch
                                              // the rod is slow and the arm
                                              // is slowing, so tens of clean
                                              // ms always back it.
    parameter integer DEAD_MS      = 120,     // ms of CONTINUOUS dropout in
                                              // BALANCE before the run is
                                              // killed.  A clean balance
                                              // never trips this (stop-state
                                              // span ~300 cdeg vs the 2000
                                              // cdeg/ms budget); a dead link
                                              // freezes alpha and the motor
                                              // would spin blind until the
                                              // freeze timeout walks alpha
                                              // out of the fall window --
                                              // this gate stops first, so it
                                              // is kept BELOW GLITCH_HOLD_MS.
    parameter integer JUDGE_MS     = 1200,    // 2026-10-28: JUDGE used to have
                                              // exactly two exits -- a detected
                                              // peak or a capture.  A rod
                                              // hanging dead still never flips
                                              // adot's sign, so no peak ever
                                              // fires and the FSM sat in JUDGE
                                              // for seconds with the rod down
                                              // (bench 10-28: 85 s of JUDGE,
                                              // duty=0, zero pumps).  After this
                                              // long without a peak, fire a
                                              // retry pump on the side the rod
                                              // hangs.
    parameter integer CAPT_NEAR    = 1200,    // cdeg: with the rod INSIDE this
                                              // offset of vertical, any legal
                                              // capture may proceed.  Beyond
                                              // it the entry must be a "catch"
                                              // -- see CAPT_LIVE.  (Bench
                                              // 10-25 run4: a still rod
                                              // captured at -19.7 deg; the P
                                              // term then slammed the arm,
                                              // the light rod did not follow,
                                              // and the RELATIVE angle was
                                              // dragged out of the fall
                                              // window in 0.17 s.  run3
                                              // entered at -20.5 deg WITH
                                              // -107 deg/s of rod motion and
                                              // converged -- a moving rod can
                                              // be caught, a parked rod at
                                              // large offset cannot be
                                              // carried up.)
    parameter integer CAPT_LIVE    = 500,     // cdeg/s: beyond CAPT_NEAR the
                                              // rod must be moving at least
                                              // this fast (either direction)
                                              // for the capture to fire.
    parameter integer CAPT_SPEED_P = 3000,    // cdeg/s: the rod must be slower
                                              // than this INSIDE the window to
                                              // be captured.  2026-10-30 bench
                                              // (cap_151712): 185 pumps / 661
                                              // window crossings, median
                                              // crossing speed 13565 cdeg/s --
                                              // the rod NEVER decelerates to
                                              // 3000 any more (the 10-28 run
                                              // still had a decaying crossing
                                              // at 10619 -> -6192, and that is
                                              // what got caught).  The 3000
                                              // gate therefore rejected every
                                              // single crossing.  Raised to
                                              // 18000 so a fast pass-through
                                              // can be caught; the balance loop
                                              // then has to arrest it.
    parameter integer KEY_LOCK_MS  = 1000,    // after a toggle, further key
                                              // edges are IGNORED this long.
                                              // The KEY1 switch drops contact
                                              // ~150 ms after a press (bench
                                              // 10-25 run6: three fresh starts
                                              // killed 150-160 ms in by a
                                              // phantom second edge -- same
                                              // contact family as the 10-24
                                              // "KEY1 self-trigger" events);
                                              // run/stop must not flap on it.
    parameter integer KEY_DEB_MS   = 30,      // KEY1 must HOLD its new level
                                              // this long before the edge
                                              // counts.  2026-11-02: the lock
                                              // above only covers 1 s after a
                                              // toggle, so the 30th second of
                                              // a balance is fair game for
                                              // contact chatter -- bench
                                              // base_183329 dropped out of
                                              // BALANCE at alpha +1.4 deg
                                              // with link=1 and wdog=0, i.e.
                                              // a run_latch flip, not a fault.
                                              // Chatter is a few ms; a real
                                              // press is >100 ms.

    // ---- loop gains (Q16.16), CONVERTED from 江协 reference units ----
    // 2026-10-07 bench retune #2: Kp halved (3.69 -> 1.85).  With full Kp a
    // mere -18 deg error already commanded 66 % duty; together with the I
    // term the arm spun up and centrifugal force pinned the rod at -18 deg
    // for 1.5 s (enc +4366 counts, alpha frozen).  Half Kp keeps the stiffness
    // against a falling rod while the spinning-arm trap stays out of reach;
    // the large Kd (12.2) carries the damping that was proven on bench.
    parameter signed [31:0] KP_ANG = 32'sd121241,   // 1.85
    parameter signed [31:0] KI_ANG = 32'sd4031,     // 0.0615
    parameter signed [31:0] KD_ANG = 32'sd1179648,  // 18 = 4.5x reference:
                                                    // 12.2 still let a 258 deg/s
                                                    // return swing overshoot
                                                    // (bench 10-07 round 13)
    parameter signed [31:0] KP_POS = 32'sd2621440,  // 0.40*100      = 40 /cnt
    parameter signed [31:0] KD_POS = 32'sd26214400, // 4.00*100       = 400 /cnt
    // ---- 2026-10-26 jitter / levelling (see pid.v D_SHIFT, I_BAND) ----
    parameter signed [31:0] KI_POS     = 32'sd0,    // position integral,
                                                    // cdeg/cnt per 50 ms tick.
                                                    // 江协 V1.1 factory: 0.01
                                                    // PWM/cnt -> x8.12988 =
                                                    // 0.0813 -> Q16.16 5328.
                                                    // Removes the PD droop
                                                    // that left the rod a fixed
                                                    // ~1 deg off vertical after
                                                    // every position move.
    parameter integer POS_I_BAND  = 100,   // integral separation, counts
                                           // (江协 position loop threshold):
                                           // ramping/moving errors are large
                                           // and must NOT wind the integral;
                                           // only the last <100 counts trim.
    parameter integer D_SHIFT_ANG = 0,     // angle-loop D smoothing (ticks,
                                           // 200 Hz -> 2^N*5 ms).  1 = 10 ms
                                           // tau: removes the ADC-quantisation
                                           // noise path that pumps the 0.18 s
                                           // limit cycle, 18 deg lag at 5.5 Hz.
    parameter integer D_SHIFT_POS = 0      // position-loop D smoothing.  Keep
                                           // 0: its D term is the ramp damper
                                           // (KD_POS 37 at 20 Hz), and a 100 ms
                                           // tau would let the move overshoot.
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick_1k,     // 1 kHz master tick
    input  wire        key_run,     // active low; press edge TOGGLES run
    input  wire        link_ok,     // GD32 SPI link health
    input  wire [11:0] adc,         // raw angle potentiometer value
    input  wire signed [31:0] enc_pos,
    input  wire signed [31:0] loc_target,    // position target, counts
    output reg  signed [15:0] duty,          // -10000..10000 (duty_x100)
    output wire        enable,               // 0 = interlocked (kill)
    output wire signed [15:0] alpha,         // centideg, 0 = rod up (debug)
    output wire signed [15:0] adot_dbg,      // centideg/s (telemetry, debug)
    output wire        wdog,                // 1 = saturation watchdog release
                                            //     window active (telemetry)
    output wire [2:0]  mode            // 0 STOP 1 JUDGE 2 PUMP 3 BAL (debug)
);
    localparam [11:0] ANG_OFF_W = ANG_OFFSET;
    localparam [15:0] PUMP_W    = PUMP_DUTY;
    localparam signed [31:0] POS_TRIM_S = POS_TRIM;
    localparam signed [31:0] DUTY_LIM_S = DUTY_LIM;
    localparam signed [15:0] DUTY_LIM_W = DUTY_LIM;   // equal-width relays (trap 9:
    localparam [9:0]         WATCH_W    = WATCH_MS;   // no part-select on
    localparam [6:0]         REL_W      = REL_MS;     // parameters)
    localparam signed [31:0] WIN_S      = CENTER_WIN;
    localparam signed [31:0] FWIN_S     = FALL_WIN;

    // Declarations hoisted above their first use.  Icarus Verilog rejects
    // use-before-declaration outright, while Gowin silently tolerates it --
    // which is exactly how the missing tick strobes below went unnoticed.
    localparam [2:0] M_STOP = 3'd0, M_JUDGE = 3'd1, M_PUMP = 3'd2, M_BAL = 3'd3;
    wire signed [15:0] adot;        // driven by u_adot, declared up here
    reg        pump_big;            // 1 = first pump at FIRST_PUMP

    // ------------------------------------------------------- tick strobes --
    // Loop-rate strobes derived from the 1 kHz master tick.
    // BUGFIX 2026-10-05: tick_200 / tick_20 were referenced by both PIDs and
    // by alpha_dot but were never driven anywhere in the project.  Gowin tied
    // them to 0, swept u_ang_pid / u_pos_pid / u_adot in optimization, so the
    // BALANCE state applied ZERO torque (the motor just braked).  Evidence:
    // synthesis log "Net 'tick_200' does not have a driver" + "swept in
    // optimizing"; A/B probe D:\_fpga_verify\bal_probe_tb.v gives
    // max|duty| in BALANCE = 0 without this block, non-zero with it.
    reg [2:0] d200;
    reg [5:0] d20;
    reg       t200_r, t20_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d200 <= 3'd0; d20 <= 6'd0; t200_r <= 1'b0; t20_r <= 1'b0;
        end
        else begin
            t200_r <= 1'b0;
            t20_r  <= 1'b0;
            if (tick_1k) begin
                if (d200 == 3'd4)  begin d200 <= 3'd0; t200_r <= 1'b1; end
                else                    d200 <= d200 + 3'd1;
                if (d20  == 6'd49) begin d20  <= 6'd0; t20_r <= 1'b1; end
                else                    d20  <= d20  + 6'd1;
            end
        end
    end
    wire tick_200 = t200_r;         // 200 Hz angle loop
    wire tick_20  = t20_r;          //  20 Hz position loop

    // ------------------------------------------------------- angle scaling --
    wire signed [12:0] adc_s = {1'b0, adc};
    wire signed [12:0] off_s = {1'b0, ANG_OFF_W};
    wire signed [12:0] adc_diff = ANG_INVERT ? (off_s - adc_s) : (adc_s - off_s);
    // ---- 2026-10-31: WRAP TRIED AND SHELVED ---------------------------
    // Folding the difference into +-2048 does unify the two end-stop
    // readings (adc 0 and 4095 are the same physical point), and balance
    // did get steadier with it.  But alpha_r has to SLEW to the new value
    // at 20 deg/ms, so every end-stop bounce drags it through 332 deg of
    // positions the rod never occupied: adc<200 showed 635 frames heading
    // negative and 1217 positive, and swing-up fell from ~2-4 s to 4-10 s.
    // Kept here (unused) as the reference implementation; the A/B test
    // below decides whether to re-enable it.
    // wire signed [13:0] diff_w = (adc_diff > 13'sd2048)  ? (adc_diff - 14'sd4096) :
    //                             (adc_diff < -13'sd2048) ? (adc_diff + 14'sd4096) :
    //                             adc_diff;
    wire signed [31:0] alpha_full = (adc_diff * 32'sd33300) >>> 12;
    wire signed [31:0] alpha_cl = (alpha_full > 32'sd32000)  ? 32'sd32000  :
                                  (alpha_full < -32'sd32000) ? -32'sd32000 :
                                  alpha_full;
    // BUGFIX/TIMING 2026-10-05: alpha used to be pure combinational all the
    // way from the ADC flop.  The 50 MHz critical path then ran
    //   adc -> alpha (32-bit multiply + 32-bit clamp mux) -> PID err ->
    //   err*KP -> integrator 32-bit add -> clamp -> sum -> clamp -> out
    // = 35.05 ns vs the 24.32 ns allowed (slack -10.73 ns), i.e. the balance
    // loop sampled potentially wrong values every 5 ms tick.
    // Registering alpha cuts the chain in two 12.2 ns / 15.8 ns halves.
    // A one-clock (20 ns) delay of the angle is invisible to the 1 kHz FSM,
    // the 200 Hz angle loop and the 4 Hz display latch.
    //
    // SLEW LIMIT 2026-10-07 (bench: capture -> next frame alpha at -16585 =
    // adc 0): a motor-start surge bends the shared ground for ~1 ms and the
    // GD32 filter escapes to the bogus 0, then crawls back for a full 20 ms
    // telemetry frame.  Physics caps the rod at ~300 deg/s; slewing at
    // 400 cdeg per 1 kHz tick lets real motion through untouched while a
    // one-frame ADC glitch becomes a smooth 40 ms ramp instead of a step
    // that trips outside_fall and kills the run.
    //
    // GLITCH FREEZE 2026-10-11 (bench tlm_run1, 154 ADC jumps > 65 deg/frame
    // in 120 s -- 0 <-> 4095 endpoint slams, present even at duty=0, so NOT
    // purely motor ground-bounce).  The 10-07 ramp behaviour turned out
    // to be the single biggest loss source: the fake 4000 deg/s ramp (a)
    // walks THROUGH the capture window while the 40 ms adot estimator still
    // reads "slow" -> false capture (24 of 28 BALANCE entries were this,
    // dying 20 ms later), and (b) drags alpha out of the fall window mid
    // balance (the 28.1 s run died exactly this way: frame 3291 rod alive at
    // +9.75 deg, duty 3574 rescuing; frame 3292 adc 2162 -> 5, fake ramp,
    // stop).
    //   The jump budget is the discriminator: real motion needs <= ~30 cdeg
    // per 1 ms tick (300 deg/s), while |d_alpha| > 400 cdeg only happens on a
    // glitch (13x margin).  So: on a jump, FREEZE alpha (no fake trajectory,
    // no false capture, no false fall-out, PID and judge see the last true
    // value).  If the jump persists > GLITCH_HOLD_MS the limiter gives up
    // and follows the old way -- a dead ADC must not freeze control forever.
    reg signed [15:0] alpha_r;
    reg [7:0]         hold_ms;                  // consecutive jumped ms
    // Signal-trust accounting (updated once per 1 kHz sample in the alpha
    // block below).  mode_r is hoisted HERE because these counters read it
    // and Icarus rejects use-before-declaration (see the note at the top).
    reg [2:0]         mode_r;                   // FSM state (written in the
                                                // mode-FSM block)
    reg               trusted_r;                // last 1 ms sample was clean
    reg [6:0]         clean_ms;                 // consecutive clean ms (cap 127)
    reg [9:0]         dead_ms;                  // BAL: continuous dropout ms
    localparam signed [15:0] PEAK_VMIN_S = PEAK_VMIN;   // equal-width relays
    localparam [6:0]         CLEAN_W    = CLEAN_MS;     // (trap 9: no
    localparam [9:0]         DEAD_W     = DEAD_MS;      // part-selects)
    localparam signed [15:0] BUDGET = SLEW_BUDGET;   // equal-width relay (trap 9)
    wire signed [15:0] d_alpha  = alpha_cl[15:0] - alpha_r;
    wire               jumped   = (d_alpha >  BUDGET) || (d_alpha < -BUDGET);
    localparam [7:0]   HOLD_W   = GLITCH_HOLD_MS;   // equal-width relay (trap 9)
    wire               follow   = !jumped || (hold_ms >= HOLD_W);
    wire signed [15:0] d_step   = (d_alpha >  BUDGET) ?  BUDGET :
                                  (d_alpha < -BUDGET) ? -BUDGET :
                                  d_alpha;
    // sample-vs-display agreement: only when alpha has converged onto the
    // live adc value is the pair trustworthy.  Used to gate JUDGE->BAL
    // capture (below) -- during a freeze the display holds the last true
    // value while adc sits at an endpoint, |d_alpha| is huge, and an
    // "in window + adot decayed" coincidence must NOT capture (tlm_run2:
    // freeze-in-window false captures, segments 1807 and 5003).
    localparam signed [15:0] LOCK = 16'sd800;
    wire alpha_locked = (d_alpha > -LOCK) && (d_alpha < LOCK);
    reg               tick_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alpha_r   <= 16'sd0;
            tick_d    <= 1'b0;
            hold_ms   <= 8'd0;
            trusted_r <= 1'b1;
            clean_ms  <= 7'd0;
            dead_ms   <= 10'd0;
        end
        else begin
            tick_d <= tick_1k;                  // one slew step per 1 kHz tick
            if (tick_1k && !tick_d) begin
                trusted_r <= !jumped;
                if (jumped) begin
                    if (hold_ms != 8'd255) hold_ms <= hold_ms + 8'd1;
                    if (follow) alpha_r <= alpha_r + d_step;   // timeout: follow
                    clean_ms <= 7'd0;
                    // dropout while balancing: count toward the DEAD_MS kill
                    // (outside BALANCE a jump just resets the clean streak)
                    if (mode_r == M_BAL && dead_ms != 10'd1023)
                        dead_ms <= dead_ms + 10'd1;
                end
                else begin
                    hold_ms <= 8'd0;
                    alpha_r <= alpha_r + d_step;
                    if (clean_ms != 7'd127) clean_ms <= clean_ms + 7'd1;
                    dead_ms <= 10'd0;
                end
            end
        end
    end
    assign alpha = alpha_r;

    // ------------------------------------------------------- key toggle ----
    // (mode_r is declared up with the trust counters -- see above)
    reg        key_d;                    // DEBOUNCED key delayed (edge detect)
    reg        run_latch;                // 按一下=启动/再按一下=停止
    reg        start_req;                // press -> start, consumed by FSM
    reg [2:0]  mode_d;
    // 2026-11-02 KEY1 level debounce (see KEY_DEB_MS): chatter of a few ms
    // used to reach the edge detector directly and flip run_latch mid-balance.
    reg [7:0]  key_deb;                  // ms key_run has disagreed
    reg        key_stable;               // debounced level (1 = released)
    localparam [7:0] KEY_DEB_W = KEY_DEB_MS;   // equal-width relay (trap 9)

    // BAL watchdog on signal death: continuous dropout for DEAD_MS kills the
    // run (clean stop; the next KEY1 press starts fresh).
    wire sig_dead = (mode_r == M_BAL) && (dead_ms >= DEAD_W);
    localparam [9:0] KEY_LOCK_W = KEY_LOCK_MS;   // equal-width relay (trap 9)
    localparam [15:0] JUDGE_W = JUDGE_MS;        // equal-width relay

    reg [9:0] key_lock;              // ms of key-lock remaining after a toggle

    wire inside_win   = (alpha > -WIN_S) && (alpha < WIN_S);
    wire outside_fall = (alpha > FWIN_S) || (alpha < -FWIN_S);
    // decelerating inside the window = catchable (near the top, physics
    // slows the rod there; a pass-through at pump speed is much faster)
    localparam signed [31:0] CAPT_SPEED = CAPT_SPEED_P;  // equal-width relay
                                                    // (trap 9).  18000 = 180
                                                    // deg/s on 10-30 (see the
                                                    // parameter comment).
                                                    // History: 3000 cdeg/s =
                                                    // 30 deg/s, was 8000
                                                    // (80 deg/s): the adot
                                                    // estimator's 40 ms window
                                                    // can't see a fast
                                                    // pass-through in time, and
                                                    // even a genuine 78 deg/s
                                                    // rod overswings past the
                                                    // fall window (bench 10-07:
                                                    // -46deg pulled back to
                                                    // -0.7deg at -258deg/s,
                                                    // then swung out at +83deg).
                                                    // That overswing risk is why
                                                    // the gate was tightened;
                                                    // the 10-30 data shows the
                                                    // rod now crosses at 135
                                                    // deg/s, i.e. the gate was
                                                    // rejecting everything.
    wire signed [31:0] adot_abs = (adot < 0) ? -adot : adot;
    wire signed [31:0] alpha_abs = (alpha < 0) ? -alpha : alpha;
    localparam signed [31:0] CAPT_NEAR_S = CAPT_NEAR;   // equal-width relays
    localparam signed [31:0] CAPT_LIVE_S = CAPT_LIVE;   // (trap 9)
    // capture entry class: near-vertical = safe at any speed; far from
    // vertical = only a moving (catchable) rod may enter BALANCE
    wire capt_ok = (alpha_abs <= CAPT_NEAR_S) || (adot_abs >= CAPT_LIVE_S);
    wire slow_in_win = inside_win && (adot_abs < CAPT_SPEED);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_d      <= 1'b1;
            key_stable <= 1'b1;         // KEY1 released (active low)
            key_deb    <= 8'd0;
            run_latch  <= 1'b0;
            start_req  <= 1'b0;
            key_lock   <= 10'd0;
        end
        else begin
            // ---- 2026-11-02: debounce the LEVEL before edge detection ----
            // Only a level that holds KEY_DEB_MS is allowed to reach key_d,
            // so contact chatter cannot manufacture a press edge.
            if (tick_1k) begin
                if (key_run == key_stable)
                    key_deb <= 8'd0;
                else if (key_deb >= KEY_DEB_W - 8'd1) begin
                    key_deb    <= 8'd0;
                    key_stable <= key_run;
                end
                else
                    key_deb <= key_deb + 8'd1;
            end
            key_d <= key_stable;
            if (tick_1k && key_lock != 10'd0)
                key_lock <= key_lock - 10'd1;
            // rod lost while balancing: power off clean (next press starts).
            // sig_dead: the angle link died mid-balance (slip ring / UART) --
            // alpha is frozen and the motor would run blind; stop instead.
            if ((mode_r == M_BAL && outside_fall) || sig_dead)
                run_latch <= 1'b0;
            else if (key_d == 1'b1 && key_stable == 1'b0 && key_lock == 10'd0) begin
                // press edge: toggle the machine; request start if turning ON.
                // key_lock swallows the phantom second edge the KEY1 contact
                // drops on us ~150 ms after a real press (see KEY_LOCK_MS).
                run_latch <= ~run_latch;
                start_req <= ~run_latch;
                key_lock  <= KEY_LOCK_W;
            end
            else if (start_req && mode_r != M_STOP)
                start_req <= 1'b0;    // FSM took it
        end
    end

    wire run = run_latch;                // FSM run level (latched)

    // ------------------------------------------------------- position counts --
    // Position loop runs in RAW ENCODER COUNTS like the reference (Location):
    // error = target(+/-4080 clamped) - location.  Base captured at balance
    // entry (reference zeroes Location there); feedback truncated to 16 bits
    // (safe while within 80 revs of the entry point).
    reg signed [31:0] enc_base;
    wire signed [31:0] pos_fb = enc_pos - enc_base;
    wire bal_entry = (mode_r == M_BAL) && (mode_d != M_BAL);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            enc_base <= 32'sd0;
        else if (bal_entry)
            enc_base <= enc_pos;              // zero Location on balance entry
    end

    // ------------------------------------------------------- mode FSM -------
    // (M_STOP..M_BAL are declared near the top -- use-before-declaration.)
    reg [1:0]  pump_ph;                  // 0:+pulse 1:+wait 2:-pulse 3:-wait
    reg [15:0] ms_cnt;                   // pulse/wait countdown
    reg [5:0]  judge_cnt;                // 40 ms judge divider
    reg [15:0] judge_ms;                 // ms spent in JUDGE without a peak
    reg signed [15:0] a0, a1, a2;        // angle history, 40 ms apart
    reg        a1_in_r;                  // previous judge sample inside win
    reg        peak_r;                   // rod peaked on the + side
    reg        peak_l;                   // rod peaked on the - side
    reg        center_in;                // 2 judge samples inside window
    reg  [1:0] sample_vld;               // judge samples collected since entry

    // ---- 2026-10-30 capture veto: refuse a FAST FALLING entry -----------
    // The `adot` estimator is a 40 ms window plus a one-pole low-pass, so a
    // rod dropping at ~690 deg/s reaches the gate as a few tens of deg/s and
    // `adot_abs >= CAPT_LIVE` (500 cdeg/s) is effectively always true.
    //
    // A 40 ms displacement (the judge samples a0/a1) is still too slow: bench
    // cap_205210 had a capture at -22.4 deg where the samples 40 ms apart
    // differed by only 0.72 deg, yet the rod reached -50.0 deg 20 ms later --
    // the acceleration happened AFTER the last sample.  8 ms of real motion
    // catches it (5.5 deg there, vs 0.44 deg for every entry that held).
    //
    // Veto = far from vertical AND moving AWAY from it AND displaced more
    // than FALL_V8 in the last 8 ms (= 500 deg/s).
    reg signed [15:0] ad8_0, ad8_1, ad8_2, ad8_3, ad8_4, ad8_5, ad8_6, ad8_7;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ad8_0 <= 16'sd0; ad8_1 <= 16'sd0; ad8_2 <= 16'sd0; ad8_3 <= 16'sd0;
            ad8_4 <= 16'sd0; ad8_5 <= 16'sd0; ad8_6 <= 16'sd0; ad8_7 <= 16'sd0;
        end
        else if (tick_1k) begin
            ad8_0 <= alpha_r; ad8_1 <= ad8_0; ad8_2 <= ad8_1; ad8_3 <= ad8_2;
            ad8_4 <= ad8_3; ad8_5 <= ad8_4; ad8_6 <= ad8_5; ad8_7 <= ad8_6;
        end
    end
    localparam signed [15:0] FALL_V8     = 16'sd250; // 2.5 deg / 8 ms = 312 deg/s
                                                     // 2026-10-30 cap_213204: one
                                                     // death slipped through at
                                                     // 4.7 deg / 8 ms against the
                                                     // old 4.0 deg threshold,
                                                     // while every entry that
                                                     // held was <= 1.44 deg.
    localparam signed [15:0] CAPT_NEAR_W = CAPT_NEAR; // equal-width relay (trap 9)
    wire signed [15:0] ad8_7_abs   = (ad8_7 < 16'sd0) ? -ad8_7 : ad8_7;
    wire signed [15:0] a_now_abs   = (alpha_r < 16'sd0) ? -alpha_r : alpha_r;
    wire signed [15:0] a_step8     = alpha_r - ad8_7;      // 8 ms displacement
    wire signed [15:0] a_step8_abs = (a_step8 < 16'sd0) ? -a_step8 : a_step8;
    wire               capt_veto   = (a_now_abs > CAPT_NEAR_W) &&   // far from vertical
                                     (a_now_abs > ad8_7_abs) &&     // moving away
                                     (a_step8_abs > FALL_V8);       // and fast

    // ---- 2026-10-30 judge retry-pump gating ------------------------------
    // A purely timed retry beats against the rod's own swing and sometimes
    // cancels it (cap_211538: 3 of 11 starts stalled at -104 -> -88 -> -115
    // deg).  Pump when the rod has settled (< 10 deg/s over 8 ms) at the
    // hanging side (> 80 deg from vertical); JUDGE_FORCE_W is the fallback so
    // a rod that never settles still gets nudged.
    localparam signed [15:0] ROD_STILL_V = 16'sd80;    // 0.8 deg / 8 ms
    localparam signed [15:0] ROD_DOWN_V  = 16'sd8000;  // 80 deg from vertical
    localparam [15:0]        JUDGE_FORCE_W = JUDGE_MS * 2;
    wire rod_still = (a_step8_abs < ROD_STILL_V);
    wire rod_down  = (alpha_r > ROD_DOWN_V) || (alpha_r < -ROD_DOWN_V);

    // Peak detection v2: position in the far zone + VELOCITY SIGN FLIP.
    // The 3-point extremum test aliases at high rod speed (peak falls
    // between two 40 ms samples: rise-rise-drop -> middle not an extremum
    // -> never pumps -> rod freewheels down, bench-observed).  Velocity
    // zero-crossing cannot alias: within 40 ms a crossing MUST show at
    // the sample nearest it.  adot is the existing alpha_dot estimator.
    reg signed [15:0] adot_prev_v;   // adot VALUE at the previous judge sample
    always @(*) begin
        // 2026-10-25 PEAK_VMIN: the bare sign flip fired on near-zero adot
        // noise (still-rod micro-sway / dropout decay) -- 46/64 pumps hit a
        // still rod.  The previous judge sample must also carry REAL speed
        // on the losing side of the flip; a genuine out-of-window peak is
        // always preceded by far more than PEAK_VMIN.
        peak_r = sample_vld == 2'd2 && (a0 > WIN_S) && (a1 > WIN_S) &&
                 adot_prev_v[15] && !adot[15] &&
                 (adot_prev_v <= -PEAK_VMIN_S);
                 // was falling hard, now rising => just peaked on + side
        peak_l = sample_vld == 2'd2 && (a0 < -WIN_S) && (a1 < -WIN_S) &&
                 !adot_prev_v[15] && adot[15] &&
                 (adot_prev_v >= PEAK_VMIN_S);
                 // was rising hard, now falling => peaked on the - side
        center_in = sample_vld >= 2'd1 && inside_win && a1_in_r;
    end

    // EVERYTHING in this block runs at the 1 kHz master tick -- the reference
    // executes its state machine in a 1 ms interrupt; without the tick gate
    // the pulse/judge timing would run 50000x too fast (bench bug).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_r    <= M_STOP;
            pump_ph   <= 2'd0;
            pump_big  <= 1'b0;
            ms_cnt    <= 16'd0;
            judge_cnt <= 6'd0;
            judge_ms  <= 16'd0;
            a0 <= 16'sd0; a1 <= 16'sd0; a2 <= 16'sd0;
            a1_in_r      <= 1'b0;
            adot_prev_v  <= 16'sd0;
            sample_vld   <= 2'd0;
            mode_d       <= 3'd0;
        end
        else if (tick_1k) begin
            mode_d <= mode_r;

            // angle history sampled every 40 ms while judging.  trusted_r
            // (2026-10-25): a dropout must not write fake angles/speeds into
            // the judge history -- it both forges peaks and poisons the
            // pump phase.
            if (mode_r == M_JUDGE && mode_d != M_JUDGE)
                sample_vld <= 2'd0;      // fresh history on judge entry
            else if (mode_r == M_JUDGE && judge_cnt == 6'd39 && trusted_r) begin
                a2          <= a1;
                a1          <= a0;
                a0          <= alpha;
                a1_in_r     <= inside_win;
                adot_prev_v <= adot;
                if (sample_vld != 2'd2) sample_vld <= sample_vld + 2'd1;
            end

            if (!run) begin
                mode_r <= M_STOP;                  // machine toggled off
            end
            else case (mode_r)
                M_STOP: begin
                    ms_cnt <= 16'd0;
                    if (start_req) begin
                        mode_r   <= M_PUMP;        // first pump (escapes the
                        pump_ph  <= 2'd0;          // pot dead zone), ref s21
                        pump_big <= 1'b1;          // at full breakaway force
                        ms_cnt   <= PULSE_MS[15:0];
                    end
                end
                M_JUDGE: begin
                    if (judge_cnt >= 6'd39) begin
                        judge_cnt <= 6'd0;
                    end
                    else               judge_cnt <= judge_cnt + 6'd1;
                    // pump side BINDING, matched to the reference: a peak
                    // on the adc>center side (our alpha>+WIN) pumps -duty,
                    // a peak on adc<center pumps +duty.  Swapping this pair
                    // mirrors the whole pump semantics (bench: arm spun one
                    // full revolution instead of rocking).
                    if (peak_r) begin
                        mode_r  <= M_PUMP; pump_ph <= 2'd2;
                        pump_big<= 1'b0;           // judge pumps are gentle:
                        ms_cnt  <= PULSE_MS[15:0]; // less speed through the window
                    end
                    else if (peak_l) begin
                        mode_r  <= M_PUMP; pump_ph <= 2'd0;
                        pump_big<= 1'b0;
                        ms_cnt  <= PULSE_MS[15:0];
                    end
                    else if (inside_win && slow_in_win && alpha_locked &&
                             (clean_ms >= CLEAN_W) && capt_ok && !capt_veto) begin
                        // capture = in window AND slow enough to hold AND the
                        // displayed angle agrees with the live sample.  A rod
                        // passing the window at pump speed (<=20 ms)
                        // must NOT be captured: the balance loop cannot
                        // fight that speed, it just trips the fall detector
                        // one tick later (bench: "moves once then stops").
                        // |adot| < CAPT_SPEED = decelerating near the top.
                        // alpha_locked (2026-10-11): during a glitch freeze
                        // the display can hold an in-window value while the
                        // adc sits far away -- capturing then hands the loop
                        // a frozen angle (tlm_run2 false captures).
                        // clean_ms >= CLEAN_MS (2026-10-25): the capture
                        // decision must be backed by glitch-free signal for
                        // the adot window + one judge interval -- the five
                        // 0.2 s-lived false captures of bench 10-24 slipped
                        // past alpha_locked during slip-ring dropout bounce.
                        mode_r <= M_BAL;
                    end
                    else if ((judge_ms >= JUDGE_W && rod_still && rod_down) ||
                             (judge_ms >= JUDGE_FORCE_W)) begin
                        // retry pump.  2026-10-30 bench (cap_211538): a
                        // PURELY TIMED retry (every 340+300 ms) beats against
                        // the rod's own swing and cancels its energy -- two
                        // starts climbed -104 -> -88 -> -115 deg (no growth)
                        // while two others climbed -107 -> -94 -> -84 and
                        // captured.  Wait for the rod to actually SETTLE at
                        // the hanging side before pushing again, so every pump
                        // lands on a rod at rest; the 2x timeout is the
                        // anti-stall fallback (a rod that never settles must
                        // still get nudged).
                        mode_r   <= M_PUMP;
                        pump_big <= 1'b0;
                        ms_cnt   <= PULSE_MS[15:0];
                        judge_ms <= 16'd0;
                        if (alpha > 16'sd0) pump_ph <= 2'd2;   // + side: -duty
                        else                pump_ph <= 2'd0;   // - side: +duty
                    end
                    else if (judge_ms != 16'hFFFF)
                        judge_ms <= judge_ms + 16'd1;
                end
                M_PUMP: begin
                    if (ms_cnt != 16'd0) ms_cnt <= ms_cnt - 16'd1;
                    else begin
                        // advance through: +P, wait, -P, wait -> JUDGE
                        if (pump_ph == 2'd3) begin
                            mode_r    <= M_JUDGE;
                            judge_cnt <= 6'd0;
                            judge_ms  <= 16'd0;
                            pump_big  <= 1'b0;
                        end
                        else begin
                            pump_ph <= pump_ph + 2'd1;
                            ms_cnt  <= PULSE_MS[15:0];
                        end
                    end
                end
                M_BAL: if (outside_fall) mode_r <= M_STOP;  // rod lost (wide
                                                             // window) -> stop
                default: mode_r <= M_STOP;
            endcase
        end
    end

    assign mode = mode_r;

    // ------------------------------------------------------- alpha_dot -----
    // pendulum angular velocity (sign+rate) -- seeds the balance D-term at
    // capture so it fights the rod speed from its very first tick
    // (adot is declared near the top -- use-before-declaration.)
    alpha_dot #(
        .K     (9),
        .SCALE (32'sd25)          // hardware: 200 Hz sampling, 40 ms window
    ) u_adot (
        .clk   (clk),
        .rst_n (rst_n),
        .tick  (tick_200),
        .alpha (alpha),
        .adot  (adot)
    );

    // telemetry tap (COM9): the speed estimator state is the only way to tell
    // a dead speed gate from a real capture decision
    assign adot_dbg = adot;

    // ------------------------------------------------------- loop enables --
    // Both PIDs run ONLY in BALANCE; a one-clock wipe on entry clears stale
    // integrators (the reference zeroes ErrorInt on center entry too).
    //
    // 2026-10-26: a glitch FREEZE must also freeze the loops.  While the
    // limiter holds alpha (jumped but not yet timed out) the held value is
    // the last true angle, NOT the current one -- running the PID on it made
    // a dropout look like a sudden 15-25 deg error and slammed duty to
    // +/-10000 for the whole freeze (bench kd775e: both BAL segments died
    // exactly this way -- alpha jumped and froze at +1528 / -2431, duty went
    // to full authority, rod thrown out).  Freezing the loops keeps the last
    // good output instead; if the dropout outlasts DEAD_MS the run stops
    // clean, and if it ends earlier the loops resume on real samples.
    wire glitch_hold = jumped && !follow;
    wire bal_en  = (mode_r == M_BAL) && !glitch_hold;
    wire bal_clr = (mode_r == M_BAL) && (mode_d != M_BAL);

    // D-term seed: one 5 ms tick worth of error-rate at capture.
    //   err = -alpha (+ slow pos trim);  d(err)/dt = -adot
    //   seed = -adot / 200 (5 ms)  -> arithmetic shift, sign-safe
    wire signed [15:0] d_seed = -$signed(adot) >>> 8;   // /256 ~= /200 (25% low, fine)   // 1-tick late is fine: PID
                                                  // first tick comes 5 ms later

    // ------------------------------------------------------- position loop --
    wire signed [15:0] pos_pid_out;
    pid #(
        .KP (KP_POS), .KI (KI_POS), .KD (KD_POS),
        .OUT_MIN (-POS_TRIM_S), .OUT_MAX ( POS_TRIM_S),
        // the integrator shares the trim clamp: it must never wind past the
        // authority the position loop actually has
        .I_MIN (-POS_TRIM_S), .I_MAX ( POS_TRIM_S),
        .D_SHIFT (D_SHIFT_POS), .I_BAND (POS_I_BAND)
    ) u_pos_pid (
        .clk (clk), .rst_n (rst_n), .tick (tick_20),
        .en  (bal_en), .clr (bal_clr),
        .d_seed (16'sd0),
        .sp  (loc_target[15:0]),
        .fb  (pos_fb[15:0]),
        .out (pos_pid_out)
    );

    // TIMING 2026-10-05: the cascade was fully combinational from the
    // position PID's output register into the angle PID and out to `duty`
    // (25.64 ns vs 24.32 ns allowed, slack -1.32 ns, 14 failing endpoints).
    // Registering the setpoint splits it: pos_pid -> ang_sp (5 ns) and
    // ang_sp -> angle PID -> duty (~16 ns).  A one-clock (20 ns) delay of a
    // 20 Hz position-loop setpoint is irrelevant.
    reg signed [15:0] ang_sp_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ang_sp_r <= 16'sd0;
        else        ang_sp_r <= -pos_pid_out;
    end
    wire signed [15:0] ang_sp = ang_sp_r;

    // ------------------------------------------------------- angle loop -----
    wire signed [15:0] ang_pid_out;
    pid #(
        .KP (KP_ANG), .KI (KI_ANG), .KD (KD_ANG),
        .OUT_MIN (-DUTY_LIM_S), .OUT_MAX ( DUTY_LIM_S),
        .I_MIN (-32'sd3000), .I_MAX (32'sd3000),
        .D_SHIFT (D_SHIFT_ANG), .I_BAND (0)
    ) u_ang_pid (
        .clk (clk), .rst_n (rst_n), .tick (tick_200),
        .en  (bal_en), .clr (bal_clr),
        .d_seed (d_seed),
        .sp  (ang_sp),
        .fb  (alpha),
        .out (ang_pid_out)
    );

    // ------------------------------------------------------- pump output ----
    // pump_ph: 0 = +pulse, 1 = +wait, 2 = -pulse, 3 = -wait
    // (pump_big is declared near the top -- use-before-declaration.)
    localparam [15:0] FPUMP_W = FIRST_PUMP;
    reg signed [15:0] pump_duty;
    always @(*) begin
        case (pump_ph)
            2'd0:    pump_duty = pump_big ? $signed(FPUMP_W) : $signed(PUMP_W);
            2'd2:    pump_duty = pump_big ? -$signed(FPUMP_W) : -$signed(PUMP_W);
            default: pump_duty =  16'sd0;
        endcase
    end

    // soft-start: first 100 ms of balance run at half output authority.
    // Was 200 ms: with a 30 deg/s capture gate the rod is slow at entry, but
    // the fall window is only 15 deg past the capture window edge -- bench
    // 10-07 showed a 78 deg/s rod sliding out in 95 ms while still at half
    // torque.  100 ms keeps the anti-kick purpose without eating the margin.
    // 2026-10-30: a capture far from vertical must NOT lose half its
    // authority.  cap_203705: both instant deaths entered at |alpha| 32-40
    // deg with the output already clipped to -5000 by the 100 ms soft start,
    // while the P term wanted ~9800 (3.075 * 32 deg).  Latch the entry angle
    // once per capture: past BIG_ENTRY the loop starts at full authority.
    localparam signed [31:0] BIG_ENTRY = 32'sd1500;   // 15 deg
    reg        entry_big;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        entry_big <= 1'b0;
        else if (bal_clr)  entry_big <= (alpha_abs > BIG_ENTRY);
    end
    reg [8:0] bal_ms;
    wire      bal_soft = bal_en && (bal_ms < 9'd100) && !entry_big;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  bal_ms <= 9'd0;
        // counted while IN BALANCE (not on bal_en: a glitch freeze must not
        // re-arm soft-start every time the slip ring drops out)
        else if (tick_1k && (mode_r == M_BAL)) begin
            // Saturate after the initial 100 ms.  A 9-bit free-running
            // counter wrapped every 512 ms and re-entered soft-start during
            // a long BAL run, periodically halving the control authority.
            if (bal_ms < 9'd100)
                bal_ms <= bal_ms + 9'd1;
        end
        else if (tick_1k)            bal_ms <= 9'd0;
    end
    // BUGFIX 2026-10-05: {1'b0, x[15:1]} is an UNSIGNED part-select, so a
    // negative angle-loop output came back as a large POSITIVE number
    // (-10000 -> +27768, exact match in the bench probe): during the first
    // 200 ms of every capture the soft-start kicked the arm BACKWARDS.
    // An arithmetic shift keeps the sign.
    // SIGN FIX 2026-10-07 (bench: BAL pushed the rod AWAY, +25deg -> +63deg
    // over 0.7 s with duty=-4896).  Reference chain: rod falls to adc+ side
    // -> Err0 = Target-Angle < 0 -> SetPWM < 0.  But Motor_SetPWM(+) drives
    // PB12=0/PB13=1 = AIN1:0/AIN2:1 = OUR duty < 0 (motor_driver: duty>0 =
    // AIN1:1/AIN2:0).  So our duty = -reference SetPWM, and the balance term
    // must come out INVERTED: rod at +alpha must give duty > 0.  The swing-up
    // pump path is separate and already bench-proven -- untouched.  The D-term
    // seed and the position loop flow through this same negation and stay
    // consistent with the reference.
    wire signed [15:0] ang_out = -ang_pid_out;
    wire signed [15:0] ang_out_ss = bal_soft ? (ang_out >>> 1)
                                             : ang_out;

    // ------------------------------------------------ saturation watchdog --
    // ANTI-CENTRIFUGAL-LOCK (bench 10-07 residue, e.g. [30.22s]): even with
    // the I term capped (+/-3000) and Kp halved, the position-loop clamp
    // (POS_TRIM) stacked on a large angle error can pin the balance output
    // at FULL authority indefinitely.  The arm then spins at constant full
    // duty and centrifugal force HOLDS the rod inside the fall window at a
    // frozen alpha -- the loop can never exit that state on its own (it
    // neither corrects nor falls out to a clean stop).
    //   |output| at full authority (DUTY_LIM) for WATCH_MS consecutive ms
    //   -> force the output to zero for REL_MS (motor short-brakes), re-arm.
    // Each cycle the arm sheds speed during the window; either the rod comes
    // back (error shrinks, saturation ends) or it leaves the fall window and
    // the run stops clean.  A legitimate rescue never sits at FULL output
    // for 400 ms straight (bench: -46 deg pulled back in ~300 ms), so normal
    // balancing is untouched.  The soft-start half-output ms do NOT count
    // (only real, delivered full torque accumulates).
    reg [9:0] sat_ms;                    // consecutive full-authority ms
    reg [6:0] rel_ms;                    // release window countdown
    wire sat_now = bal_en && ((ang_out_ss >= DUTY_LIM_W) ||
                              (ang_out_ss <= -DUTY_LIM_W));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sat_ms <= 10'd0;
            rel_ms <= 7'd0;
        end
        else if (tick_1k) begin
            if (rel_ms != 7'd0)
                rel_ms <= rel_ms - 7'd1;            // inside the release window
            else if (sat_now) begin
                if (sat_ms >= WATCH_W - 10'd1) begin
                    sat_ms <= 10'd0;                // WATCH_MS reached: fire
                    rel_ms <= REL_W;                // window starts next tick
                end
                else
                    sat_ms <= sat_ms + 10'd1;
            end
            else
                sat_ms <= 10'd0;                    // saturation ended: re-arm
        end
    end
    wire bal_rel = (rel_ms != 7'd0);     // release window active this cycle
    assign wdog  = bal_rel;

    wire signed [15:0] ang_out_wd = bal_rel ? 16'sd0 : ang_out_ss;
    wire signed [15:0] mode_out = (mode_r == M_BAL)  ? ang_out_wd :
                                  (mode_r == M_PUMP) ? pump_duty  :
                                  16'sd0;

    // ------------------------------------------------------- interlock ------
    // Pure combinational: machine off, link lost or STOP
    // -> zero duty THIS cycle.
    wire kill = !run || !link_ok || (mode_r == M_STOP);

    assign enable = !kill;

    always @(*) begin
        duty = kill ? 16'sd0 : mode_out;
    end

endmodule
