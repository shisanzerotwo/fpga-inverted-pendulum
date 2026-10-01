// 正交编码器四倍频解码：A/B 每个有效边沿计 1，A 超前 B 递增。
// 输入为异步信号：先两级同步，再要求连续 FILTER 拍一致才采信（抗毛刺，对应 STM32 输入滤波）。
// 方向约定仅在本模块内有效；物理正方向由边界模块的 ENC_SIGN 单点定义。
module quad_decoder #(
    parameter FILTER = 4
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               enc_a,
    input  wire               enc_b,
    output reg  signed [31:0] count
);
    // 两级同步
    reg [1:0] a_sync, b_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_sync <= 2'b00;
            b_sync <= 2'b00;
        end else begin
            a_sync <= {a_sync[0], enc_a};
            b_sync <= {b_sync[0], enc_b};
        end
    end
    wire [1:0] ab_raw = {a_sync[1], b_sync[1]};

    // 滤波：原始值与当前稳定值不同且连续 FILTER 拍保持，才更新稳定值
    reg [1:0]  ab_stable;
    reg [7:0]  flt_cnt;
    reg [1:0]  ab_cand;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ab_stable <= 2'b00;
            ab_cand   <= 2'b00;
            flt_cnt   <= 8'd0;
        end else if (ab_raw == ab_stable) begin
            flt_cnt <= 8'd0;
        end else if (ab_raw != ab_cand) begin
            ab_cand <= ab_raw;
            flt_cnt <= 8'd1;
        end else if (flt_cnt >= FILTER - 1) begin
            ab_stable <= ab_cand;
            flt_cnt   <= 8'd0;
        end else begin
            flt_cnt <= flt_cnt + 1'b1;
        end
    end

    // 前后稳定状态查表：格雷码相邻一步计 ±1，其余（不变/两相同变）计 0
    reg [1:0] ab_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ab_prev <= 2'b00;
            count   <= 32'sd0;
        end else begin
            ab_prev <= ab_stable;
            case ({ab_prev, ab_stable})
                // 正转 00->10->11->01->00
                4'b00_10, 4'b10_11, 4'b11_01, 4'b01_00: count <= count + 32'sd1;
                // 反转 00->01->11->10->00
                4'b00_01, 4'b01_11, 4'b11_10, 4'b10_00: count <= count - 32'sd1;
                default: ;
            endcase
        end
    end
endmodule
