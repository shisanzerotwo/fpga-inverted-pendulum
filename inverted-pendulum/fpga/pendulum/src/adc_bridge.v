// GD32 -> FPGA 摆角 ADC 码值桥（单线 UART 接收，8N1）。
// 帧格式（4 字节）：0xA5 | {4'b0, code[11:8]} | code[7:0] | chk = A5 ^ hi ^ lo
// GD32 只做"采样 + 原码转发"，本模块只收帧与校验，不做任何滤波/换算（合规分工）。
// 输出：code = 最近一帧校验通过的原始码值；valid = 收到合法帧打一拍；
//       stale = 超过 TIMEOUT_MS 无合法帧（含上电后从未收到）为 1，控制侧据此进安全态。
//
// 波特率容限（发送端相对偏差 e，接收端为本地时钟）：
//   起始沿经两级同步后，在起始位约 0.49 位处复核，之后每 BIT_CLKS 采一位，
//   第 k 位（k=0 起始位 … 9 停止位）的采样点约在 k+0.49 个接收位处。
//   须落在发送端第 k 位内：k(1+e) <= k+0.49 < (k+1)(1+e)，k=9 最紧：
//   发送端偏快 e > -0.51/10 = -5.1%；偏慢 e <= 0.49/9 = +5.4%（±1 个时钟的同步相位抖动）。
//   实测（tb 切片 8 扫描）：-4.8% ~ +5.5% 全对，-5.0% / +6.0% 失败。
//   两侧均为晶振派生时实际偏差在 ppm 量级，余量充足；GD32 侧分频误差待固件定稿后核算。
module adc_bridge #(
    parameter CLK_HZ     = 50_000_000,
    parameter BAUD       = 1_000_000,
    parameter TIMEOUT_MS = 5
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx,
    output reg  [11:0] code,
    output reg         valid,
    output reg         stale
);
    localparam BIT_CLKS  = CLK_HZ / BAUD;
    localparam HALF_CLKS = BIT_CLKS / 2;

    // ---------------- 两级同步 ----------------
    reg [1:0] rx_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_sync <= 2'b11;
        else        rx_sync <= {rx_sync[0], rx};
    end
    wire rxs = rx_sync[1];

    // ---------------- UART 字节接收 ----------------
    localparam R_IDLE = 2'd0, R_START = 2'd1, R_DATA = 2'd2, R_STOP = 2'd3;
    reg [1:0]  r_state;
    reg [15:0] r_cnt;
    reg [2:0]  r_bit;
    reg [7:0]  r_shift;
    reg        byte_valid;
    reg [7:0]  byte_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_state    <= R_IDLE;
            r_cnt      <= 16'd0;
            r_bit      <= 3'd0;
            r_shift    <= 8'd0;
            byte_valid <= 1'b0;
            byte_data  <= 8'd0;
        end else begin
            byte_valid <= 1'b0;
            case (r_state)
                R_IDLE: if (!rxs) begin
                    r_state <= R_START;
                    r_cnt   <= 16'd0;
                end
                R_START: if (r_cnt == HALF_CLKS - 1) begin
                    // 起始位中点复核：仍为低才认，否则是毛刺
                    r_state <= rxs ? R_IDLE : R_DATA;
                    r_cnt   <= 16'd0;
                    r_bit   <= 3'd0;
                end else r_cnt <= r_cnt + 1'b1;
                R_DATA: if (r_cnt == BIT_CLKS - 1) begin
                    r_cnt   <= 16'd0;
                    r_shift <= {rxs, r_shift[7:1]};          // LSB 先到
                    if (r_bit == 3'd7) r_state <= R_STOP;
                    else               r_bit   <= r_bit + 1'b1;
                end else r_cnt <= r_cnt + 1'b1;
                R_STOP: if (r_cnt == BIT_CLKS - 1) begin
                    r_state <= R_IDLE;
                    if (rxs) begin                            // 停止位为 1 才算有效字节
                        byte_valid <= 1'b1;
                        byte_data  <= r_shift;
                    end
                end else r_cnt <= r_cnt + 1'b1;
            endcase
        end
    end

    // ---------------- 帧解析 ----------------
    localparam SYNC = 8'hA5;
    localparam F_SYNC = 2'd0, F_HI = 2'd1, F_LO = 2'd2, F_CHK = 2'd3;
    reg [1:0] f_state;
    reg [7:0] f_hi, f_lo;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_state <= F_SYNC;
            f_hi    <= 8'd0;
            f_lo    <= 8'd0;
            code    <= 12'd0;
            valid   <= 1'b0;
        end else begin
            valid <= 1'b0;
            if (byte_valid) begin
                case (f_state)
                    F_SYNC: if (byte_data == SYNC) f_state <= F_HI;
                    // hi 高 4 位必须为 0（12bit 码值的协议不变量）。不满足 = 当前是错位解析：
                    // 立即判帧错误；若该字节本身是 A5，就地当作新帧头（不再吞后两字节），
                    // 否则错位相位会被固定的 4 字节节拍永久锁住。
                    F_HI:   if (byte_data[7:4] != 4'd0)
                                f_state <= (byte_data == SYNC) ? F_HI : F_SYNC;
                            else begin
                                f_hi    <= byte_data;
                                f_state <= F_LO;
                            end
                    F_LO:   begin f_lo <= byte_data; f_state <= F_CHK; end
                    F_CHK:  begin
                        f_state <= F_SYNC;
                        if (byte_data == (SYNC ^ f_hi ^ f_lo)) begin
                            code  <= {f_hi[3:0], f_lo};
                            valid <= 1'b1;
                        end
                    end
                endcase
            end
        end
    end

    // ---------------- 超时 ----------------
    // 距最近一次合法帧满 TIMEOUT_MS 毫秒即置 stale；上电后从未收到合法帧也为 1（失效安全）
    localparam integer TIMEOUT_CLKS = (CLK_HZ / 1000) * TIMEOUT_MS;
    reg [31:0] to_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            to_cnt <= 32'd0;
            stale  <= 1'b1;
        end else if (valid) begin
            to_cnt <= 32'd0;
            stale  <= 1'b0;
        end else if (to_cnt >= TIMEOUT_CLKS - 1) begin
            stale  <= 1'b1;
        end else begin
            to_cnt <= to_cnt + 1'b1;
        end
    end
endmodule
