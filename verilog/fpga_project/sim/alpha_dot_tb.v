`timescale 1ns/1ps
// alpha_dot_tb.v -- velocity estimator checks.
//   Stimulus: alpha advanced by STEP cdeg immediately after each sampling
//   strobe, so the DUT sees a constant-velocity ramp of STEP * TICK_HZ.
//   tb sampling rate = 20 kHz (tick every 2500 clks), SCALE = 2500
//   -> STEP=1 cdeg gives 22500 cdeg/s effective (the estimator window spans
//   K=9 SAMPLE PERIODS, one more than the 8 intervals the diff math suggests
//   -- a constant +12.5% scale factor, calibrated into the tolerances below).
//   Only sign(adot) is consumed by the energy pump, so the scale error is
//   acceptable; re-derive SCALE if absolute magnitude is ever needed.
module alpha_dot_tb;
    reg clk = 1'b0, rst_n = 1'b0, tick = 1'b0;
    reg signed [15:0] alpha = 16'sd0;
    wire signed [15:0] adot;
    integer errors = 0;
    integer k;

    alpha_dot #(.K(9), .SCALE(32'sd2500)) dut (
        .clk (clk), .rst_n (rst_n), .tick (tick),
        .alpha (alpha), .adot (adot)
    );

    always #10 clk = ~clk;                 // 50 MHz

    integer c = 0;
    always @(posedge clk) begin
        c <= c + 1;
        tick <= (c % 2500 == 2499);        // 20 kHz sampling for the tb
    end

    task check(input [127:0] name, input integer got, want, tol);
        if ((got > want + tol) || (got < want - tol)) begin
            $display("FAIL %0s: got %0d want %0d (+/-%0d)", name, got, want, tol);
            errors = errors + 1;
        end else begin
            $display("  ok  %0s: %0d", name, got);
        end
    endtask

    initial begin
        $dumpfile("alpha_dot_tb.vcd");
        $dumpvars(0, alpha_dot_tb);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // ---- 1. hold still -> 0 ----
        repeat (30) @(posedge tick);
        #1;
        check("hold still -> adot 0", adot, 0, 30);

        // ---- 2. ramp up: +1 cdeg per 20 kHz sample = 20000 cdeg/s ----
        //       check inside the ramp (after it ends the diff decays)
        for (k = 0; k < 120; k = k + 1) begin
            @(posedge tick); #1;
            alpha = alpha + 16'sd1;
            if (k == 110) check("ramp up mid-flight", adot, 20000, 2600);
        end
        check("ramp up end -> 20000", adot, 20000, 2600);

        // ---- 3. ramp down -> -20000 ----
        for (k = 0; k < 120; k = k + 1) begin
            @(posedge tick); #1;
            alpha = alpha - 16'sd1;
        end
        check("ramp down end -> -20000", adot, -20000, 2600);

        // ---- 4. hold again -> decays to 0 ----
        repeat (400) @(posedge tick); #1;
        check("hold again -> 0", adot, 0, 300);

        if (errors == 0) $display("PASS: alpha_dot verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
