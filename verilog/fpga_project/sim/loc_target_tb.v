`timescale 1ns/1ps
// loc_target_tb.v -- target sequencer checks:
//   1. btn_up steps cmd by +408, clamped at +4080
//   2. target ramps toward cmd at STEP_HZ revolutions/s while run
//   3. btn_down mirrors, clamped at -4080
//   4. ramp pauses when run drops
module loc_target_tb;
    reg clk = 1'b0, rst_n = 1'b0, tick_1k = 1'b0;
    reg btn_up = 1'b0, btn_down = 1'b0, run = 1'b0, clear = 1'b0;
    reg [15:0] step_up = 16'd408, step_down = 16'd408;
    wire signed [31:0] target;
    wire moving;
    integer errors = 0;
    integer k;

    loc_target_gen #(.STEP_HZ(2), .LIMIT(4080)) dut (
        .clk (clk), .rst_n (rst_n), .tick_1k (tick_1k),
        .btn_up (btn_up), .btn_down (btn_down),
        .step_up (step_up), .step_down (step_down),
        .clear (clear), .run (run),
        .target (target), .moving (moving)
    );

    always #10 clk = ~clk;

    integer c = 0;
    always @(posedge clk) begin
        c <= c + 1;
        tick_1k <= (c % 1000 == 999);
    end

    task pulse(input which);
        begin
            @(negedge clk);
            if (which) btn_up = 1'b1; else btn_down = 1'b1;
            // Hold for EXACTLY one tick period (1000 clk), so the interval
            // [start, start+1000) always contains exactly one tick edge and
            // the start phase never drifts between presses.
            //
            // The old body held 1200 clk = 1.2 periods: the phase walked
            // 200 clk per press and every 5th press spanned TWO ticks, so it
            // silently counted twice.  With the original 408-count step that
            // was invisible (all checks were on the +-4080 clamp or on ramp
            // targets); a 20-count knob step exposes it at once (5 x 20 was
            // reading back as 120).
            repeat (1000) @(posedge clk);
            #1
            btn_up = 1'b0; btn_down = 1'b0;
        end
    endtask

    task check(input [127:0] name, input integer got, want, tol);
        if ((got > want + tol) || (got < want - tol)) begin
            $display("FAIL %0s: got %0d want %0d (+/-%0d)", name, got, want, tol);
            errors = errors + 1;
        end else $display("  ok  %0s: %0d", name, got);
    endtask

    initial begin
        // (VCD dump dropped 2026-10-26: the 25 s ramp section dumps 25M clock
        // edges and dominates wall time; waveform debugging was never needed)

        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // ---- 1. two up presses: cmd 816; ramp starts only when run=1
        pulse(1); pulse(1);                    // cmd = +816 (target stays 0)
        #1;
        $display("DBG cmd=%0d target=%0d moving=%0d", dut.cmd, dut.target, dut.moving);
        check("no ramp before run", target, 0, 0);
        run = 1'b1;
        // 2026-10-26 contract fix: at STEP_HZ=2 the ramp steps ONE revolution
        // per 500 ms.  Checkpoints sit mid-interval (0.75 s / 1.25 s) so the
        // tick-alignment phase (+/-1 tick between `run` and the counter start)
        // can never straddle a step boundary (the old 0.5 s checkpoint wanted
        // 816 -- which only "passed" via the 8-bit ramp_div bug making the
        // real period 244 ms; audit 10-23, fixed 10-26).
        repeat (750) @(posedge tick_1k); #1;
        check("ramp: target 408 at 0.75 s", target, 408, 0);
        repeat (500) @(posedge tick_1k); #1;
        check("ramp: target 816 at 1.25 s", target, 816, 0);

        // ---- 2. long run: clamps at +4080 ----
        repeat (30) pulse(1);
        repeat (25000) @(posedge tick_1k); #1; // 25 s of ramping
        check("cmd clamped at +4080", target, 4080, 0);

        // ---- 3. ramp pauses when run drops ----
        run = 1'b0;
        repeat (500) @(posedge tick_1k); #1;
        check("ramp paused with run=0", target, 4080, 0);

        // ---- 4. down press then ramp to negative ----
        run = 1'b1;
        pulse(0);
        repeat (9000) @(posedge tick_1k); #1;  // 9 s at 2 rev/s
        check("down ramp moving", target < 32'sd4080, 1, 0);

        // ---- 5. clear drops command AND target (2026-10-28 BAL entry) ----
        // The old target must not survive a re-capture: the outer loop adds
        // it as an angle bias on the first balance tick.
        clear = 1'b1;
        repeat (1200) @(posedge clk); #1;
        clear = 1'b0;
        check("clear zeroes target", target, 0, 0);
        check("clear zeroes cmd", dut.cmd, 0, 0);

        // ---- 6. PORT-STEP SIGN TRAP (2026-10-30) --------------------------
        // A 16-bit UNSIGNED step pointer makes `cmd - step` unsigned, so the
        // compare against -LIMIT degrades: cmd=+400 one detent down became
        // 380 < 0xFFFFF010 -> TRUE -> cmd = -4080 (arm turns 10 revs).  The
        // 2026-10-28 build shipped exactly that bug.
        step_up   = 16'd20;
        step_down = 16'd20;

        pulse(1); pulse(1); pulse(1); pulse(1); pulse(1);   // cmd = +100
        check("port step 5x20 -> cmd 100", dut.cmd, 100, 0);

        pulse(0);                      // +100 - 20 = +80, NOT -4080
        check("detent down from +100 (signed)", dut.cmd, 80, 0);

        pulse(0); pulse(0); pulse(0); pulse(0);             // back to 0
        check("detent down through zero to 0", dut.cmd, 0, 0);

        pulse(0);                      // 0 - 20 = -20, NOT +4080
        check("detent down below zero", dut.cmd, -20, 0);

        pulse(1);                      // -20 + 20 = 0
        check("detent up back to zero", dut.cmd, 0, 0);

        // ---- 7. 20 detents = 400 counts, ramp follows ----
        repeat (11) pulse(1);          // 11 x 20 = 220
        repeat (9)  pulse(1);          // + 180 = 400
        check("20 detents -> cmd 400", dut.cmd, 400, 0);
        repeat (1200) @(posedge tick_1k); #1;
        check("ramp reaches 400", target, 400, 0);

        // ---- 8. port step still clamps at the rails ----
        step_up = 16'd408; step_down = 16'd408;
        repeat (11) pulse(1);          // 400 + 11*408 = 4888 -> clamp 4080
        check("port step clamps at +4080", dut.cmd, 4080, 0);
        repeat (21) pulse(0);          // 4080 - 21*408 = -4488 -> clamp -4080
        check("port step clamps at -4080", dut.cmd, -4080, 0);

        if (errors == 0) $display("PASS: loc_target_gen verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
