// 平衡控制：节拍分频 + 双环级联 PID + 安全态。
// 与江协参考（TIM1 1kHz 中断、RunState==4 分支）对齐的部分：
//   - 摆角环每 5 拍（200Hz）用摆角 PID 输出直接驱动电机；
//   - 位置环每 50 拍（20Hz）算一次，输出改写摆角环目标：tgt = CENTER - loc_out；
//   - 两者同拍时先算摆角环、再算位置环（与参考 "先 AnglePID.Actual/PID_Update/Motor_SetPWM，再 Count2>=50 位置环" 一致）。
// 与参考不同的部分（有意为之，已标注）：
//   - 参考在出窗时停止调用 PID_Update 并清零积分；本实现 PID 持续运行、只把输出置安全态（en=0），
//     这样控制律是纯函数式可对拍；抗积分饱和由 pid 模块的 INT_LIM 负责。
//   - 起摆/能量甩摆（参考 RunState 1/21-24/31-34）不在此模块，后续单做。
// 定标：摆角 = ADC 码值 ×10（0.1 码值单位），位置 = 编码器计数，位置环输出 ×10。
module balance_ctrl #(
    parameter integer CLK_HZ   = 50_000_000,
    parameter integer ANG_DIV  = 5,          // 摆角环分频：每 ANG_DIV 个 1kHz 拍算一次（200Hz）
    parameter integer LOC_DIV  = 50,         // 位置环分频（20Hz），以 1kHz 拍计
    parameter integer WIN_X10  = 5000,       // 平衡窗口：|target-actual| >= WIN_X10 即出窗
    parameter integer CENTER_X10 = 20100     // 摆角垂直位 ADC 码值 ×10（实物校准）
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               stale,          // ADC 桥失效 -> 安全态
    input  wire [11:0]        adc_code,
    input  wire signed [31:0] loc,
    output wire               ang_tick,
    output wire               loc_tick,
    output wire signed [31:0] tgt_x10,
    output wire signed [7:0]  u_dir,
    output wire               u_mag,
    output wire               en
);
    localparam integer TICK_DIV = CLK_HZ / 1000;    // 1kHz 基准

    // 三级分频：1kHz -> 摆角环每 ANG_DIV 拍（200Hz）-> 位置环每 LOC_DIV 拍（20Hz）
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
            loc_cnt  <= loc_t ? 16'd0 : loc_cnt + 1'b1;
        end else begin
            tick_cnt <= tick_cnt + 1'b1;
        end
    end

    // ---------------- 双环级联 ----------------
    reg signed [31:0] tgt = CENTER_X10;

    wire signed [31:0] ang_out, loc_out;
    wire               ang_done, loc_done;

    // 摆角环：0.3/0.01/0.4 = 30/1/40 ÷ 1000（输入 ×10 定标）
    // 位置环：0.4/0/4 = 4/0/40 ÷ 1（输出直接为 0.1 码值单位），限幅 ±1000 = ±100 码值
    // 先扩位再乘：避免综合/仿真对"12 位无符号 × 常数"按 16 位截断（2410×10 会溢出 16 位）
    wire signed [31:0] adc_x10 = $signed({20'd0, adc_code}) * 32'sd10;
    pid #(.KP(30), .KI(1), .KD(40), .DIV(1000), .OUT_MAX(100), .INT_LIM(100000)) u_ang (
        .clk(clk), .rst_n(rst_n), .tick(ang_t), .clr_int(1'b0),
        .target(tgt), .actual(adc_x10), .out(ang_out), .done(ang_done));
    pid #(.KP(4), .KI(0), .KD(40), .DIV(1), .OUT_MAX(1000), .INT_LIM(100000)) u_loc (
        .clk(clk), .rst_n(rst_n), .tick(loc_t), .clr_int(1'b0),
        .target(32'sd0), .actual(loc), .out(loc_out), .done(loc_done));

    // 位置环改写摆角环目标（与参考一致：Target = CENTER − LocationPID.Out）。
    // 注意：pid 是流水线的，loc_t 当拍 loc_out 还是上一次的结果，必须等 loc_done 之后一拍再采
    // （参考是软件顺序执行，同一拍内 Out 已就绪；RTL 必须等 done，否则目标整体滞后一个位置环周期）。
    reg loc_done_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       loc_done_d <= 1'b0;
        else              loc_done_d <= loc_done;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           tgt <= CENTER_X10;
        else if (loc_done_d)  tgt <= CENTER_X10 - loc_out;
    end

    // ---------------- 安全态 ----------------
    wire signed [31:0] ang_err_x10 = tgt - adc_x10;                 // 0.1 码值单位
    wire safe = stale || (ang_err_x10 >= WIN_X10) || (ang_err_x10 <= -WIN_X10);

    assign ang_tick = ang_t;
    assign loc_tick = loc_t;
    assign tgt_x10  = tgt;
    assign u_dir    = safe ? 8'sd0 : ang_out[7:0];
    assign u_mag    = safe ? 1'b0  : (ang_out != 32'sd0);
    assign en       = ~safe;
endmodule
