`timescale 1ns/1ps
// ctrl_tb.v -- checks for the 江协-reference state machine port:
//   1. key released            -> STOP, duty 0
//   2. key press               -> PUMP: +3500 (100ms), 0 (100ms),
//                                 -3500 (100ms), 0 (100ms) -> JUDGE
//   3. two judge samples inside center window -> BALANCE, PID runs
//   3b. BALANCE must answer an off-vertical sample with non-zero duty
//       (regression for the 2026-10-05 undriven tick_200/tick_20 bug)
//   3c. BALANCE pinned at full output 400 ms -> saturation watchdog forces
//       a 60 ms zero-output window, re-fires while saturated, quiet when not
//       (2026-10-11 anti-centrifugal-lock)
//   3d. ADC endpoint slam while balancing -> glitch freeze: alpha must not
//       move, BALANCE must survive (2026-10-11, bench-derived)
//   3f. FAST true motion (415 deg/s) must NOT trip the freeze (2026-10-11
//       v2: the old 400 cdeg/ms budget froze the lightened rod mid-rescue;
//       budget raised to 2000)
//   4. rod falls out of window (ramped) -> STOP
//   4b. persistent bogus ADC -> freeze gives up after 200 ms (timeout)
//   3g. capture gate during freeze (tlm_run2 seg 1807/5003): alpha frozen
//       in-window with the adc away must NOT capture; after the adc returns
//       a REAL capture must follow
//   5. key release mid-state   -> STOP
module ctrl_tb;
    reg clk = 1'b0, rst_n = 1'b0;
    reg tick_1k = 1'b0;
    reg key_run = 1'b1;                    // released
    reg link_ok = 1'b0;
    reg [11:0] adc = 12'd1988;             // rod up (calibrated offset)
    reg signed [31:0] enc_pos = 32'sd0;
    reg signed [31:0] loc_target = 32'sd0;   // position-loop setpoint (counts)
    wire signed [15:0] duty;
    wire enable;
    wire signed [15:0] alpha;
    wire signed [15:0] adot_w;
    wire [2:0] mode;
    integer errors = 0;
    integer k;

    pendulum_ctrl #(
        .ANG_OFFSET (1988),
        .CENTER_WIN (4100),
        .PUMP_DUTY  (3500),
        .PULSE_MS   (100),     // 100 ms -> 100 ticks
        .POS_TRIM   (2000),
        .KEY_DEB_MS (1),       // tb drives 3-tick presses; the board
                               // build uses 30 ms (see key_deb_tb)
        .DUTY_LIM   (10000)
    ) dut (
        .clk (clk), .rst_n (rst_n), .tick_1k (tick_1k),
        .key_run (key_run), .link_ok (link_ok),
        .adc (adc), .enc_pos (enc_pos),
        .loc_target (loc_target),
        .duty (duty), .enable (enable),
        .alpha (alpha), .adot_dbg (adot_w), .wdog (wdog_w), .mode (mode)
    );

    wire wdog_w;
    integer wd_rel, wd_full, wd_leak;
    reg signed [15:0] alpc_pre;          // alpha snapshot for glitch checks

    always #10 clk = ~clk;                 // 50 MHz

    integer c = 0;
    always @(posedge clk) begin
        c <= c + 1;
        tick_1k <= (c % 1000 == 999);      // 1 kHz tick, one clk wide
    end

    task check(input [127:0] name, input [31:0] cond);
        if (cond === 1'b1) $display("  ok  %0s", name);
        else begin
            $display("FAIL %0s (duty=%0d mode=%0d alpha=%0d en=%b)",
                     name, duty, mode, alpha, enable);
            errors = errors + 1;
        end
    endtask

    initial begin
        $dumpfile("ctrl_tb.vcd");
        $dumpvars(0, ctrl_tb);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        link_ok = 1'b1;

        // ---- 1. key released -> STOP ----
        repeat (2000) @(posedge clk);
        #1;
        check("key released -> STOP, duty 0",
              (mode === 3'd0) && (duty === 16'sd0));

        // ---- 2. key press -> PUMP sequence ----
        //       adc stays inside the window (rod up), so after the pump
        //       pair the judge sees center-entry -> BALANCE
        key_run = 1'b0;                    // pressed (active low)
        repeat (3) @(posedge tick_1k);     // press consumed at the 1 ms tick
        #1;
        check("first pump pulse +4500", (duty === 16'sd4500) && (mode === 3'd2));
        repeat (99) @(posedge tick_1k);    // pulse lasts 100 ms
        #1;
        check("end of +pulse", (duty === 16'sd4500) && (mode === 3'd2));
        repeat (2) @(posedge tick_1k);     // step into the +wait phase
        #1;
        check("then +wait (duty 0)", (duty === 16'sd0) && (mode === 3'd2));
        repeat (102) @(posedge tick_1k);   // wait (100 ms) + into -pulse
        #1;
        check("then -pulse -4500", (duty === -16'sd4500));
        repeat (102) @(posedge tick_1k);   // pulse + into -wait
        #1;
        check("then -wait (duty 0)", (duty === 16'sd0));
        repeat (102) @(posedge tick_1k);   // -wait ends -> JUDGE
        #1;
        check("pump pair done -> JUDGE or direct BAL",
              (mode === 3'd1) || (mode === 3'd3));   // rod already inside the
                                                     // window: first judge
                                                     // sample captures at once
        repeat (130) @(posedge tick_1k);
        #1;
        check("center entry -> BALANCE", (mode === 3'd3));
        // ---- 3b. REGRESSION (2026-10-05): the balance loop must actually
        //          produce torque.  While tick_200 was undriven, both PIDs
        //          were swept by synthesis -> duty stayed 0 forever, yet this
        //          TB still reported PASS.  Feed an off-vertical sample
        //          (+100 counts = +812 cdeg, still inside the window) and a
        //          live loop MUST answer with non-zero duty.
        //          Negative control: compile this TB against the un-fixed RTL
        //          (D:\_fpga_verify\pc_hoist.v) -> this check must FAIL.
        // NOTE 2026-10-11: adc moves in RAMP (1 count/tick = 8 cdeg/ms, a
        // physically possible rod speed) -- a STEP would be a >4000 deg/s
        // jump and correctly trigger the new glitch-freeze, stalling the
        // test's own premise.  Ramps keep the TB physical.
        for (k = 0; k < 100; k = k + 1) begin
            adc = adc + 12'd1;
            @(posedge tick_1k);
        end
        repeat (240) @(posedge tick_1k);   // 240 ms: past the 200 ms soft start
        #1;
        check("balance loop alive (duty != 0)", (duty !== 16'sd0));
        // inclusive: the angle loop clamps at exactly +/-10000, so a
        // saturated (but healthy) output lands ON the bound.  The original
        // strict '<' compared only ever passed because duty was stuck at 0.
        check("balance duty in range",
              (duty >= -16'sd10000) && (duty <= 16'sd10000));

        // ---- 3c. saturation watchdog (2026-10-11): pin the rod at a big
        //          in-window angle so the P term ALONE saturates the loop;
        //          after WATCH_MS (400) of full output the watchdog must
        //          force a REL_MS (60) zero window, then full output resumes
        //          (still saturating) -- breaking the centrifugal lock.
        //          (adc ramps 2088 -> 2788 at 2 counts/tick = 162 deg/s.)
        for (k = 0; k < 350; k = k + 1) begin
            adc = adc + 12'd2;
            @(posedge tick_1k);
        end
        // alpha ~ +6081 cdeg: 1.85*6081 = 11250 > DUTY_LIM -> saturated,
        // still inside FALL_WIN (7000)
        wd_rel = 0; wd_full = 0; wd_leak = 0;
        for (k = 0; k < 700; k = k + 1) begin
            @(posedge tick_1k); #1;
            if (wdog_w === 1'b1) begin
                wd_rel = wd_rel + 1;
                if (duty !== 16'sd0) wd_leak = wd_leak + 1;
            end
            if ((duty === 16'sd10000) || (duty === -16'sd10000))
                wd_full = wd_full + 1;
        end
        check("watchdog fired (release window seen)", wd_rel  >= 55);
        check("zero output during release window",     wd_leak == 0);
        check("full output before/after release",      wd_full >= 400);
        // persistent saturation must fire AGAIN (lock would just return).
        // Budget: the PID output takes ~100 ms of ragged saturation (I term
        // settling) before the first clean 400 ms run, and each subsequent
        // cycle is WATCH+REL = 460 ms -- 700 ms comfortably holds window B.
        wd_rel = 0; wd_leak = 0;
        for (k = 0; k < 700; k = k + 1) begin
            @(posedge tick_1k); #1;
            if (wdog_w === 1'b1) begin
                wd_rel = wd_rel + 1;
                if (duty !== 16'sd0) wd_leak = wd_leak + 1;
            end
        end
        check("watchdog re-fires on persistent saturation", wd_rel >= 55);
        check("zero output during 2nd release window",      wd_leak == 0);
        // leaving saturation re-arms: ramp back toward vertical (2/tick),
        // wait out the transient, watchdog must stay quiet
        for (k = 0; k < 110; k = k + 1) begin
            adc = adc - 12'd2;
            @(posedge tick_1k);
        end
        repeat (150) @(posedge tick_1k); #1;
        check("watchdog quiet when unsaturated", wdog_w === 1'b0);

        // ---- 3d. ADC GLITCH FREEZE (2026-10-11): an endpoint slam (the
        //          bench's 154-per-120s 0<->4095 ADC jumps) must NOT move
        //          alpha -- the old slew limiter ramped alpha toward the
        //          bogus value, which (a) false-captured BALANCE entries and
        //          (b) killed the 28.1 s run mid-rescue.  Pre-fix this
        //          section FAILS: alpha ramps away and BALANCE stops.
        alpc_pre = alpha;
        adc = 12'd3800;                    // STEP: +143 deg bogus endpoint
        repeat (30) @(posedge tick_1k); #1;
        check("glitch: mode still BALANCE",  (mode === 3'd3));
        check("glitch: alpha frozen",        (alpha === alpc_pre));
        adc = 12'd2568;                    // adc returns where control left it
        repeat (60) @(posedge tick_1k); #1;
        check("glitch: recovered, still BALANCE", (mode === 3'd3));
        check("glitch: alpha still near pre value",
              (alpha > alpc_pre - 16'sd200) && (alpha < alpc_pre + 16'sd200));

        // ---- 3f. FAST true motion must NOT trip the freeze --------------
        // The rod's physical limit is ~300 deg/s = 30 cdeg/ms; this ramp is
        // 5 counts/tick = 40.6 cdeg/ms (406 deg/s), i.e. slightly ABOVE that
        // limit, so a real fast rod must still be followed.
        //
        // 2026-10-31: this used 51 counts/tick, which is 414.6 cdeg/tick =
        // 4146 deg/s -- 14x the physical limit.  That passed only because
        // the old SLEW_BUDGET was 2000 (20000 deg/s); the comment claiming
        // "415 deg/s" was off by 10x.
        alpc_pre = alpha;                  // ~ +4715 after the 3d settle
        for (k = 0; k < 80; k = k + 1) begin
            adc = adc - 12'd5;             // 40.6 cdeg/tick, 80 ticks = -3252 cdeg
            @(posedge tick_1k);
        end
        #1;
        check("fast true motion follows (no freeze)",
              (alpha < alpc_pre - 16'sd3000));

        // ---- 4. rod falls out of window -> STOP (ramped, as a real fall:
        //         1 count/tick ~ 8 cdeg/ms, no freeze, plain tracking).
        //         Starts from the 3f landing (adc ~2058); 900 ticks land at
        //         ~2958 counts = ~+7900 cdeg, past FALL_WIN (7000).
        for (k = 0; k < 900; k = k + 1) begin
            adc = adc + 12'd1;
            @(posedge tick_1k);
        end
        #1;
        check("rod fell -> STOP, duty 0",
              (mode === 3'd0) && (duty === 16'sd0) && (enable === 1'b0));

        // ---- 4b. PERSISTENT glitch timeout: a dead/bogus ADC must not
        //          freeze alpha forever -- after GLITCH_HOLD_MS (200) the
        //          limiter gives up and follows again (old behaviour)
        alpc_pre = alpha;                  // frozen position after the step
        adc = 12'd0;                       // STEP to the far endpoint, HOLD
        repeat (150) @(posedge tick_1k); #1;
        check("persistent glitch: still frozen at 150 ms",
              (alpha === alpc_pre));
        repeat (120) @(posedge tick_1k); #1;   // ~270 ms: timeout long past
        check("persistent glitch: follows after timeout",
              (alpha < alpc_pre - 16'sd2000));

        // ---- 3g. capture gate during freeze (tlm_run2 seg 1807/5003):
        //          alpha frozen in-window with the adc away must NOT
        //          capture (v1 did: in-window + adot decayed, no lock
        //          check); after the adc returns a REAL capture follows.
        key_run = 1'b1;                    // release
        repeat (3) @(posedge tick_1k);
        key_run = 1'b0;                    // press -> restart swing
        repeat (450) @(posedge tick_1k);   // pump pair 400 ms + judge head
        // judge: slam adc to the in-window target (glitch 0 -> 2088): 200 ms
        // freeze (alpha still at the endpoint), then the timeout follows:
        // alpha climbs toward +812 -- freeze it mid-climb inside the window
        adc = 12'd2088;
        repeat (210) @(posedge tick_1k);   // past the 200 ms timeout
        // wait until alpha climbs just inside the window (still < +812)
        k = 0;
        while (alpha < 16'sd100 && k < 400) begin
            @(posedge tick_1k);
            k = k + 1;
        end
        adc = 12'd0;                       // SLAM back to the endpoint: freeze
                                           // alpha in-window while adc is away
        repeat (150) @(posedge tick_1k); #1;   // adot decays under the gate
        check("capture gated during freeze (still JUDGE)",
              (mode === 3'd1));
        adc = 12'd2088;                    // adc returns: display agrees again
        repeat (400) @(posedge tick_1k); #1;
        check("real capture after adc returns", (mode === 3'd3));
        // exit BALANCE cleanly before the section-5 restart check
        adc = 12'd0;                       // glitch: 200 ms freeze, then the
        repeat (250) @(posedge tick_1k);   // timeout follows the bogus 0 ->
                                           // alpha leaves the fall window

        // ---- 5. restart needs release+press; link kill still instant ----
        // (run_latch was already cleared by the 4/4b stop; a fresh press
        // restarts the swing regardless of the bogus adc left in place)
        repeat (60) @(posedge tick_1k);
        key_run = 1'b1;                    // release (reference: no auto-reswing)
        repeat (3) @(posedge tick_1k);
        key_run = 1'b0;                    // press again -> swing restarts
        repeat (3) @(posedge tick_1k);
        check("restarted pump", (mode === 3'd2) || (mode === 3'd1));
        link_ok = 1'b0;                    // kill the link
        #1;
        check("link lost -> duty 0 (same cycle)",
              (duty === 16'sd0) && (enable === 1'b0));

        if (errors == 0) $display("PASS: pendulum_ctrl verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
