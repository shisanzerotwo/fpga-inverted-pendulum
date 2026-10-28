`timescale 1ns/1ps
// ============================================================================
// knob_dec.v -- mechanical rotary-encoder front end (KY-040 class module).
//
//   The knob module sits on the G1 header: CLK/DT = the two quadrature
//   phases, SW = its own push button, powered from the header's 3V3 so the
//   outputs swing 0..3.3 V into 3.3 V banks.  The module carries 10 k
//   pull-ups, so the FPGA pins stay PULL_MODE=NONE.
//
//   Why a separate decoder: the motor's own encoder goes through
//   enc_decoder.v with an 80 ns filter, which is far too short for a knob's
//   mechanical contacts (1~10 ms of bounce per edge).  Here every accepted
//   phase state must be stable DEB_MS before it counts, and one detent is
//   PHASE_PER_DETENT quadrant transitions (4 for the standard module).
//
//   Output strobes follow the 2026-10-26 pulse contract: a strobe is SET in
//   the tick cycle where the event is detected and CLEARED at a LATER tick,
//   so a consumer that samples on tick_1k always sees it.  (A 20 ns pulse
//   lands on the tick-high cycle with probability 1/50000.)
// ============================================================================
module knob_dec #(
    parameter integer DEB_MS           = 3,    // phase / button stable time
    parameter integer PHASE_PER_DETENT = 4,    // quadrature transitions per click
    parameter integer SW_LOCK_MS       = 50,   // one toggle per press
    parameter         INVERT           = 1'b0  // 1 = flip the counting direction
) (
    input  wire clk,
    input  wire rst_n,
    input  wire tick_1k,        // 1 kHz strobe
    input  wire a,              // module CLK pin
    input  wire b,              // module DT pin
    input  wire sw_n,           // module SW pin, active low
    output reg  step_up,        // one detent, counting up
    output reg  step_down,      // one detent, counting down
    output reg  sw_toggle       // one debounced press (1 ms wide)
);
    localparam [3:0] DEB_W  = DEB_MS;
    localparam [3:0] PH_W   = PHASE_PER_DETENT;
    localparam [5:0] LOCK_W = SW_LOCK_MS;

    wire [1:0] q_now = {a, b};

    reg [1:0] q_stable;         // last accepted phase
    reg [3:0] phase;            // transitions seen inside the current detent
    reg [3:0] deb_cnt;          // ms the sampled phase has disagreed
    reg [3:0] sw_deb;           // ms the sampled button has disagreed
    reg       sw_stable;        // debounced button (1 = released)
    reg [5:0] lock_cnt;         // ms of toggle lock remaining
    reg       primed;           // first tick: adopt the pins, decode nothing

    // one accepted transition = 1 only for adjacent states; e_up says which
    // way.  Two-phase jump = contact bounce artefact, dropped.
    reg       e_valid;
    reg       e_up;
    always @(*) begin
        e_valid = 1'b1;
        e_up    = 1'b1;
        case ({q_stable, q_now})
            4'b00_01, 4'b01_11, 4'b11_10, 4'b10_00: ;           // clockwise
            4'b00_10, 4'b10_11, 4'b11_01, 4'b01_00: e_up = 1'b0; // counter
            default: e_valid = 1'b0;
        endcase
    end

    wire e_up_eff = INVERT ? ~e_up : e_up;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_stable  <= 2'b00;
            phase     <= 4'd0;
            deb_cnt   <= 4'd0;
            sw_deb    <= 4'd0;
            sw_stable <= 1'b1;
            lock_cnt  <= 6'd0;
            primed    <= 1'b0;
            step_up   <= 1'b0;
            step_down <= 1'b0;
            sw_toggle <= 1'b0;
        end
        else if (tick_1k) begin
            // cleared at a tick AFTER being seen (set below wins)
            step_up   <= 1'b0;
            step_down <= 1'b0;
            sw_toggle <= 1'b0;
            if (lock_cnt != 6'd0) lock_cnt <= lock_cnt - 6'd1;

            if (!primed) begin
                primed    <= 1'b1;
                q_stable  <= q_now;
                sw_stable <= sw_n;
                deb_cnt   <= 4'd0;
                sw_deb    <= 4'd0;
            end
            else begin
                // ---- quadrature: accept after DEB_MS of agreement ----
                if (q_now == q_stable) begin
                    deb_cnt <= 4'd0;
                end
                else if (deb_cnt >= DEB_W - 4'd1) begin
                    deb_cnt  <= 4'd0;
                    q_stable <= q_now;
                    if (e_valid) begin
                        if (e_up_eff) begin
                            if (phase >= PH_W - 4'd1) begin
                                step_up <= 1'b1;
                                phase   <= 4'd0;
                            end
                            else phase <= phase + 4'd1;
                        end
                        else begin
                            if (phase == 4'd0) begin
                                step_down <= 1'b1;
                                phase     <= PH_W - 4'd1;
                            end
                            else phase <= phase - 4'd1;
                        end
                    end
                end
                else deb_cnt <= deb_cnt + 4'd1;

                // ---- push button: debounce, then one toggle per press ----
                if (sw_n == sw_stable) begin
                    sw_deb <= 4'd0;
                end
                else if (sw_deb >= DEB_W - 4'd1) begin
                    sw_deb    <= 4'd0;
                    sw_stable <= sw_n;
                    if (sw_n == 1'b0 && lock_cnt == 6'd0) begin
                        sw_toggle <= 1'b1;   // press edge
                        lock_cnt  <= LOCK_W;
                    end
                end
                else sw_deb <= sw_deb + 4'd1;
            end
        end
    end

endmodule
