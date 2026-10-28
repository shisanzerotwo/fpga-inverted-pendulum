`timescale 1ns/1ps
// ============================================================================
// loc_target_gen.v -- position-target sequencer for the extended requirements
//                     (拓展1 位置控制 + 拓展2 速度曲线).
//
//   Strobes step the commanded target by the count carried on step_up /
//   step_down, clamped to +/-LIMIT (4080 = 10 arm revolutions, like the
//   reference).  The TARGET then RAMPES toward the command at RAMP_STEP
//   counts per DIV ms, so the arm follows a linear velocity profile while the
//   rod stays up -- the balance loop sees a slow-moving setpoint, not a step.
//
//   2026-10-28: the step size became a PORT.  The auto demo feeds one
//   revolution (408), the rotary knob feeds one detent (20); the ramp, the
//   clamp and the run gating are shared.  `clear` drops command and target
//   back to zero when the balance loop re-acquires the rod (top.v fires it on
//   the BAL entry edge, in the same tick that pendulum_ctrl re-zeroes
//   enc_base), so a re-captured rod never inherits an old target.
//
//   All state advances on tick_1k.  Button inputs are already strobes that
//   span a tick (from top.v edge detectors / knob_dec).
// ============================================================================
module loc_target_gen #(
    parameter integer STEP_HZ   = 2,        // ramp: revolutions per second
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
    input  wire        btn_up,       // strobe: cmd += step_up
    input  wire        btn_down,     // strobe: cmd -= step_down
    input  wire [15:0] step_up,      // counts per up strobe (408 demo / 20 knob)
    input  wire [15:0] step_down,    // counts per down strobe
    input  wire        clear,        // synchronous: cmd = target = 0
    input  wire        run,          // machine running (ramp only while run)
    output reg  signed [31:0] target,
    output reg         moving               // 1 while ramping (debug)
);
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

    localparam signed [31:0] LIM_NEG = -LIMIT;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd      <= 32'sd0;
            target   <= 32'sd0;
            moving   <= 1'b0;
            ramp_div <= 9'd0;
        end
        else if (tick_1k) begin
            // ---- strobe steps (hold across a tick, see header) ----
            if (btn_up)   cmd <= (cmd + step_up   >  LIM_S) ?  LIM_S : cmd + step_up;
            if (btn_down) cmd <= (cmd - step_down < LIM_NEG) ? LIM_NEG : cmd - step_down;
            // clear wins over a simultaneous strobe (placed last on purpose)
            if (clear) begin
                cmd    <= 32'sd0;
                target <= 32'sd0;
            end

            // ---- ramp toward cmd, one RAMP_STEP per DIV ms ----
            if (run && (target != cmd) && !clear) begin
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
