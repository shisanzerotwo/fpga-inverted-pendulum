`timescale 1ns/1ps
// demo_sel_tb.v -- boot-time demo selector:
//   1. KEY1 idle through reset          -> demo ON  (default)
//   2. KEY1 held low through the window -> demo OFF
//   3. KEY1 low only 30 ms (bounce)     -> demo ON  (below LOW_MS)
//   4. key activity after the window    -> demo state frozen
module demo_sel_tb;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg tick_1k = 1'b0;
    reg key_n = 1'b1;                    // released
    wire demo_on;

    integer errors = 0;
    integer k;

    demo_sel #(
        .WIN_MS (100),
        .LOW_MS (60)
    ) dut (
        .clk (clk), .rst_n (rst_n), .tick_1k (tick_1k),
        .key_n (key_n), .demo_on (demo_on)
    );

    always #10 clk = ~clk;               // 50 MHz

    integer c = 0;
    always @(posedge clk) begin
        c <= c + 1;
        tick_1k <= (c % 1000 == 999);    // 1 kHz tick, one clk wide
    end

    task check(input [383:0] name, input cond);
        if (cond === 1'b1) $display("  ok  %0s", name);
        else begin
            $display("FAIL %0s (demo_on=%b)", name, demo_on);
            errors = errors + 1;
        end
    endtask

    // one case: hold the key low for hold_ms starting just before reset
    task run_case(input integer hold_ms);
        key_n = (hold_ms > 0) ? 1'b0 : 1'b1;   // press before reset release
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;                          // KEY0 released
        k = 0;
        while (k < hold_ms) begin              // hold, then let go
            @(posedge tick_1k);
            k = k + 1;
        end
        key_n = 1'b1;
        repeat (130) @(posedge tick_1k);       // past the 100 ms window
        #1;
    endtask

    initial begin
        // ---- 1. idle through reset: demo ON ----
        run_case(0);
        check("idle at reset -> demo ON", demo_on === 1'b1);

        // ---- 2. held through the window: demo OFF ----
        run_case(150);
        check("held through reset -> demo OFF", demo_on === 1'b0);

        // ---- 3. short bounce only: below LOW_MS, stays ON ----
        run_case(30);
        check("30 ms bounce -> demo ON", demo_on === 1'b1);

        // ---- 4. the decision is frozen after the window ----
        key_n = 1'b0;                          // press for a long time now
        repeat (300) @(posedge tick_1k);
        #1;
        check("late hold does not change the mode", demo_on === 1'b1);
        key_n = 1'b1;

        if (errors == 0) $display("PASS: demo_sel verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
