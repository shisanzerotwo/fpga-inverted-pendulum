`timescale 1ns/1ps
// zero_guard_tb.v -- start must be refused when the angle zero has drifted
// (2026-10-30).  The rod hangs at the pot's travel end-stop, so at rest the
// reading has to sit at an end of the 4095-count track.  Bench 10-30: the
// coupling slipped ~3270 counts in one session and the balance loop then held
// the rod ~98 deg off vertical (BAL survived 1.1~1.8 s).  ANG_OFFSET is a
// compile-time constant, so the firmware cannot follow that -- it must refuse
// to start and say so.
//
// Checks:
//   1. rod at the end-stop, KEY1 -> starts pumping (guard lets it through);
//   2. rod mid-track, KEY1 -> stays in STOP, zero_fault raised, no pump;
//   3. rod back at the end-stop, KEY1 -> starts again, flag drops.
module zero_guard_tb;
    reg clk = 1'b0, rst_n = 1'b0, tick_1k = 1'b0;
    reg key_run = 1'b1;                 // released (active low)
    reg link_ok = 1'b1;
    reg [11:0] adc = 12'd0;             // rod hanging on the end-stop
    reg signed [31:0] enc_pos = 32'sd0;
    reg signed [31:0] loc_target = 32'sd0;
    wire signed [15:0] duty;
    wire enable;
    wire signed [15:0] alpha, adot_w;
    wire wdog_w;
    wire [2:0] mode;
    wire zero_fault;
    integer errors = 0;

    pendulum_ctrl #(
        .ANG_OFFSET (2057)
    ) dut (
        .clk (clk), .rst_n (rst_n), .tick_1k (tick_1k),
        .key_run (key_run), .link_ok (link_ok),
        .adc (adc), .enc_pos (enc_pos),
        .loc_target (loc_target),
        .duty (duty), .enable (enable),
        .alpha (alpha), .adot_dbg (adot_w), .wdog (wdog_w), .mode (mode),
        .zero_fault (zero_fault)
    );

    always #10 clk = ~clk;
    integer c = 0;
    always @(posedge clk) begin
        c <= c + 1;
        tick_1k <= (c % 1000 == 999);
    end

    task check(input [511:0] name, input cond);
        if (cond === 1'b1) $display("  ok  %0s", name);
        else begin
            $display("FAIL %0s (mode=%0d zero_fault=%0b adc=%0d)",
                     name, mode, zero_fault, adc);
            errors = errors + 1;
        end
    endtask

    // one KEY1 press (active-low pulse), 100 ms apart
    task press;
        begin
            @(posedge tick_1k); #1;
            key_run = 1'b0;
            repeat (10) @(posedge tick_1k);
            #1;
            key_run = 1'b1;
            repeat (1200) @(posedge tick_1k);   // 1.2 s: clears KEY_LOCK_MS
            #1;
        end
    endtask

    integer pumps;

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge tick_1k);

        // ---- 1. rod on the end-stop: the guard must let the start through --
        adc = 12'd0;
        press;
        check("rod at end-stop -> engine starts (PUMP seen)",
              (mode == 3'd2) || (mode == 3'd1));
        check("no fault while the rod is down", zero_fault === 1'b0);
        check("duty alive after start", dut.run_latch === 1'b1);

        // ---- 2. rod mid-track (= zero has drifted): refuse --------------
        @(posedge tick_1k); #1;
        key_run = 1'b0;                      // stop the current run
        repeat (10) @(posedge tick_1k);
        #1;
        key_run = 1'b1;
        repeat (1200) @(posedge tick_1k);
        #1;
        adc = 12'd2048;                      // rod reads mid-track
        repeat (5) @(posedge tick_1k);
        check("mid-track reading raises the fault", zero_fault === 1'b1);

        press;
        check("key press refused: still STOP", mode === 3'd0);
        check("key press refused: no pump and run stays off",
              (dut.run_latch === 1'b0) && (dut.mode_r === 3'd0));

        // ---- 3. rod back on the end-stop: works again -------------------
        adc = 12'd0;
        repeat (5) @(posedge tick_1k);
        check("fault clears when the rod is back down", zero_fault === 1'b0);
        press;
        check("start works again", (mode == 3'd2) || (mode == 3'd1));

        // ---- 4. the far end of the track is also a legal hang pose ------
        @(posedge tick_1k); #1;
        key_run = 1'b0; repeat (10) @(posedge tick_1k); #1; key_run = 1'b1;
        repeat (1200) @(posedge tick_1k); #1;
        adc = 12'd4090;                      // dead-zone side of the same pose
        repeat (5) @(posedge tick_1k);
        check("dead-zone side of the hang pose is accepted", zero_fault === 1'b0);
        press;
        check("start works from the dead-zone side", (mode == 3'd2) || (mode == 3'd1));

        if (errors == 0) $display("PASS: zero guard verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
