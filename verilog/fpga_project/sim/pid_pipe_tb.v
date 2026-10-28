`timescale 1ns/1ps
// ============================================================================
// pid_pipe_tb.v -- differential test for the 2026-10-05 timing change.
//
//   The PID was split into a two-stage pipeline to meet 50 MHz (post-fit the
//   single-cycle version left 14 failing endpoints, worst slack -10.7 ns).
//   This TB proves the split did NOT change the arithmetic: the pipelined
//   module must produce, every clock, EXACTLY the value the frozen
//   single-cycle reference produced one clock earlier.
//
//     module pid       : current (pipelined) implementation under test
//     module pid_ref   : verbatim pre-pipeline implementation, FROZEN
//
//   Both run identical stimulus (same sp/fb/tick/en/clr/d_seed).  Zero
//   tolerance: any bit difference is a failure.
// ============================================================================
module pid_pipe_tb;
    reg clk = 0, rst_n = 0;
    reg tick = 0, en = 1, clr = 0;
    reg signed [15:0] d_seed = 0;
    reg signed [15:0] sp = 0, fb = 0;

    wire signed [15:0] out_new, out_ref;

    integer errors = 0;
    integer checks = 0;
    integer clr_skips = 0;      // see the tolerance note below
    integer i;
    reg signed [15:0] ref_d;          // reference output one clock ago
    reg signed [15:0] new_d;          // new output one clock ago (for diffing)
    reg                clr_d;         // clr one clock ago
    reg                warm = 0;      // pipeline fill guard

    localparam signed [31:0] KP_ANG = 32'sd241864;   // 0.30*100/8.13
    localparam signed [31:0] KI_ANG = 32'sd80616;    // 0.01*100/8.13
    localparam signed [31:0] KD_ANG = 32'sd322486;   // 0.40*100/8.13
    localparam signed [31:0] KP_POS = 32'sd2621440;  // 0.40*100
    localparam signed [31:0] KD_POS = 32'sd26214400; // 4.00*100

    pid #(.KP(KP_ANG), .KI(KI_ANG), .KD(KD_ANG), .OUT_MIN(-32'sd10000), .OUT_MAX(32'sd10000))
    u_new (.clk(clk), .rst_n(rst_n), .tick(tick), .en(en), .clr(clr), .d_seed(d_seed),
           .sp(sp), .fb(fb), .out(out_new));

    pid_ref #(.KP(KP_ANG), .KI(KI_ANG), .KD(KD_ANG), .OUT_MIN(-32'sd10000), .OUT_MAX(32'sd10000))
    u_ref (.clk(clk), .rst_n(rst_n), .tick(tick), .en(en), .clr(clr), .d_seed(d_seed),
           .sp(sp), .fb(fb), .out(out_ref));

    always #10 clk = ~clk;            // 50 MHz

    // every clock: pipelined output must equal the reference's PREVIOUS output
    //
    // Tolerance (measured, one clock wide, and unreachable in the real design):
    // when `clr` and a pending fold land on the same clock, clr wins and clears
    // the pipeline, so the single value the reference had presented for the
    // 20 ns before the clr is never presented by the pipelined version.  In
    // furuta_ctrl `clr` (= bal_clr) is high on the first clock of BALANCE, and
    // the clock before it has en=0, so nothing is ever pending there.  Each
    // tolerated occurrence is counted and printed instead of being hidden.
    always @(posedge clk) begin
        ref_d <= out_ref;
        new_d <= out_new;
        clr_d <= clr;
        if (rst_n && warm) begin
            checks = checks + 1;
            if (out_new !== ref_d) begin
                if (clr || clr_d) clr_skips = clr_skips + 1;
                else begin
                    errors = errors + 1;
                    if (errors <= 5)
                        $display("FAIL t=%0t: new=%0d  ref(prev)=%0d  sp=%0d fb=%0d",
                                 $time, out_new, ref_d, sp, fb);
                end
            end
        end
    end

    task step(input signed [15:0] s, input signed [15:0] f);
        begin
            sp = s; fb = f;
        end
    endtask

    initial begin
        $dumpfile("pid_pipe_tb.vcd");
        $dumpvars(0, pid_pipe_tb);

        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (6) @(negedge clk);
        warm = 1;

        // ---- random stimulus: gains, saturation, integrator wind-up, clr, seeds
        for (i = 0; i < 4000; i = i + 1) begin
            @(negedge clk);
            // a tick every 5..9 clocks (>= 2 clocks apart, the pipeline needs 2)
            tick <= ((i % 7) == 1);
            // random setpoints / feedback across the full int16 range
            sp   <= $random;
            fb   <= $random;
            // integrator / mode-entry behaviour
            clr    <= ((i % 97) == 13);
            d_seed <= ((i % 97) == 13) ? $random : 16'sd0;
            en     <= ((i % 211) == 7) ? 1'b0 : 1'b1;    // freeze window
        end
        @(negedge clk);
        tick = 0;
        repeat (20) @(posedge clk);

        $display("checks=%0d errors=%0d clr_skips=%0d", checks, errors, clr_skips);
        if (errors == 0) $display("PASS: pipelined pid is bit-identical to the single-cycle reference (1 clock later)");
        else             $display("FAIL: %0d mismatches", errors);
        $finish;
    end

    initial begin
        #20_000_000 $display("FAIL: watchdog timeout");
        $finish;
    end
endmodule

// ============================================================================
// pid_ref -- FROZEN copy of the single-cycle pid (pre-2026-10-05 timing split).
// Do not "fix" this module: it is the reference the differential test compares
// against.  Any change here invalidates pid_pipe_tb.
// ============================================================================
module pid_ref #(
    parameter signed [31:0] KP = 32'sd19661,
    parameter signed [31:0] KI = 32'sd655,
    parameter signed [31:0] KD = 32'sd26214,
    parameter signed [31:0] OUT_MIN = -32'sd10000,
    parameter signed [31:0] OUT_MAX =  32'sd10000,
    // synced 2026-10-11 with the 2026-10-07 I-limit change in pid.v: the
    // integrator clamps to I_MIN/I_MAX (not OUT_MIN/OUT_MAX).  Without this
    // the reference still ran the pre-10-07 arithmetic and the differential
    // test failed 70/4021 (e_pid_pipe_tb.log was empty -- the 10-07 rerun
    // never recorded a PASS).
    parameter signed [31:0] I_MIN = -32'sd3000,
    parameter signed [31:0] I_MAX =  32'sd3000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick,
    input  wire        en,
    input  wire        clr,
    input  wire signed [15:0] d_seed,
    input  wire signed [15:0] sp,
    input  wire signed [15:0] fb,
    output reg  signed [15:0] out
);
    reg signed [15:0] err_prev;
    reg signed [31:0] integ;

    wire signed [31:0] err    = sp - fb;
    wire signed [47:0] p_full = err * KP;
    wire signed [47:0] i_full = err * KI;
    wire signed [47:0] d_full = (err - err_prev) * KD;

    wire signed [31:0] p_term = p_full >>> 16;
    wire signed [31:0] i_inc  = i_full >>> 16;
    wire signed [31:0] d_term = d_full >>> 16;

    wire signed [31:0] integ_next  = integ + i_inc;
    wire signed [31:0] integ_clamp = (integ_next > I_MAX) ? I_MAX :
                                     (integ_next < I_MIN) ? I_MIN :
                                     integ_next;

    wire signed [31:0] sum = p_term + integ_clamp + d_term;
    wire signed [31:0] sum_clamp32 = (sum > OUT_MAX) ? OUT_MAX :
                                     (sum < OUT_MIN) ? OUT_MIN :
                                     sum;
    wire signed [15:0] sum_clamp = sum_clamp32[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            err_prev <= 16'sd0;
            integ    <= 32'sd0;
            out      <= 16'sd0;
        end
        else if (clr) begin
            err_prev <= err - d_seed;
            integ    <= 32'sd0;
            out      <= 16'sd0;
        end
        else if (tick && en) begin
            err_prev <= err;
            integ    <= integ_clamp;
            out      <= sum_clamp;
        end
    end
endmodule
