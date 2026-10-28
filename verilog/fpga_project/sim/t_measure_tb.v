`timescale 1ns/1ps
// t_measure_tb.v -- T-method velocity checks against hand-computed values:
//   omega[0.1deg/s] = NUM / T,  NUM = 50e6*3600/408/10 = 441176470
//   T = 441176 clocks -> omega = 1000  (100.0 deg/s)
//   T =  44118 clocks -> omega = 10000 (1000 deg/s)
//   edges stop        -> omega decays to 0, valid drops
module t_measure_tb;
    reg clk = 1'b0, rst_n = 1'b0, edge_strobe = 1'b0, edge_dir = 1'b0;
    wire signed [15:0] omega;
    wire [25:0] period;
    wire valid;
    integer errors = 0;
    integer k;

    // short timeout so the decay test simulates fast
    t_measure #(
        .CLK_FREQ (50_000_000),
        .EDGES_PER_REV (408),
        .T_TIMEOUT (2000000)
    ) dut (
        .clk (clk), .rst_n (rst_n),
        .edge_strobe (edge_strobe), .edge_dir (edge_dir),
        .omega (omega), .period (period), .valid (valid)
    );

    always #10 clk = ~clk;

    task pulse_edge(input dir);
        begin
            @(negedge clk);
            edge_dir = dir; edge_strobe = 1'b1;
            @(posedge clk); #1;
            edge_strobe = 1'b0;
        end
    endtask

    task wait_clocks(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
            #1;
        end
    endtask

    task check(input [127:0] name, input integer got, want, tol);
        if ((got > want + tol) || (got < want - tol)) begin
            $display("FAIL %0s: got %0d want %0d (+/-%0d) period=%0d",
                     name, got, want, tol, period);
            errors = errors + 1;
        end else begin
            $display("  ok  %0s: %0d (period=%0d)", name, got, period);
        end
    endtask

    initial begin
        $dumpfile("t_measure_tb.vcd");
        $dumpvars(0, t_measure_tb);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // ---- 1. 100 deg/s positive: edges every 441176 clocks ----
        for (k = 0; k < 3; k = k + 1) begin
            pulse_edge(1'b0);                      // + direction
            wait_clocks(441170);                   // ~441176 between edges
        end
        wait_clocks(60);                           // division done (32 clks)
        check("100.0 deg/s -> omega 1000", omega, 1000, 3);
        check("valid after edges", valid, 1, 0);

        // ---- 2. 1000 deg/s negative: edges every 44118 clocks ----
        for (k = 0; k < 4; k = k + 1) begin
            pulse_edge(1'b1);                      // - direction
            wait_clocks(44112);
        end
        wait_clocks(60);
        check("1000 deg/s reverse -> omega -10000", omega, -10000, 30);

        // ---- 3. edges stop -> decay to 0, valid drops ----
        wait_clocks(2001000);                       // > T_TIMEOUT
        check("timeout -> omega 0", omega, 0, 0);
        check("timeout -> valid 0", valid, 0, 0);

        if (errors == 0) $display("PASS: t_measure verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
