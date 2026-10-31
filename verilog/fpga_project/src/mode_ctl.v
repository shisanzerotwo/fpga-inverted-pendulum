`timescale 1ns/1ps
// ============================================================================
// mode_ctl.v -- AUTO / MANUAL state, runtime toggle only.
//
//   AUTO   (power-up default): top.v runs the 13 s position-demo cycle while
//          the rod is balanced.
//   MANUAL : no automatic motion (a hand push on the rod is the resistance
//          test) and the rotary knob dials the position target.
//
//   The 2026-10-28 boot gesture ("hold KEY1 while KEY0 releases = demo off")
//   is GONE (2026-10-30): KEY1 is run/stop only again, and power-up is always
//   AUTO.  The knob's own push button (SW, K13) toggles at runtime.
//
//   WHY EDGE DETECTION: knob_dec.sw_toggle is a ~1 ms WIDE pulse, not a single
//   clock.  A level-sensitive flip inside a 50 MHz always-block would toggle
//   on every clock of the pulse, and 1000 clocks (even) lands back where the
//   state started -- bench symptom "pressing the knob does nothing" (2026-10-28,
//   build 0x9F9C).  Only the rising edge may toggle.
// ============================================================================
module mode_ctl (
    input  wire clk,
    input  wire rst_n,
    input  wire sw_toggle,      // 1 ms wide pulse from knob_dec
    output reg  mode_auto       // 1 = AUTO (demo), 0 = MANUAL
);
    reg  sw_d;
    wire sw_rise = sw_toggle & ~sw_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw_d      <= 1'b0;
            mode_auto <= 1'b1;          // fixed AUTO at power-up
        end
        else begin
            sw_d <= sw_toggle;
            if (sw_rise) mode_auto <= ~mode_auto;
        end
    end

endmodule
