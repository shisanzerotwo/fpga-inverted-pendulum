`timescale 1ns/1ps
// ============================================================================
// pwm_gen.v -- fixed-frequency PWM generator with a run-time duty input.
//
//   duty_x100 : 0 .. 10000  =  0.00 .. 100.00 %  (registered by the caller)
//   pwm_out   : high for duty_x100/100 percent of every period
//
//   With the default 50 MHz / 20 kHz the period is exactly 2500 clocks, so
//   10000/PERIOD = 4 and the duty-to-count conversion is a clean >> 2.
//   If you change PWM_FREQ, make sure 10000 % PERIOD == 0 or rework the
//   conversion below.
// ============================================================================
module pwm_gen #(
    parameter integer CLK_FREQ = 50_000_000,   // Hz
    parameter integer PWM_FREQ = 20_000        // Hz
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [13:0] duty_x100,              // 0..10000
    output reg         pwm_out
);
    localparam [31:0] PERIOD = CLK_FREQ / PWM_FREQ;          // 2500
    localparam integer FRAC  = 10000 / PERIOD;               // 4

    wire [13:0] duty_sat = (duty_x100 > 14'd10000) ? 14'd10000 : duty_x100;
    wire [31:0] duty_cnt = duty_sat / FRAC;                  // >> 2 when FRAC = 4

    reg [31:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cnt <= 32'd0;
        else if (cnt >= PERIOD - 32'd1)
            cnt <= 32'd0;
        else
            cnt <= cnt + 32'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pwm_out <= 1'b0;
        else
            pwm_out <= (cnt < duty_cnt) ? 1'b1 : 1'b0;
    end

endmodule
