`timescale 1ns/1ps
// ============================================================================
// mode_ctl.v -- AUTO / MANUAL state with a boot default and a runtime toggle.
//
//   boot_mode   : 1 = AUTO.  Comes from demo_sel (hold KEY1 while KEY0
//                 releases -> 0), valid only after boot_decided.
//   sw_toggle   : a 1 ms wide pulse from knob_dec (knob button).  It MUST be
//                 edge-detected here: a level-sensitive toggle inside the
//                 50 MHz loop flips mode_auto on every clock of the pulse, and
//                 a pulse of exactly 1000 clocks (even) lands back where it
//                 started -- the bench symptom was "pressing the knob does
//                 nothing" (2026-10-28, first knob build 0x9F9C).
//
//   Pulled out of top.v on purpose: top.v has no testbench, and this is the
//   second defect of the "pulse width vs sampling clock" family in two days.
// ============================================================================
module mode_ctl (
    input  wire clk,
    input  wire rst_n,
    input  wire boot_mode,      // 1 = AUTO at power-up
    input  wire boot_decided,   // 1 once the boot sample is final
    input  wire sw_toggle,      // 1 ms wide pulse: one press
    output reg  mode_auto       // 1 = AUTO, 0 = MANUAL
);
    reg sw_d;
    wire sw_rise = sw_toggle & ~sw_d;    // one toggle per pulse, not per clock

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw_d      <= 1'b0;
            mode_auto <= 1'b1;
        end
        else begin
            sw_d <= sw_toggle;
            if (!boot_decided)   mode_auto <= boot_mode;
            else if (sw_rise)    mode_auto <= ~mode_auto;
        end
    end

endmodule
