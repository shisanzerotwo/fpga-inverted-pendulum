`timescale 1ns/1ps
// mode_ctl_tb.v -- AUTO/MANUAL state:
//   1. before the boot decision the output follows boot_mode
//   2. after the decision a 1 ms WIDE pulse toggles exactly ONCE
//      (regression: a level-sensitive toggle in the 50 MHz loop flipped on
//       every clock and a 1000-clock pulse returned to the start state)
//   3. a second pulse toggles back
//   4. later changes of boot_mode are ignored
module mode_ctl_tb;
    reg clk = 1'b0, rst_n = 1'b0;
    reg boot_mode = 1'b1, boot_decided = 1'b0, sw_toggle = 1'b0;
    wire mode_auto;
    integer errors = 0;

    mode_ctl dut (
        .clk (clk), .rst_n (rst_n),
        .boot_mode (boot_mode), .boot_decided (boot_decided),
        .sw_toggle (sw_toggle), .mode_auto (mode_auto)
    );

    always #10 clk = ~clk;                  // 50 MHz

    task check(input [383:0] name, input cond);
        if (cond === 1'b1) $display("  ok  %0s", name);
        else begin
            $display("FAIL %0s (mode_auto=%b)", name, mode_auto);
            errors = errors + 1;
        end
    endtask

    // one press: exactly 1 ms high, like knob_dec's strobe.  Driven on the
    // NEGEDGE so the DUT never samples a value that changed in the same time
    // step (racing the DUT's own posedge was what made the first version of
    // this tb report a false failure).
    task press;
        begin
            @(negedge clk);
            sw_toggle = 1'b1;
            repeat (1000) @(negedge clk);
            sw_toggle = 1'b0;
            repeat (20) @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ---- 1. boot follow ----
        check("after reset: AUTO", mode_auto === 1'b1);
        @(negedge clk); boot_mode = 1'b0;   // hold KEY1 at reset = MANUAL
        repeat (4) @(posedge clk);
        check("before decision: follows boot_mode=0", mode_auto === 1'b0);
        @(negedge clk); boot_decided = 1'b1;  // decision latched
        repeat (4) @(posedge clk);
        check("decision latched: stays MANUAL", mode_auto === 1'b0);

        // ---- 2. one wide pulse = one toggle ----
        press;
        check("1 ms pulse toggles to AUTO", mode_auto === 1'b1);

        // ---- 3. and back ----
        press;
        check("second pulse back to MANUAL", mode_auto === 1'b0);

        // ---- 4. boot_mode no longer matters ----
        boot_mode = 1'b1;
        repeat (20) @(posedge clk);
        check("boot_mode ignored after decision", mode_auto === 1'b0);

        if (errors == 0) $display("PASS: mode_ctl verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
