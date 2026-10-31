`timescale 1ns/1ps
// mode_ctl_tb.v -- AUTO/MANUAL state checks (2026-10-30):
//   1. power-up default is AUTO
//   2. a 1 ms wide sw_toggle pulse flips it exactly ONCE (MANUAL)
//   3. a second pulse flips it back (AUTO)
//   4. a 2 ms long level still flips it only once
//
// Check 4 is the regression for the 2026-10-28 bug: a level-sensitive toggle
// flips on every clock of the pulse and 1000 clocks (even) flips back, so the
// button appeared dead.
module mode_ctl_tb;
    reg  clk = 1'b0, rst_n = 1'b0;
    reg  sw_toggle = 1'b0;
    wire mode_auto;
    integer errors = 0;

    mode_ctl dut (
        .clk (clk), .rst_n (rst_n),
        .sw_toggle (sw_toggle), .mode_auto (mode_auto)
    );

    always #10 clk = ~clk;              // 50 MHz

    task check(input [127:0] name, input cond);
        if (cond === 1'b1) $display("  ok  %0s", name);
        else begin
            $display("FAIL %0s (mode_auto=%b)", name, mode_auto);
            errors = errors + 1;
        end
    endtask

    // one 1 ms wide strobe, driven on the negedge (never sampled at the same
    // instant the DUT samples)
    task pulse_ms(input integer ms);
        begin
            @(negedge clk);
            sw_toggle = 1'b1;
            repeat (ms * 50) @(negedge clk);
            sw_toggle = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        check("power-up is AUTO", mode_auto === 1'b1);

        pulse_ms(1);
        check("1 ms pulse -> MANUAL", mode_auto === 1'b0);
        repeat (5) @(negedge clk);
        check("stays MANUAL after the pulse", mode_auto === 1'b0);

        pulse_ms(1);
        check("second pulse -> AUTO", mode_auto === 1'b1);

        pulse_ms(2);                       // long level: must still be one toggle
        check("2 ms level -> MANUAL once", mode_auto === 1'b0);

        if (errors == 0) $display("PASS: mode_ctl verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
