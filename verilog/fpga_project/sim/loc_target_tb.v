`timescale 1ns/1ps
// loc_target_tb.v -- target sequencer checks:
//   1. btn_up steps cmd by +408, clamped at +4080
//   2. target ramps toward cmd at STEP_HZ revolutions/s while run
//   3. btn_down mirrors, clamped at -4080
//   4. ramp pauses when run drops
//   5. 2026-10-28: step size comes from step_up/step_down (knob = 20 counts),
//      and `clear` drops cmd AND target to zero (BAL re-entry contract)
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

    // One strobe = high across exactly ONE tick edge (the contract top.v and
    // knob_dec implement: set after a tick, cleared at a later tick).  The
    // old fixed 1200-clock hold drifted in phase and sometimes spanned two
    // tick edges, which double-counted the step.
    task pulse(input which);
        begin
            @(posedge tick_1k);
            #1;
            if (which) btn_up = 1'b1; else btn_down = 1'b1;
            @(posedge tick_1k);            // consumer samples here
            #1;
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

        // ---- 5. knob step (20 counts) and the BAL-entry clear ----
        run = 1'b0;
        repeat (5) @(posedge tick_1k); #1;
        clear = 1'b1;                          // re-entry contract
        repeat (2) @(posedge tick_1k); #1;
        clear = 1'b0;
        check("clear drops target to 0", target, 0, 0);
        check("clear drops cmd to 0", dut.cmd, 0, 0);

        step_up = 16'd20; step_down = 16'd20;  // one knob detent
        for (k = 0; k < 20; k = k + 1) pulse(1);
        #1;
        check("20 knob detents -> cmd +400", dut.cmd, 400, 0);
        run = 1'b1;
        repeat (3000) @(posedge tick_1k); #1;  // 3 s of ramping at 408/s
        check("knob target reached", target, 400, 0);

        if (errors == 0) $display("PASS: loc_target_gen verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
