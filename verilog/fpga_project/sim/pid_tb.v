`timescale 1ns/1ps
// pid_tb.v -- fixed-point PID check.  Delta-based assertions so the checks
//             do not depend on tick alignment:
//   step 5000 -> P=(5000*0.30)=1499, D-kick=(5000*0.40)=1999, I creep +49/tick
module pid_tb;
    reg clk = 1'b0, rst_n = 1'b0, tick = 1'b0;
    reg signed [15:0] sp = 16'sd0, fb = 16'sd0;
    wire signed [15:0] out;
    integer errors = 0;
    integer k;
    integer out1, out2, out3;

    pid dut (
        .clk (clk), .rst_n (rst_n), .tick (tick),
        .en (1'b1), .clr (1'b0),
        .sp (sp), .fb (fb), .out (out)
    );

    always #10 clk = ~clk;                 // 50 MHz

    integer c = 0;
    always @(posedge clk) begin
        c <= c + 1;
        tick <= (c % 2500 == 2499);        // 20 kHz tick
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
        $dumpfile("pid_tb.vcd");
        $dumpvars(0, pid_tb);

        repeat (10) @(negedge clk);
        rst_n = 1'b1;

        // ---- 1. zero in, zero out ----
        sp = 16'sd0; fb = 16'sd0;
        repeat (12) @(posedge tick);
        #1;
        check("zero in -> zero out", out, 0, 0);

        // ---- 2. step: tick1 = P+D, then D decays, I creeps +49/tick ----
        @(negedge clk); sp = 16'sd5000;
        @(posedge tick); #1; out1 = out;   // first tick: P + D kick
        @(posedge tick); #1; out2 = out;   // second: D gone, I +49
        @(posedge tick); #1; out3 = out;   // third: I +49 again
        check("tick1 = P+D kick", out1, 3498, 60);
        check("tick2-tick1 = -D+I", out2 - out1, -1950, 4);
        check("tick3-tick2 = +I creep", out3 - out2, 49, 4);

        // ---- 3. clamp high ----
        @(negedge clk); sp = 16'sd32767; fb = -16'sd32768;
        repeat (20) @(posedge tick);
        #1;
        check("clamp at OUT_MAX", out, 10000, 0);

        // ---- 4. clamp low (rail the other way) ----
        @(negedge clk); sp = -16'sd32768; fb = 16'sd32767;
        repeat (20) @(posedge tick);
        #1;
        check("clamp at OUT_MIN", out, -10000, 0);

        if (errors == 0) $display("PASS: pid verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
