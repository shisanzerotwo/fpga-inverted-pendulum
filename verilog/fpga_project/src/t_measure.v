`timescale 1ns/1ps
// ============================================================================
// t_measure.v -- T-method angular velocity from the quadrature edges.
//
//   Measures the clock interval T between accepted quadrature edges and
//   converts it to angular velocity with one sequential restoring division
//   per edge:
//
//       omega [0.1 deg/s] = NUM / T,   NUM = CLK_FREQ * 3600 / (EDGES*10)
//       (one edge = 360/408 deg = 8.82 units of 0.1 deg; 1/T revs per second)
//
//   Why T-method: at low speed the count-per-tick method resolves 882 deg/s
//   per count (1 count per 1 kHz tick) -- useless for the D-term and LQR.
//   The edge interval GROWS as speed falls, so T-method resolution improves
//   exactly where the pendulum spends its time.
//
//   Budget: worst case 4216 edges/s = one 32-cycle division every 11860
//   clocks at 50 MHz -- 370x margin.  T saturates and omega decays to 0
//   (valid=0) if edges stop arriving.
// ============================================================================
module t_measure #(
    parameter integer CLK_FREQ      = 50_000_000,
    parameter integer EDGES_PER_REV = 408,
    parameter integer T_TIMEOUT     = 67_000_000  // ~1.34 s no edge -> omega = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        edge_strobe,   // 1-clock pulse per accepted edge
    input  wire        edge_dir,      // 1 = + direction edge
    output reg  signed [15:0] omega,  // 0.1 deg/s, signed
    output reg  [25:0] period,       // debug: last edge interval, clocks
    output reg         valid         // 1 = edges arriving regularly
);
    localparam [25:0] T_SAT_W = T_TIMEOUT;             // truncate to 26 bits
    // divide BEFORE multiplying: CLK_FREQ*3600 would overflow 32-bit integers
    localparam [31:0] NUM     = (CLK_FREQ / EDGES_PER_REV) * 3600;

    reg [25:0] t_cnt;                  // clocks since the last edge
    reg        dir_r;

    // ---- sequential restoring divider: NUM / div_t ----
    reg        div_busy;
    reg [5:0]  div_cnt;
    reg [32:0] rem;                    // 33-bit working remainder
    reg [31:0] quot;
    reg [31:0] div_t;                  // divisor (latched T, min 2)

    wire [32:0] rem_shift = {rem[31:0], quot[31]};        // << 1
    wire [32:0] rem_try   = rem_shift - {1'b0, div_t};
    wire        rem_ok    = (rem_shift >= {1'b0, div_t});
    wire [31:0] quot_done = {quot[30:0], rem_ok};         // quotient after the
                                                          // 32nd shift
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_cnt    <= 26'd0;
            omega    <= 16'sd0;
            period   <= 26'd0;
            valid    <= 1'b0;
            dir_r    <= 1'b0;
            div_busy <= 1'b0;
            div_cnt  <= 6'd0;
            rem      <= 33'd0;
            quot     <= 32'd0;
            div_t    <= 32'd2;
        end
        else begin
            // ---- interval counter with saturation ----
            if (t_cnt != T_SAT_W)
                t_cnt <= t_cnt + 26'd1;

            // ---- timeout: edges stopped -> velocity decays to zero ----
            if (t_cnt == T_SAT_W) begin
                omega <= 16'sd0;
                valid <= 1'b0;
            end

            // ---- edge: latch interval, kick off a division ----
            if (edge_strobe) begin
                period   <= (t_cnt > T_SAT_W) ? T_SAT_W : t_cnt;
                div_t    <= (t_cnt < 26'd2)   ? 32'd2   : {6'd0, t_cnt};
                t_cnt    <= 26'd0;
                dir_r    <= edge_dir;
                div_busy <= 1'b1;
                div_cnt  <= 6'd0;
                rem      <= 33'd0;
                quot     <= NUM;
                valid    <= 1'b1;
            end

            // ---- divider core: 32 cycles of shift / conditional subtract ----
            if (div_busy) begin
                rem <= rem_ok ? rem_try : rem_shift;
                quot <= {quot[30:0], rem_ok};
                div_cnt <= div_cnt + 6'd1;
                if (div_cnt == 6'd31) begin
                    div_busy <= 1'b0;
                    // NOTE: use quot_done (the 32nd shift's result), not the
                    // pre-shift quot -- otherwise omega lands on HALF the
                    // true value (bench-verified bug).
                    if (!dir_r) begin
                        // positive: saturate at +32767
                        omega <= (quot_done[31:16] != 16'd0) ? 16'sd32767
                               : (quot_done[15:0] > 16'sd32767) ? 16'sd32767
                               : $signed(quot_done[15:0]);
                    end
                    else begin
                        // negative: saturate at -32768
                        omega <= (quot_done[31:16] != 16'd0) ? -16'sd32768
                               : (quot_done[15:0] > 16'sd32768) ? -16'sd32768
                               : -$signed(quot_done[15:0]);
                    end
                end
            end
        end
    end

endmodule
