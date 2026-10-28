`timescale 1ns/1ps
// ============================================================================
// alpha_dot.v -- pendulum angular velocity estimator (centideg/s) from the
//                200 Hz angle samples.
//
//   Sliding difference over K=9 samples (8 intervals x 5 ms = 40 ms window),
//   scaled to centideg/s, then a light one-pole low-pass:
//
//       raw  = clamp(alpha - hist[oldest]) * SCALE
//              // SCALE = 1 cdeg / window_seconds; hardware (200 Hz, 40 ms
//              // window) uses 25.  The tb runs 20 kHz sampling -> 2500.
//       adot += (raw - adot) >>> 3          // low-pass, tau ~ 8 samples
//
//   Resolution: ~1 LSB diff -> ~25 cdeg/s (hardware) -- ample for swing-up
//   energy pumping (rod speeds there are 10000~30000 cdeg/s).  diff is
//   clamped to +/-1200 LSB so a dead-zone wrap spike is capped instead of
//   flinging adot across the range.
// ============================================================================
module alpha_dot #(
    parameter integer K = 9,                 // samples in the window
    parameter signed [31:0] SCALE = 32'sd25  // cdeg/s per cdeg of diff
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick,          // sample strobe (200 Hz on hardware)
    input  wire signed [15:0] alpha,  // centideg
    output reg  signed [15:0] adot    // centideg/s, signed
);
    reg signed [15:0] hist [0:K-1];    // hist[0] = newest
    integer i;

    wire signed [31:0] diff    = alpha - hist[K-1];
    wire signed [31:0] diff_c  = (diff > 32'sd1200)  ? 32'sd1200  :
                                 (diff < -32'sd1200) ? -32'sd1200 : diff;
    wire signed [31:0] raw     = diff_c * SCALE;        // centideg/s
    wire signed [31:0] lp      = (raw - adot) >>> 3;    // low-pass STEP
    wire signed [31:0] nxt     = adot + lp;
    wire signed [31:0] nxt_c   = (nxt > 32'sd32767)  ? 32'sd32767  :
                                 (nxt < -32'sd32768) ? -32'sd32768 : nxt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < K; i = i + 1) hist[i] <= 16'sd0;
            adot <= 16'sd0;
        end
        else if (tick) begin
            for (i = K-1; i > 0; i = i - 1) hist[i] <= hist[i-1];
            hist[0] <= alpha;
            adot    <= nxt_c[15:0];
        end
    end

endmodule
