`timescale 1ns/1ps
// motor_tb.v -- motor_driver checks: brake on interlock, deadband,
//               direction split, magnitude passthrough.
module motor_tb;
    reg clk = 1'b0, rst_n = 1'b0, enable = 1'b0;
    reg signed [15:0] duty_in = 16'sd0;
    wire [13:0] duty_mag;
    wire AIN1, AIN2, braking;
    integer errors = 0;

    motor_driver #(.DEADBAND(150)) dut (
        .clk (clk), .rst_n (rst_n), .enable (enable),
        .duty_in (duty_in),
        .duty_mag (duty_mag), .AIN1 (AIN1), .AIN2 (AIN2), .braking (braking)
    );

    always #10 clk = ~clk;

    task check(input [127:0] name, input [31:0] cond);
        if (cond === 1'b1) $display("  ok  %0s", name);
        else begin
            $display("FAIL %0s (mag=%0d AIN1=%b AIN2=%b brk=%b)",
                     name, duty_mag, AIN1, AIN2, braking);
            errors = errors + 1;
        end
    endtask

    initial begin
        $dumpfile("motor_tb.vcd");
        $dumpvars(0, motor_tb);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        #1;

        // ---- 1. interlocked: short brake even with a duty present ----
        enable = 1'b0; duty_in = 16'sd5000;
        @(posedge clk); #1;
        check("interlock -> short brake (IN1=IN2=1, mag=0)",
              (braking === 1'b1) && (AIN1 === 1'b1) && (AIN2 === 1'b1) &&
              (duty_mag === 14'd0));

        // ---- 2. drive CW ----
        enable = 1'b1; duty_in = 16'sd5000;
        @(posedge clk); #1;
        check("drive +5000 -> mag 5000, AIN1=1/AIN2=0",
              (duty_mag === 14'd5000) && (AIN1 === 1'b1) && (AIN2 === 1'b0) &&
              (braking === 1'b0));

        // ---- 3. drive CCW ----
        duty_in = -16'sd3000;
        @(posedge clk); #1;
        check("drive -3000 -> mag 3000, AIN1=0/AIN2=1",
              (duty_mag === 14'd3000) && (AIN1 === 1'b0) && (AIN2 === 1'b1));

        // ---- 4. PWM offset (2026-10-25): small NON-ZERO duty -> lifted to
        //          the minimum drive (JiangXie pid-3 offset), NOT braked ----
        duty_in = 16'sd100;
        @(posedge clk); #1;
        check("duty +100 < deadband -> lifted to +150 drive",
              (braking === 1'b0) && (duty_mag === 14'd150) &&
              (AIN1 === 1'b1) && (AIN2 === 1'b0));

        duty_in = -16'sd149;
        @(posedge clk); #1;
        check("duty -149 < deadband -> lifted to -150 drive",
              (braking === 1'b0) && (duty_mag === 14'd150) &&
              (AIN1 === 1'b0) && (AIN2 === 1'b1));

        // ---- 4b. TRUE zero command still short-brakes (STOP/JUDGE/pump-wait
        //           and the interlock path rely on this) ----
        duty_in = 16'sd0;
        @(posedge clk); #1;
        check("duty 0 -> short brake",
              (braking === 1'b1) && (duty_mag === 14'd0) &&
              (AIN1 === 1'b1) && (AIN2 === 1'b1));

        // ---- 5. just above deadband -> drives again ----
        duty_in = 16'sd151;
        @(posedge clk); #1;
        check("duty +151 >= deadband -> drive",
              (braking === 1'b0) && (duty_mag === 14'd151) && (AIN1 === 1'b1));

        if (errors == 0) $display("PASS: motor_driver verified");
        else             $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
