`timescale 1ns/1ps
// ============================================================================
// loc_target_gen.v -- position-target sequencer for the extended requirements
//                     (拓展1 位置控制 + 拓展2 速度曲线).
//
//   Buttons step the commanded target by +/-408 counts (one arm revolution
//   each), clamped to +/-4080 (10 revolutions) like the reference.
//   The TARGET then RAMPES toward the command in one-revolution steps at
//   STEP_HZ, so the arm follows a linear velocity profile while the rod
//   stays up -- the balance loop sees a slow-moving setpoint, not a step.
//
//   All state advances on tick_1k.  Button inputs are already single-clock
//   strobes (from top.v edge detectors).
// ============================================================================
module loc_target_gen #(
    parameter integer STEP_HZ   = 2,        // ramp: revolutions per second
    parameter integer REV_COUNT = 408,      // counts per arm revolution
    parameter integer LIMIT     = 4080,     // +/- target clamp (10 revolutions)
    // 2026-10-26: the ramp step used to equal REV_COUNT (a full revolution per
    // DIV ms).  On this light rod a full-rev step tilts the pendulum ~12 deg
    // (p90) during the move and leaves it swinging at the stop moment.  A
    // separate (smaller) RAMP_STEP with the SAME DIV gives the position loop a
    // gentler setpoint -- half-rev steps at STEP_HZ=1 = 0.5 rev/s.
    parameter integer RAMP_STEP = 408
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick_1k,
    input  wire        btn_up,       // 1-clock strobe: target += 1 revolution
    input  wire        btn_down,     // 1-clock strobe: target -= 1 revolution
    input  wire        run,          // machine running (ramp only while run)
    output reg  signed [31:0] target,
    output reg         moving               // 1 while ramping (debug)
);
    localparam signed [31:0] REV_S  = REV_COUNT;
    localparam signed [31:0] STEP_S = RAMP_STEP;
    localparam signed [31:0] LIM_S  = LIMIT;
    parameter integer DIV = 1000 / STEP_HZ; // ms per one-revolution step
    localparam [8:0] DIV_W = DIV;           // equal-width relay (trap 9).  9
                                            // bits: DIV=500 overflowed the old
                                            // 8-bit counter (ramp_div wrapped
                                            // at 256 and the >= compare saw a
                                            // truncated 244 -> 4.1 rev/s
                                            // instead of the 2 rev/s contract;
                                            // found by the 10-23 independent
                                            // audit, fixed 10-26)

    reg signed [31:0] cmd;                   // commanded target
    reg [8:0]  ramp_div;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd      <= 32'sd0;
            target   <= 32'sd0;
            moving   <= 1'b0;
            ramp_div <= 9'd0;
        end
        else if (tick_1k) begin
            // ---- button steps (single-shot strobes) ----
            if (btn_up)   cmd <= (cmd + REV_S >  LIM_S) ?  LIM_S : cmd + REV_S;
            if (btn_down) cmd <= (cmd - REV_S < -LIM_S) ? -LIM_S : cmd - REV_S;

            // ---- ramp toward cmd, one revolution per DIV ms ----
            if (run && (target != cmd)) begin
                moving <= 1'b1;
                if (ramp_div >= DIV_W - 9'd1) begin
                    ramp_div <= 9'd0;
                    if (cmd - target >= STEP_S)      target <= target + STEP_S;
                    else if (target - cmd >= STEP_S) target <= target - STEP_S;
                    else                             target <= cmd;
                end
                else ramp_div <= ramp_div + 9'd1;
            end
            else begin
                moving   <= 1'b0;
                ramp_div <= 9'd0;
            end
        end
    end

endmodule
