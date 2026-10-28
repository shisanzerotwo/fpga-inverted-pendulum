`timescale 1ns/1ps
// alpha_dot_tb.v -- velocity estimator checks:
//   ramp up 10 cdeg/sample (200 Hz)  -> adot converges to 10*308 = 3080
//   ramp down the same               -> -3080
//   hold still                       -> 0
module alpha_dot_dbg;
    reg clk = 1'b0, rst_n = 1'b0, tick = 1'b0;
    reg signed [15:0] alpha = 16'sd0;
    wire signed [15:0] adot;
    integer errors = 0;
    integer k;

    alpha_dot #(.K(9), .SCALE(32'sd25)) dut (
        .clk (clk), .rst_n (rst_n), .tick (tick),
        .alpha (alpha), .adot (adot)
    );

    always #10 clk = ~clk;                 // 50 MHz

    integer c = 0;
    always @(posedge clk) begin
        c <= c + 1;
        tick <= (c % 2500 == 2499);        // 200 Hz
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
        $dumpfile("alpha_dot_dbg.vcd");
        $dumpvars(0, alpha_dot_tb);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // ---- 1. hold still -> 0 ----
        repeat (30) @(posedge tick);
        #1;
        check("hold still -> adot 0", adot, 0, 30);

        // ---- 2. ramp up 10 cdeg/sample -> 2000 cdeg/s ----
        //       check at the last ramp tick: after the ramp the diff decays
        //       to zero and adot decays with it, so a post-ramp check would
        //       read the DECAY, not the velocity (verified the hard way)
        for (k = 0; k < 60; k = k + 1) begin
            @(posedge tick); #1;
            alpha = alpha + 16'sd10;
            if (k >= 50)
                $display("k=%0d: alpha=%0d h0=%0d h8=%0d diff=%0d raw=%0d adot=%0d",
                         k, alpha, dut.hist[0], dut.hist[8], dut.diff, dut.raw, adot);
        end
        check("ramp +10/sample -> 2000", adot, 2000, 120);

        // ---- 3. ramp down -> -2000 ----
        for (k = 0; k < 60; k = k + 1) begin
            @(posedge tick); #1;
            alpha = alpha - 16'sd10;
        end
        check("ramp -10/sample -> -2000", adot, -2000, 120);

        // ---- 4. hold again -> decays to 0 ----
        repeat (80) @(posedge tick); #1;
        check("hold again -> 0", adot, 0, 60);

        if (errors == 0) $display("PASS: alpha_dot verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
