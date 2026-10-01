// 位置式 PID（整数域），语义照搬江协 User/PID.c：
//   E1 <- E0；E0 = target − actual；ΣE += E0（Ki=0 时 ΣE 恒清零）；ΣE 饱和到 ±INT_LIM（抗饱和）
//   Out = (KP·E0 + KI·ΣE + KD·(E0−E1)) / DIV，向零截断（= float→int8_t），限幅 ±OUT_MAX
// 增益用"整数 / DIV"精确表示参考的十进制系数，例：角度环 0.3/0.01/0.4 = 30/1/40 ÷ 1000（输入按 ×10 定标）。
// 除法为顺序恢复除法；tick 后约 QB+4 个时钟出 done（OUT_MAX=100 时 ≈11 拍）；
// tick 仅在空闲时被接收（控制节拍 200Hz/20Hz 远慢于计算时延）。
module pid #(
    parameter integer KP      = 30,
    parameter integer KI      = 1,
    parameter integer KD      = 40,
    parameter integer DIV     = 1000,
    parameter integer OUT_MAX = 100,
    parameter integer INT_LIM = 100000
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,
    input  wire               clr_int,
    input  wire signed [31:0] target,
    input  wire signed [31:0] actual,
    output reg  signed [31:0] out,
    output reg                done
);
    // 商位数：限幅后 |Out| <= OUT_MAX，故只需 clog2(OUT_MAX+1) 位
    localparam integer QB      = $clog2(OUT_MAX + 1);
    localparam [63:0]  SAT_ABS = OUT_MAX * DIV;         // |sum| >= 此值 -> 直接饱和到 OUT_MAX

    // 三级流水（50MHz 下单拍完成"减法→积分限幅→乘加→取模→比较"余量仅 0.5%，实测 50.2MHz）：
    //   S_IDLE 锁存误差/积分 → S_SUM 乘加 → S_ABS 取模与饱和判断 → S_DIV 恢复除法 → S_OUT
    localparam S_IDLE = 3'd0, S_SUM = 3'd1, S_ABS = 3'd2, S_DIV = 3'd3, S_OUT = 3'd4;

    reg signed [31:0] e0, e1, ei;
    reg signed [31:0] de;                               // 本拍 E0−E1
    reg signed [63:0] sum_r;
    reg        [2:0]  st;
    reg               neg;
    reg        [63:0] rem;
    reg        [31:0] quo;
    reg        [5:0]  bitn;

    wire signed [31:0] e_new  = target - actual;
    // 积分：ΣE + E0 饱和到 ±INT_LIM（抗饱和，参考实现无此项；纪律 §5）；
    // KI=0 时 ΣE 恒为 0（参考 Ki==0 清零语义；端口不可观测，因 0·ΣE≡0）
    // clr_int 与 tick 同拍：先清零再累加本拍 E0（= 参考"进平衡态清 ErrorInt → 下一次 PID_Update"）
    wire signed [31:0] ei_base = clr_int ? 32'sd0 : ei;
    wire signed [32:0] ei_raw = $signed({ei_base[31], ei_base}) + $signed({e_new[31], e_new});
    wire signed [31:0] ei_new = (KI == 0)              ? 32'sd0 :
                                (ei_raw >  INT_LIM)    ? INT_LIM :
                                (ei_raw < -INT_LIM)    ? -INT_LIM :
                                                         ei_raw[31:0];
    // S_SUM 紧接 S_IDLE 且只占 1 拍：此拍读到的 ei 必为本拍新值（途中 clr_int 最早在此拍末才生效）
    wire signed [63:0] sum    = $signed(KP) * e0 + $signed(KI) * ei + $signed(KD) * de;
    wire        [63:0] sum_abs = sum_r[63] ? -sum_r : sum_r;
    wire        [63:0] dsh    = (64'd0 + DIV) << bitn;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e0 <= 0; e1 <= 0; ei <= 0; de <= 0; sum_r <= 0;
            st <= S_IDLE; neg <= 1'b0;
            rem <= 0; quo <= 0; bitn <= 0;
            out <= 32'sd0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (st)
                S_IDLE: if (tick) begin
                    e1   <= e0;
                    e0   <= e_new;
                    de   <= e_new - e0;
                    ei   <= ei_new;
                    st   <= S_SUM;
                end
                S_SUM: begin
                    sum_r <= sum;
                    st    <= S_ABS;
                end
                S_ABS: begin
                    neg  <= sum_r[63];
                    rem  <= sum_abs;                        // 向零截断 = 对模做除法再补号
                    bitn <= QB - 1;
                    if (sum_abs >= SAT_ABS) begin           // 输出限幅：|Out| >= OUT_MAX 直接饱和
                        quo <= OUT_MAX;
                        st  <= S_OUT;
                    end else begin
                        quo <= 0;
                        st  <= S_DIV;
                    end
                end
                S_DIV: begin                                // 恢复除法：自高位起逐位试减 DIV<<bitn
                    if (rem >= dsh) begin
                        rem <= rem - dsh;
                        quo <= quo | (32'd1 << bitn);
                    end
                    if (bitn == 0) st <= S_OUT;
                    else           bitn <= bitn - 1'b1;
                end
                S_OUT: begin
                    out  <= neg ? -$signed(quo) : $signed(quo);
                    done <= 1'b1;
                    st   <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
            // 单独的 clr_int：任意状态均清 ΣE（只清积分，不动 E0/E1；同拍 tick 时已在上面合并处理）
            if (clr_int && !(st == S_IDLE && tick)) ei <= 32'sd0;
        end
    end
endmodule
