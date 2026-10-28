`timescale 1ns/1ps
// ============================================================================
// demo_sel.v -- boot-time selector for the auto-demo (position rotation).
//
//   The 2026-10-26 demo sequencer walked the arm +/-1 rev every 13 s inside
//   BALANCE, which is exactly what the anti-push test must NOT have: a light
//   touch and the auto-rotation look identical in telemetry.  It used to be a
//   compile-time localparam, so switching modes meant a rebuild + reflash.
//
//   KEY1 cannot carry a runtime toggle: its press edge already toggles
//   run_latch, and the switch drops contact ~150 ms after a press (the
//   phantom edge that KEY_LOCK_MS exists for).  A release-edge or long-hold
//   scheme would let that phantom stop a live run.
//
//   So the mode is chosen where nothing is running yet -- at reset:
//       hold KEY1 (F10) while KEY0 (D11, rst_n) is released -> demo OFF
//       leave KEY1 alone                                   -> demo ON
//   The choice is sampled once in the first WIN_MS after reset; afterwards
//   KEY1 behaves exactly as before (press toggles run).
//
//   Contact bounce: a single sample could land on an open instant, so the
//   window COUNTS the milliseconds the key spends low and decides on a
//   majority (LOW_MS).  A press that starts before reset and is still down
//   most of the window is unambiguous even with the switch's dropouts.
// ============================================================================
module demo_sel #(
    parameter integer WIN_MS = 100,   // sampling window after reset, ms
    parameter integer LOW_MS = 60     // key low this long inside the window
                                      // = "held through reset" = demo OFF
) (
    input  wire clk,
    input  wire rst_n,
    input  wire tick_1k,        // 1 kHz strobe
    input  wire key_n,          // KEY1 raw, active low (0 = pressed)
    output reg  demo_on,        // 1 = auto-demo enabled (default)
    output wire decided         // 1 once the boot sample is latched; from then
                                // on the mode belongs to the runtime control
                                // (top.v hands it to the knob's push button)
);
    localparam [7:0] WIN_W = WIN_MS;   // equal-width relays (trap 9: a
    localparam [7:0] LOW_W = LOW_MS;   // narrower compare operand wraps)

    reg [7:0] win_ms;                  // window progress, saturating
    reg [7:0] low_ms;                  // ms the key was low in the window
    reg       locked;                  // decision taken; KEY1 is hands-off

    assign decided = locked;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_ms  <= 8'd0;
            low_ms  <= 8'd0;
            locked  <= 1'b0;
            demo_on <= 1'b1;           // default: demo ON, as before
        end
        else if (tick_1k && !locked) begin
            if (win_ms >= WIN_W) begin
                demo_on <= (low_ms >= LOW_W) ? 1'b0 : 1'b1;
                locked  <= 1'b1;
            end
            else begin
                win_ms <= win_ms + 8'd1;
                if (key_n == 1'b0 && low_ms != 8'hFF)
                    low_ms <= low_ms + 8'd1;
            end
        end
    end

endmodule
