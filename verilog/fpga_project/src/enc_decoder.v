`timescale 1ns/1ps

module enc_decoder #(
    parameter integer FILTER     = 4,       // clocks the input must stay stable
    parameter         DIR_INVERT = 1'b0,    // 1 = flip counting direction
    parameter integer DW         = 32       // position width
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 tick,       // 1-clock strobe
    input  wire                 EA,
    input  wire                 EB,
    output reg  signed [DW-1:0] pos,
    output reg  signed [DW-1:0] delta,
    output wire                 dir,
    // per-edge taps for T-method velocity measurement (t_measure.v)
    output wire                 edge_strobe, // 1-clock pulse per accepted edge
    output wire                 edge_dir     // direction of that edge
);

    // ---------------------------------------------------------------- sync ---
    reg ea_s0, ea_s1, eb_s0, eb_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ea_s0 <= 1'b0; ea_s1 <= 1'b0;
            eb_s0 <= 1'b0; eb_s1 <= 1'b0;
        end else begin
            ea_s0 <= EA;   ea_s1 <= ea_s0;
            eb_s0 <= EB;   eb_s1 <= eb_s0;
        end
    end

    // ------------------------------------------------------------- deglitch ---
    reg  ea_f, eb_f;
    reg  [15:0] ea_cnt, eb_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ea_f <= 1'b0; ea_cnt <= 16'd0;
            eb_f <= 1'b0; eb_cnt <= 16'd0;
        end else begin
            if (ea_s1 != ea_f) begin
                if (ea_cnt >= FILTER-1) begin ea_f <= ea_s1; ea_cnt <= 16'd0; end
                else                          ea_cnt <= ea_cnt + 16'd1;
            end else ea_cnt <= 16'd0;

            if (eb_s1 != eb_f) begin
                if (eb_cnt >= FILTER-1) begin eb_f <= eb_s1; eb_cnt <= 16'd0; end
                else                          eb_cnt <= eb_cnt + 16'd1;
            end else eb_cnt <= 16'd0;
        end
    end

    // -------------------------------------------------- 4x decode: 1 step ---
    // Gray sequence forward : 00 -> 01 -> 11 -> 10 -> 00
    // Gray sequence reverse : 00 -> 10 -> 11 -> 01 -> 00
    // idx = {previous ab, current ab}; the four "one bit changed" codes each
    // way are the only legal transitions.  Both-bits-changed codes (0011,
    // 0110, 1001, 1100) are treated as noise and ignored.
    reg  [1:0] ab_prev;
    wire [1:0] ab  = {ea_f, eb_f};
    wire [3:0] idx = {ab_prev, ab};

    wire up   = (idx == 4'b0001) || (idx == 4'b0111) ||
                (idx == 4'b1000) || (idx == 4'b1110);
    wire down = (idx == 4'b0010) || (idx == 4'b0100) ||
                (idx == 4'b1011) || (idx == 4'b1101);

    wire inc = DIR_INVERT ? down : up;
    wire dec = DIR_INVERT ? up   : down;

    assign edge_strobe = inc | dec;         // 1-clock pulse per accepted edge
    assign edge_dir    = inc;               // 1 = + direction edge

    // dir is a LATCHED level (the direction of the last accepted edge), so the
    // rest of the design can sample it at any time -- not a one-cycle pulse.
    reg dir_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)   dir_r <= 1'b0;
        else if (inc) dir_r <= 1'b1;
        else if (dec) dir_r <= 1'b0;
    end
    assign dir = dir_r;

    // ------------------------------------------------- position and delta ---
    wire signed [DW-1:0] pos_next = inc ? (pos + 1'b1) :
                                    dec ? (pos - 1'b1) : pos;

    reg signed [DW-1:0] pos_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ab_prev  <= 2'b00;
            pos      <= {DW{1'b0}};
            pos_prev <= {DW{1'b0}};
            delta    <= {DW{1'b0}};
        end else begin
            ab_prev <= ab;
            pos     <= pos_next;

            if (tick) begin
                delta    <= pos_next - pos_prev;
                pos_prev <= pos_next;
            end
        end
    end

endmodule
