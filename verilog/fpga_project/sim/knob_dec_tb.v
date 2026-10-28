`timescale 1ns/1ps
// knob_dec_tb.v -- rotary-encoder front end:
//   1. four clean quadrant transitions = exactly one step_up
//   2. contact bounce (1 ms glitch inside each quadrant) must not count twice
//   3. reverse direction = one step_down
//   4. 20 detents = 20 pulses (the bench check "20 clicks = 408 counts"
//      is 20 x 20 counts by construction)
//   5. button bounce = one toggle; a second press inside the lock is ignored;
//      a press after the lock toggles again
module knob_dec_tb;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg tick_1k = 1'b0;
    reg a = 1'b0;                 // start at 00 (both phases low, as at rest)
    reg b = 1'b0;
    reg sw_n = 1'b1;              // released
    wire step_up, step_down, sw_toggle;

    integer up_cnt = 0, dn_cnt = 0, sw_cnt = 0;
    integer errors = 0;
    integer k;

    knob_dec #(
        .DEB_MS           (3),
        .PHASE_PER_DETENT (4),
        .SW_LOCK_MS       (50),
        .INVERT           (1'b0)
    ) dut (
        .clk (clk), .rst_n (rst_n), .tick_1k (tick_1k),
        .a (a), .b (b), .sw_n (sw_n),
        .step_up (step_up), .step_down (step_down), .sw_toggle (sw_toggle)
    );

    always #10 clk = ~clk;                  // 50 MHz

    integer c = 0;
    always @(posedge clk) begin
        c <= c + 1;
        tick_1k <= (c % 1000 == 999);       // 1 kHz tick, one clk wide
    end

    reg up_d = 1'b0, dn_d = 1'b0, sw_d = 1'b0;
    always @(posedge clk) begin
        up_d <= step_up;
        dn_d <= step_down;
        sw_d <= sw_toggle;
        if (step_up   && !up_d) up_cnt <= up_cnt + 1;   // rising edges only
        if (step_down && !dn_d) dn_cnt <= dn_cnt + 1;   // (a strobe lasts 1 ms)
        if (sw_toggle && !sw_d) sw_cnt <= sw_cnt + 1;
    end

    task check(input [511:0] name, input cond);
        if (cond === 1'b1) $display("  ok  %0s", name);
        else begin
            $display("FAIL %0s (up=%0d dn=%0d sw=%0d a=%b b=%b)",
                     name, up_cnt, dn_cnt, sw_cnt, a, b);
            errors = errors + 1;
        end
    endtask

    // hold one quadrature state; `glitch` = 1 inserts a 1 ms wrong-phase
    // blip in the middle (contact bounce), 2 inserts it at the end
    task qhold(input reg na, input reg nb, input integer ms, input integer glitch);
        a = na; b = nb;
        if (glitch == 1) begin
            repeat (3) @(posedge tick_1k);  // long enough to be accepted
            a = ~na;                        // 1 ms wrong phase (bounce)
            repeat (1) @(posedge tick_1k);  // too short for DEB_MS: ignored
            a = na;
            repeat (ms) @(posedge tick_1k);
        end
        else repeat (ms) @(posedge tick_1k);
    endtask

    // one full clockwise detent: 00->01->11->10->00, 5 ms per quadrant
    task detent_up(input integer glitch);
        qhold(1'b0, 1'b1, 5, glitch);       // 00 -> 01
        qhold(1'b1, 1'b1, 5, glitch);       // 01 -> 11
        qhold(1'b1, 1'b0, 5, glitch);       // 11 -> 10
        qhold(1'b0, 1'b0, 5, glitch);       // 10 -> 00
    endtask

    // one full counter-clockwise detent: 00->10->11->01->00
    task detent_dn;
        qhold(1'b1, 1'b0, 5, 0);            // 00 -> 10
        qhold(1'b1, 1'b1, 5, 0);            // 10 -> 11
        qhold(1'b0, 1'b1, 5, 0);            // 11 -> 01
        qhold(1'b0, 1'b0, 5, 0);            // 01 -> 00
    endtask

    task press(input integer ms);
        sw_n = 1'b0;
        repeat (ms) @(posedge tick_1k);
        sw_n = 1'b1;
        repeat (ms) @(posedge tick_1k);
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge tick_1k);     // let it prime on the resting state

        // ---- 1. one clean detent ----
        detent_up(0);
        repeat (6) @(posedge tick_1k);
        check("one clean detent -> one step_up", (up_cnt === 1) && (dn_cnt === 0));

        // ---- 2. same detent with a 1 ms bounce in every quadrant ----
        detent_up(1);
        repeat (6) @(posedge tick_1k);
        check("bounced detent -> exactly one more step_up",
              (up_cnt === 2) && (dn_cnt === 0));

        // ---- 3. reverse ----
        detent_dn;
        repeat (6) @(posedge tick_1k);
        check("reverse detent -> one step_down",
              (up_cnt === 2) && (dn_cnt === 1));

        // ---- 4. 20 detents = 20 pulses ----
        for (k = 0; k < 20; k = k + 1) detent_up(0);
        repeat (6) @(posedge tick_1k);
        check("20 detents -> 22 total step_up", (up_cnt === 22));

        // ---- 5. button: bounce, lock, then a later press ----
        sw_n = 1'b0;                        // press with contact chatter
        repeat (2) @(posedge tick_1k);
        sw_n = 1'b1; repeat (1) @(posedge tick_1k);
        sw_n = 1'b0; repeat (1) @(posedge tick_1k);
        sw_n = 1'b1; repeat (1) @(posedge tick_1k);
        sw_n = 1'b0;                        // settles pressed
        repeat (6) @(posedge tick_1k);
        sw_n = 1'b1;
        repeat (8) @(posedge tick_1k);
        check("bounced press -> one toggle", sw_cnt === 1);

        press(6);                           // inside the 50 ms lock
        check("press inside lock -> still one toggle", sw_cnt === 1);

        repeat (60) @(posedge tick_1k);     // let the lock expire
        press(80);                          // after the lock
        check("press after lock -> second toggle", sw_cnt === 2);

        if (errors == 0) $display("PASS: knob_dec verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
