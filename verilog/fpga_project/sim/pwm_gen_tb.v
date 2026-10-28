// ============================================================================
// pwm_gen_tb.v -- self-checking testbench for the RUN-TIME-DUTY pwm_gen
//                 (rewritten 2026-10-11: the old tb instantiated the removed
//                  DUTY_PCT parameter and never compiled -- regression 12/13)
//
//   Kept OUT of the Gowin project (lives in sim/, never added to the .gprj).
//   Parameters are scaled down so the whole check runs in a few us:
//       CLK_FREQ = 1000, PWM_FREQ = 10  ->  PERIOD = 100 clocks, FRAC = 100
//       duty_x100 = N  ->  N/100 clocks high per period
//
//   Checks:
//     1. pwm_out stays low through reset
//     2. duty 0      -> constant low
//     3. duty 3000   -> 30 high / 70 low, three periods in a row
//     4. duty 5000 (changed at a period boundary) -> 50 high / 50 low
//     5. duty 10000  -> constant high
//     6. duty > 10000 saturates to constant high
//     7. duty 99 (below FRAC) -> constant low (rounds to 0 clocks)
//
//   Run:
//       iverilog -g2012 -o pwm_gen_tb.vvp pwm_gen_tb.v ../src/pwm_gen.v
//       vvp pwm_gen_tb.vvp
//
//   pwm_out is sampled on negedges (half a clock after each posedge), so
//   there is no race with the DUT's nonblocking assignment.
// ============================================================================
`timescale 1ns/1ps

module pwm_gen_tb;

    localparam integer TB_CLK_FREQ = 1000;
    localparam integer TB_PWM_FREQ = 10;

    localparam integer EXP_PERIOD = TB_CLK_FREQ / TB_PWM_FREQ;   // 100
    localparam integer EXP_FRAC   = 10000 / EXP_PERIOD;          // 100

    reg  [13:0] duty_x100 = 14'd0;
    reg         clk   = 1'b0;
    reg         rst_n = 1'b0;
    wire        pwm_out;

    integer errors = 0;
    integer high_cnt;
    integer low_cnt;
    integer p;

    pwm_gen #(
        .CLK_FREQ (TB_CLK_FREQ),
        .PWM_FREQ (TB_PWM_FREQ)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .duty_x100(duty_x100),
        .pwm_out  (pwm_out)
    );

    always #5 clk = ~clk;      // 10 ns period

    // count one full period of high/low phases; first waits for a LOW phase
    // so counting starts exactly at the next rising edge (entering mid-high
    // would undercount the high phase).  Only used with duties < 100%.
    task measure_period;
        begin
            high_cnt = 0;
            low_cnt  = 0;
            while (pwm_out !== 1'b0) @(negedge clk);   // land in the low phase
            while (pwm_out !== 1'b1) @(negedge clk);   // advance to rising edge
            while (pwm_out === 1'b1) begin             // high phase
                high_cnt = high_cnt + 1;
                @(negedge clk);
            end
            while (pwm_out === 1'b0) begin             // low phase
                low_cnt = low_cnt + 1;
                @(negedge clk);
            end
        end
    endtask

    task check_period(input [127:0] name, input integer exp_high);
        begin
            if (high_cnt !== exp_high || low_cnt !== EXP_PERIOD - exp_high) begin
                $display("FAIL %0s: high = %0d, low = %0d (expect %0d / %0d)",
                         name, high_cnt, low_cnt, exp_high, EXP_PERIOD - exp_high);
                errors = errors + 1;
            end
            else
                $display("  ok  %0s: %0d / %0d", name, high_cnt, low_cnt);
        end
    endtask

    task check_const(input [127:0] name, input exp_level);
        integer n;
        reg ok;
        begin
            ok = 1;
            for (n = 0; n < EXP_PERIOD; n = n + 1) begin
                @(negedge clk);
                if (pwm_out !== exp_level) begin
                    $display("FAIL %0s: pwm_out = %b at clock %0d, expected %b",
                             name, pwm_out, n, exp_level);
                    errors = errors + 1;
                    ok = 0;
                    n = EXP_PERIOD;                    // one report is enough
                end
            end
            if (ok)
                $display("  ok  %0s (constant %b for a full period)", name, exp_level);
        end
    endtask

    initial begin
        $dumpfile("pwm_gen_tb.vcd");
        $dumpvars(0, pwm_gen_tb);

        // ---- 1. output must stay low while reset is asserted ----
        duty_x100 = 14'd3000;
        repeat (5) @(negedge clk);
        if (pwm_out !== 1'b0) begin
            $display("FAIL: pwm_out = %b during reset, expected 0", pwm_out);
            errors = errors + 1;
        end

        rst_n = 1'b1;

        // ---- 2. duty 0 -> constant low ----
        duty_x100 = 14'd0;
        check_const("duty 0 -> constant low", 1'b0);

        // ---- 3. duty 3000 -> 30/70, three periods ----
        duty_x100 = 14'd3000;
        repeat (2) @(negedge clk);                     // let it take effect
        for (p = 0; p < 3; p = p + 1) begin
            measure_period;
            check_period("duty 3000", 3000 / EXP_FRAC);
        end

        // ---- 4. duty 5000 -> 50/50 ----
        duty_x100 = 14'd5000;
        for (p = 0; p < 2; p = p + 1) begin
            measure_period;
            check_period("duty 5000", 5000 / EXP_FRAC);
        end

        // ---- 5. duty 10000 -> constant high (10000/100 = PERIOD) ----
        duty_x100 = 14'd10000;
        repeat (2) @(negedge clk);
        check_const("duty 10000 -> constant high", 1'b1);

        // ---- 6. duty above 10000 saturates to constant high ----
        duty_x100 = 14'd12500;
        repeat (2) @(negedge clk);
        check_const("duty 12500 saturates -> constant high", 1'b1);

        // ---- 7. duty below FRAC -> constant low (rounds to 0 clocks) ----
        duty_x100 = 14'd99;
        repeat (2) @(negedge clk);
        check_const("duty 99 (<FRAC) -> constant low", 1'b0);

        if (errors == 0)
            $display("PASS: pwm_gen verified (0/3000/5000/10000/12500/99 duty)");
        else
            $display("FAIL: %0d check(s) failed", errors);

        $finish;
    end

endmodule
