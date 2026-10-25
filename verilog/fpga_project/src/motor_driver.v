`timescale 1ns/1ps
// ============================================================================
// motor_driver.v -- signed duty -> TB6612 drive interface (PWMA + AIN1/AIN2).
//
//   Responsibilities, all registered:
//     * split the signed duty into magnitude (to pwm_gen) + direction pins
//     * MIN-DRIVE (2026-10-25, JiangXie pid-3 "PWM offset"): any NON-ZERO
//       command below DEADBAND is lifted UP to DEADBAND instead of braking.
//       The old hard deadband braked small outputs, so a balancing loop
//       sitting inside the deadband accumulated error until it burst out as
//       a full step -- stick-slip, exactly the "low-frequency wobble =
//       offset too small" the factory page describes.  Short brake is now
//       reserved for a TRUE zero command (STOP / JUDGE / pump waits /
//       interlock), where holding still is what we want.
//     * enable = 0 (interlock): AIN1=AIN2=1 = TB6612 SHORT BRAKE, not coast.
//       Braking stops the arm far faster than freewheeling, and it needs no
//       PWM at all -- it holds even with duty_mag = 0.
//
//   TB6612 truth table used here:
//       IN1=1 IN2=0 PWM=1 -> CW      IN1=0 IN2=1 PWM=1 -> CCW
//       IN1=IN2=1         -> short brake (any PWM)
//       IN1=IN2=0         -> coast (never used: brake is safer)
// ============================================================================
module motor_driver #(
    parameter integer DEADBAND = 150          // duty_x100; 1.5 % = dead zone
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,                // 0 = interlocked -> short brake
    input  wire signed [15:0] duty_in,        // -10000..10000
    output reg  [13:0] duty_mag,             // 0..10000 -> pwm_gen
    output reg         AIN1,
    output reg         AIN2,
    output reg         braking               // debug/telemetry: 1 = brake held
);
    // PWM-offset equivalent: lift small non-zero commands to the minimum
    // drive so the loop always touches the motor (see header).  Signed
    // compares with an equal-width relay (trap 9: no part-selects).
    localparam signed [15:0] DB_W = DEADBAND;
    wire signed [15:0] duty_drv =
        (duty_in > 16'sd0 && duty_in < DB_W)   ?  DB_W :
        (duty_in < 16'sd0 && duty_in > -DB_W)  ? -DB_W :
        duty_in;
    wire [15:0] mag = (duty_drv < 16'sd0) ? -duty_drv : duty_drv;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            duty_mag <= 14'd0;
            AIN1     <= 1'b1;                // reset into brake, never coast
            AIN2     <= 1'b1;
            braking  <= 1'b1;
        end
        else if (!enable || (duty_drv == 16'sd0)) begin
            duty_mag <= 14'd0;
            AIN1     <= 1'b1;                // short brake
            AIN2     <= 1'b1;
            braking  <= 1'b1;
        end
        else begin
            duty_mag <= mag[13:0];
            AIN1     <= (duty_drv > 16'sd0);
            AIN2     <= (duty_drv < 16'sd0);
            braking  <= 1'b0;
        end
    end

endmodule
