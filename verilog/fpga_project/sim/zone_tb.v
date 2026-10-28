`timescale 1ns/1ps
// zone_tb.v -- regression for the reverse-rotation runaway bug:
//   the old implementation part-selected dz[8:0] (unsigned!) so dz = -1
//   became +511 and ezone ran away backwards.  This tb drives pos forward,
//   backward, and across zero, and requires ezone to track monotonically
//   and STOP changing when the arm stops.
module zone_tb;
    reg clk = 1'b0, rst_n = 1'b0;
    reg signed [31:0] pos = 32'sd0;
    wire [3:0] ezone;
    integer errors = 0;
    integer k;
    reg [3:0] z_hold;
    integer down_start;

    enc_zone #(.ZONE(41), .ZONE_MAX(9)) dut (
        .clk (clk), .rst_n (rst_n), .pos (pos), .ezone (ezone)
    );

    always #10 clk = ~clk;

    task check(input [127:0] name, input [31:0] cond);
        if (cond === 1'b1) $display("  ok  %0s (ezone=%0d)", name, ezone);
        else begin
            $display("FAIL %0s (ezone=%0d pos=%0d)", name, ezone, pos);
            errors = errors + 1;
        end
    endtask

    initial begin
        $dumpfile("zone_tb.vcd");
        $dumpvars(0, zone_tb);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // ---- 1. forward one full zone: +41 counts -> ezone 0 -> 1 ----
        for (k = 0; k < 41; k = k + 1) begin
            @(negedge clk); pos = pos + 1;
        end
        @(posedge clk); #1;
        check("forward 41 counts -> ezone 1", (ezone == 4'd1));

        // ---- 2. backward the same 41: ezone must return to 0 and STOP ----
        for (k = 0; k < 41; k = k + 1) begin
            @(negedge clk); pos = pos - 1;
        end
        @(posedge clk); #1;
        check("backward 41 counts -> ezone 0", (ezone == 4'd0));
        z_hold = ezone;
        repeat (200) @(posedge clk);           // arm stopped: nothing may drift
        #1;
        check("stopped -> ezone frozen", (ezone === z_hold));

        // ---- 3. the original bug scenario: long reverse run across zero ----
        // pos walks +123 then -123 (9->6 style jump would appear here)
        for (k = 0; k < 123; k = k + 1) begin
            @(negedge clk); pos = pos + 1;
        end
        @(posedge clk); #1;
        check("forward 123 -> ezone 3", (ezone == 4'd3));
        down_start = ezone;
        for (k = 0; k < 123; k = k + 1) begin
            @(negedge clk); pos = pos - 1;
        end
        @(posedge clk); #1;
        check("reverse 123 -> back to ezone 0", (ezone == 4'd0));
        z_hold = ezone;
        repeat (200) @(posedge clk);
        #1;
        check("no runaway after reverse", (ezone === z_hold));

        // ---- 4. big fast jump: +1024 in one clock step (impossible on hw,
        //         but the walker must still stay bounded, no X, no wrap spam)
        pos = pos + 32'sd1024;
        @(posedge clk); #1;
        check("huge +1024 jump stays in 0..9",
              (ezone <= 4'd9));
        pos = pos - 32'sd1024;
        repeat (10) @(posedge clk);
        #1;
        check("and back, still sane", (ezone <= 4'd9));

        if (errors == 0) $display("PASS: enc_zone verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
