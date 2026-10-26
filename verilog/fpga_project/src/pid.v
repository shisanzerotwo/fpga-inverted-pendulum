`timescale 1ns/1ps
// ============================================================================
// pid.v -- generic fixed-point PID, instantiated twice (angle loop 200 Hz,
//          position loop 20 Hz).  Gains in Q16.16, I/O in signed 16-bit.
//
//   Per `tick` (one-clock strobe at the loop rate):
//       err   = sp - fb
//       P     = err * KP                  >> 16
//       I    += err * KI                  >> 16   (clamped: anti-windup)
//       D     = (err - err_prev) * KD     >> 16
//       out   = clamp(P + I + D, OUT_MIN, OUT_MAX)
//
//   Everything is registered behind `tick`, so the loop updates once per tick
//   and holds its output between ticks.
// ============================================================================
module pid #(
    parameter signed [31:0] KP = 32'sd19661,          // 0.30 in Q16.16
    parameter signed [31:0] KI = 32'sd655,            // 0.01
    parameter signed [31:0] KD = 32'sd26214,          // 0.40
    parameter signed [31:0] OUT_MIN = -32'sd10000,    // duty_x100 units
    parameter signed [31:0] OUT_MAX =  32'sd10000,
    // 2026-10-07: with a sustained error the integrator saturates at OUT_MAX
    // on its own, so P+D become irrelevant and the arm spins up until
    // centrifugal force pins the rod (bench: alpha frozen at -18 deg for 1.5 s
    // while enc ran +4366 counts).  I_LIMIT caps the I term alone so P and D
    // always keep their share of the output.
    parameter signed [31:0] I_MIN = -32'sd3000,
    parameter signed [31:0] I_MAX =  32'sd3000,
    // 2026-10-26 jitter/levelling work:
    //   D_SHIFT: incomplete-derivative low-pass (JiangXie B站 2-2).  The raw
    //   D eats ADC quantisation noise -- one 8.13-cdeg LSB between two 5 ms
    //   samples already commands Kd*8.13 of output -- and that noise drive is
    //   what pumps the observed 0.18 s / +/-2 deg limit cycle.  Smoothing the
    //   D term (one-pole, tau = 2^D_SHIFT ticks) removes the noise path while
    //   keeping phase lag small (18 deg at 5.5 Hz for D_SHIFT=1).
    //   D_SHIFT=0 restores the raw difference (old behaviour).
    //   I_BAND: integral separation (JiangXie position loop, threshold 100
    //   counts).  |err| >= I_BAND skips integration, so the integrator only
    //   trims the small steady error a pure PD loop leaves behind -- moving
    //   the arm does not wind it up.  I_BAND=0 integrates always.
    parameter integer D_SHIFT = 0,
    parameter integer I_BAND  = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick,        // 1-clock strobe at the loop rate
    input  wire        en,          // 0 = loop inactive: freeze, no integration
    input  wire        clr,         // 1 = wipe integrator + output (mode entry)
    input  wire signed [15:0] d_seed, // clr-time error-rate seed: err_prev is
                                    // preloaded to err-d_seed so the D term
                                    // starts at FULL strength on its first
                                    // tick (a fast rod outruns a D term that
                                    // builds up from zero -- bench-verified)
    input  wire signed [15:0] sp,
    input  wire signed [15:0] fb,
    output reg  signed [15:0] out
);
    reg signed [15:0] err_prev;
    reg signed [31:0] integ;

    // ---- TIMING 2026-10-05: two-stage pipeline ---------------------------
    // The single-cycle version packed one constant multiply AND two 32-bit
    // adds AND three clamp muxes into one 20 ns clock.  Post-fit that path
    // measured 35.05 ns (Fmax 32.5 MHz against a 50 MHz constraint) with the
    // failing endpoints inside this module.  Splitting after the products
    // keeps the arithmetic bit-identical and only delays `out` by one clock
    // (20 ns -- irrelevant for a 1 kHz / 200 Hz loop):
    //   stage 1 (on `tick`): err, err_prev and the three product terms
    //   stage 2 (next clock): integrator update, sum, clamps, out
    // Stage 2 is armed by `fold`, so each tick's products are folded exactly
    // once.  Assumption: consecutive ticks are >= 2 clocks apart (true at
    // 1 kHz and 200 Hz).  If a new tick landed on the same clock as a pending
    // fold, the load wins and `fold` stays armed -- no product is lost.
    // Verified bit-identical against the previous revision by
    // sim/pid_pipe_tb.v (same stimulus, out shifted by exactly one clock).
    reg signed [31:0] p_r, i_r, d_r;
    reg               fold;
    reg signed [31:0] d_filt;             // smoothed D term (see D_SHIFT)

    wire signed [31:0] err    = sp - fb;
    wire signed [47:0] p_full = err * KP;
    wire signed [47:0] i_full = err * KI;
    wire signed [47:0] d_full = (err - err_prev) * KD;

    wire signed [31:0] p_term = p_full >>> 16;
    wire signed [31:0] i_inc  = i_full >>> 16;
    wire signed [31:0] d_raw  = d_full >>> 16;
    // one-pole D smoothing: d_filt += (d_raw - d_filt) >>> D_SHIFT.
    // D_SHIFT=0 collapses to d_next == d_raw (arithmetic identity), so the
    // parameter costs nothing when disabled.
    wire signed [31:0] d_delta = d_raw - d_filt;
    wire signed [31:0] d_term  = d_filt + (d_delta >>> D_SHIFT);
    // integral separation: |err| >= I_BAND contributes nothing to the
    // integrator this tick (I_BAND=0 = always integrate)
    wire signed [31:0] err_mag  = (err < 0) ? -err : err;
    localparam signed [31:0] I_BAND_W = I_BAND;
    wire               integ_ok = (I_BAND == 0) || (err_mag < I_BAND_W);

    // integrate with a hard clamp: the integrator can never wind past I_MAX,
    // so recovery from saturation is immediate
    // (i_r / p_r / d_r are the stage-1 product registers)
    wire signed [31:0] integ_next  = integ + i_r;
    wire signed [31:0] integ_clamp = (integ_next > I_MAX) ? I_MAX :
                                     (integ_next < I_MIN) ? I_MIN :
                                     integ_next;

    // clamp in the full 32-bit domain FIRST, then narrow (a >15-bit limit
    // would silently wrap if narrowed before comparing)
    wire signed [31:0] sum = p_r + integ_clamp + d_r;
    wire signed [31:0] sum_clamp32 = (sum > OUT_MAX) ? OUT_MAX :
                                     (sum < OUT_MIN) ? OUT_MIN :
                                     sum;
    wire signed [15:0] sum_clamp = sum_clamp32[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            err_prev <= 16'sd0;
            integ    <= 32'sd0;
            out      <= 16'sd0;
            p_r      <= 32'sd0;
            i_r      <= 32'sd0;
            d_r      <= 32'sd0;
            d_filt   <= 32'sd0;
            fold     <= 1'b0;
        end
        else if (clr) begin
            // mode entry: zero the integrator/output, but preload err_prev
            // so the D term begins at full strength (no zero-to-full ramp
            // while the rod crosses the window in 20 ms)
            err_prev <= err - d_seed;   // D starts at full strength
            integ    <= 32'sd0;
            out      <= 16'sd0;
            p_r      <= 32'sd0;
            i_r      <= 32'sd0;
            d_r      <= 32'sd0;
            d_filt   <= 32'sd0;
            fold     <= 1'b0;
        end
        else begin
            // stage 1: sample err and the product terms, once per tick
            if (tick && en) begin
                err_prev <= err;
                p_r      <= p_term;
                i_r      <= integ_ok ? i_inc : 32'sd0;
                d_r      <= d_term;
                d_filt   <= d_term;      // advance the smoother
                fold     <= 1'b1;
            end
            // stage 2: fold the registered products, one clock after the tick
            if (fold) begin
                integ <= integ_clamp;
                out   <= sum_clamp;
                if (!(tick && en)) fold <= 1'b0;
            end
        end
    end

endmodule
