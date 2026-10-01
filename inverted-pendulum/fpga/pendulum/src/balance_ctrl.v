module balance_ctrl #(
    parameter integer CLK_HZ   = 50_000_000,
    parameter integer ANG_DIV  = 5,          // 摆角环分频：每 ANG_DIV 个 1kHz 拍算一次
    parameter integer LOC_DIV  = 50,         // 位置环分频
    parameter integer WIN      = 5000        // 平衡窗口：|误差| >= WIN（0.1 码值单位）即出窗
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               stale,
    input  wire [11:0]        adc_code,
    input  wire signed [31:0] loc,
    output wire               ang_tick,
    output wire               loc_tick,
    output wire signed [31:0] tgt_x10,
    output wire signed [7:0]  u_dir,
    output wire               u_mag,
    output wire               en
);
    localparam integer TICK_DIV = CLK_HZ / 1000;    // 1kHz 基准 = 50000 时钟

    // 三级分频：1kHz 基准 -> 摆角环每 ANG_DIV 拍（200Hz）-> 位置环每 LOC_DIV 拍（20Hz）。
    // LOC_DIV 以 1kHz 拍为计数单位（参考实现：照角环 Count1>=5、位置环 Count2>=50，均按 1kHz 计）
    reg [15:0] tick_cnt = 16'd0;
    reg [15:0] ang_cnt  = 16'd0;
    reg [15:0] loc_cnt  = 16'd0;

    wire tick_1k = (tick_cnt == TICK_DIV - 1);
    wire ang_t   = tick_1k && (ang_cnt == ANG_DIV - 1);
    wire loc_t   = tick_1k && (loc_cnt == LOC_DIV - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= 16'd0;
            ang_cnt  <= 16'd0;
            loc_cnt  <= 16'd0;
        end else if (tick_1k) begin
            tick_cnt <= 16'd0;
            ang_cnt  <= ang_t ? 16'd0 : ang_cnt + 1'b1;
            loc_cnt  <= loc_t ? 16'd0 : loc_cnt + 1'b1;   // 两个分频计数器都按 1kHz 拍计数
        end else begin
            tick_cnt <= tick_cnt + 1'b1;
        end
    end

    assign ang_tick = ang_t;
    assign loc_tick = loc_t;
    assign tgt_x10  = 32'sd20100;
    assign u_dir    = 8'sd0;
    assign u_mag    = 1'b0;
    assign en       = 1'b0;
endmodule
