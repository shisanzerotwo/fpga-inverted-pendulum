`timescale 1ns/1ps
// ============================================================================
// enc_zone.v -- walking zone indicator for the 7-segment bring-up display.
//
//   1 arm revolution = 408 counts -> 10 zones of ~41 counts (36 deg each).
//   ezone wraps 0..9 in the direction of rotation.
//
//   VERILOG TRAP (this module exists because of it): a part-select like
//   dz[8:0] is UNSIGNED even when dz is signed -- mixing it into signed
//   arithmetic silently turned dz = -1 into +511 and made ezone run away
//   backwards on the bench.  Rule here: signed 32-bit math everywhere,
//   no part-selects inside signed expressions.
// ============================================================================
module enc_zone #(
    parameter integer ZONE      = 41,       // counts per zone (408/10)
    parameter integer ZONE_MAX  = 9         // top zone (wraps to 0)
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire signed [31:0] pos,        // 4x decoded position
    output reg  [3:0]  ezone            // 0..ZONE_MAX, wraps
);
    localparam [3:0] ZONE_TOP = ZONE_MAX;
    reg signed [31:0] pos_prev;
    reg signed [31:0] acc;               // counts accumulated inside the zone

    wire signed [31:0] dz = pos - pos_prev;
    wire signed [31:0] acc_next = acc + dz;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pos_prev <= 32'sd0;
            acc      <= 32'sd0;
            ezone    <= 4'd0;
        end
        else begin
            pos_prev <= pos;
            if (acc_next >= ZONE) begin
                acc   <= acc_next - ZONE;
                ezone <= (ezone == ZONE_TOP) ? 4'd0 : ezone + 4'd1;
            end
            else if (acc_next <= -ZONE) begin
                acc   <= acc_next + ZONE;
                ezone <= (ezone == 4'd0) ? ZONE_TOP : ezone - 4'd1;
            end
            else begin
                acc <= acc_next;
            end
        end
    end

endmodule
