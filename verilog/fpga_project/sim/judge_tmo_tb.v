`timescale 1ns/1ps
// judge_tmo_tb.v -- JUDGE must not wait for ever on a dead-still rod
// (2026-10-28): with the rod hanging outside the window and no motion, adot
// never flips sign, so no peak fires.  Before the fix the FSM sat in JUDGE
// for seconds with the rod down (bench: 4~10 s stretches, swing-up dead).
// After JUDGE_MS without a peak it must fire a retry pump.
module judge_tmo_tb;
    reg clk = 1'b0, rst_n = 1'b0, tick_1k = 1'b0;
    reg key_run = 1'b1;                 // released
    reg link_ok = 1'b1;
    reg [11:0] adc = 12'd0;             // rod hanging (alpha ~ -167 deg), still
    reg signed [31:0] enc_pos = 32'sd0;
    reg signed [31:0] loc_target = 32'sd0;
    wire signed [15:0] duty;
    wire enable;
    wire signed [15:0] alpha, adot_w;
    wire wdog_w;
    wire [2:0] mode;
    integer errors = 0;

    pendulum_ctrl #(
        .ANG_OFFSET (2057),
        .JUDGE_MS   (300),              // short for the simulation
        .KEY_DEB_MS (1)                 // tb presses are only a few ticks long
    ) dut (
        .clk (clk), .rst_n (rst_n), .tick_1k (tick_1k),
        .key_run (key_run), .link_ok (link_ok),
        .adc (adc), .enc_pos (enc_pos),
        .loc_target (loc_target),
        .duty (duty), .enable (enable),
        .alpha (alpha), .adot_dbg (adot_w), .wdog (wdog_w), .mode (mode)
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
            $display("FAIL %0s (mode=%0d duty=%0d)", name, mode, duty);
            errors = errors + 1;
        end
    endtask

    integer k, pumps, judges;
    reg stuck;
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge tick_1k);

        key_run = 1'b0;                     // start: STOP -> PUMP (first pump)
        repeat (3) @(posedge tick_1k);
        key_run = 1'b1;                     // release (run is latched)

        // The rod stays dead still and outside the window.  Count pump
        // entries over 3 s: the timeout (300 ms in this tb) must keep firing
        // them, so we expect several.
        pumps = 0; judges = 0; stuck = 1'b0;
        for (k = 0; k < 3000; k = k + 1) begin
            @(posedge tick_1k); #1;
            if (mode === 3'd2 && dut.mode_d !== 3'd2) pumps = pumps + 1;
            if (mode === 3'd1) judges = judges + 1;
        end
        $display("  (pumps=%0d, judge ticks=%0d)", pumps, judges);
        check("retry pumps fired (>=3 in 3 s)", pumps >= 3);
        check("judge time bounded (< 600 ms per stretch)", judges < 1800);

        if (errors == 0) $display("PASS: judge timeout verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
