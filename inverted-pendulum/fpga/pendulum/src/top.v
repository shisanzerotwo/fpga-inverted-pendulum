// 倒立摆正式顶层（D3 整链集成版）：采集链 + 双环控制 + 电机 PWM，保留自检能力。
//
// 信号链（全部在 FPGA 内，MCU 只做 ADC 采样 + 原码转发）：
//   GD32 ADC 码值 --UART 1Mbaud--> adc_bridge --> sign_map(方向边界) --> balance_ctrl(双环 PID)
//                                                            |                    |
//   编码器 A/B --> quad_decoder ---------------------------> loc           u_ctrl |
//                                                                                v
//                                                                        sign_map --> pwm_gen --> 电机
//
// 板载 2 个 RGB 彩灯 = led[0..5] 六通道（极性未核实，见 AGENTS.md §5.1）：
//   led[0]=R9 心跳（约 1.5Hz）        led[1]=C10 跟随 D11
//   led[2]=R7 跟随 F10                led[3]=N6  编码器计数最低位（转动时闪）
//   led[4]=T10 控制使能 en（1=在控制，0=安全态）led[5]=P7 串口空闲时亮
//
// 串口（板上读 COM9）：每次心跳发 4 字节自检帧，一次上板可同时验多件事：
//   [0] 0xA5  帧头          [1] 编码器计数低 8 位
//   [2] adc_code 低 8 位    [3] PWM 幅值（|u|，0~100）
// 上电安全态：ADC 桥 stale 为 1（GD32 未发帧）时 balance_ctrl 输出 en=0、u=0，电机不动。
module top (
    input  wire       sys_clk,
    input  wire [1:0] key,
    output reg  [5:0] led,
    output wire       uart_tx,
    input  wire       uart_rx,
    output wire       pwma,
    output wire       ain1,
    output wire       ain2,
    input  wire       enc_a,
    input  wire       enc_b,
    input  wire       adc_rx,     // GD32 PA2(USART1_TX) -> K11，摆角 ADC 码值帧
    input  wire [3:0] kext
);
    // 上电后 FPGA 无独立复位脚，用计数器前几拍当复位。
    reg [3:0] rst_cnt = 4'd0;
    wire      rst_n   = &rst_cnt;
    always @(posedge sys_clk) if (!rst_n) rst_cnt <= rst_cnt + 1'b1;

    // ---------------- 采集链 ----------------
    // 摆角 ADC 码值桥（GD32 只采样转发；GD32 固件未就绪前 stale 恒为 1）
    wire [11:0] adc_code_raw;
    wire        adc_valid, adc_stale, adc_framing_err;
    adc_bridge #(.CLK_HZ(50_000_000), .BAUD(1_000_000), .TIMEOUT_MS(5)) u_ab (
        .clk(sys_clk), .rst_n(rst_n), .rx(adc_rx),
        .code(adc_code_raw), .valid(adc_valid), .stale(adc_stale),
        .framing_err(adc_framing_err)
    );

    // 编码器四倍频计数（输出轴一圈 408）
    wire signed [31:0] enc_raw;
    quad_decoder #(.FILTER(4)) u_qd (
        .clk(sys_clk), .rst_n(rst_n),
        .enc_a(enc_a), .enc_b(enc_b), .count(enc_raw)
    );

    // ---------------- 方向边界（纪律 §2：三个常数只在这里定义一次）----------------
    wire signed [7:0]  u_ctrl;      // 控制律输出（物理坐标，来自 balance_ctrl）
    wire [11:0]        adc_code;    // 物理坐标（角度环用）
    wire signed [31:0] enc;         // 物理坐标（位置环用）
    wire signed [7:0]  u_phys;      // 边界之后送执行器的输出
    sign_map #(
        .CENTER_CODE(2010),
        .ANGLE_SIGN(1),             // 实物 bring-up 手拨标定
        .MOTOR_SIGN(-1),
        .ENC_SIGN(1)
    ) u_sm (
        .adc_code_raw(adc_code_raw), .enc_raw(enc_raw), .u_ctrl(u_ctrl),
        .adc_code(adc_code), .enc(enc), .u(u_phys)
    );

    // ---------------- 控制律（物理坐标）----------------
    wire               ang_tick, loc_tick;
    wire signed [31:0] tgt_x10;
    wire               u_mag, en;
    balance_ctrl #(
        .CLK_HZ(50_000_000), .ANG_DIV(5), .LOC_DIV(50),
        .WIN_X10(5000), .CENTER_X10(20100)
    ) u_bc (
        .clk(sys_clk), .rst_n(rst_n), .stale(adc_stale),
        .adc_code(adc_code), .loc(enc),
        .ang_tick(ang_tick), .loc_tick(loc_tick), .tgt_x10(tgt_x10),
        .u_dir(u_ctrl), .u_mag(u_mag), .en(en)
    );

    // ---------------- 执行器 ----------------
    // en=0 时 pwm_gen 三路输出全 0，电机不动（上电与 stale 均落在这一支）
    pwm_gen #(.CLK_HZ(50_000_000), .PWM_HZ(20_000)) u_pwm (
        .clk(sys_clk), .rst_n(rst_n), .en(en), .u(u_phys),
        .pwma(pwma), .ain1(ain1), .ain2(ain2)
    );

    // ---------------- 自检：串口回传 4 字节帧 ----------------
    reg [7:0] tx_byte  = 8'd0;
    reg [1:0] tx_idx   = 2'd0;
    reg       tx_valid = 1'b0;
    reg       tx_send  = 1'b0;
    wire      tx_ready;
    uart_tx u_tx (
        .clk(sys_clk), .rst_n(rst_n),
        .data(tx_byte), .valid(tx_valid), .ready(tx_ready), .tx(uart_tx)
    );

    wire [7:0] u_abs = u_phys[7] ? (8'd0 - u_phys) : u_phys[7:0];   // |u|，0~100

    reg [24:0] cnt;
    reg        hb_d;
    always @(posedge sys_clk) begin
        cnt    <= cnt + 1'b1;
        hb_d   <= cnt[24];

        led[0] <= cnt[24];            // 心跳
        led[1] <= key[0];             // 按下(0) 点亮
        led[2] <= key[1];
        led[3] <= enc_raw[0];         // 计数最低位：转动时闪
        led[4] <= en;                 // 1=正在控制；上电/stale 时为 0
        led[5] <= ~uart_rx;           // 串口空闲(高) 时点亮

        // 心跳上升沿启动一帧 4 字节自检帧（逐字节发）
        tx_valid <= 1'b0;
        if (cnt[24] & ~hb_d & tx_ready && !tx_send) begin
            tx_send <= 1'b1;
            tx_idx  <= 2'd0;
        end else if (tx_send && !tx_valid && tx_ready) begin
            case (tx_idx)
                2'd0:    tx_byte <= 8'hA5;                  // 帧头
                2'd1:    tx_byte <= enc_raw[7:0];           // 编码器计数低 8 位
                2'd2:    tx_byte <= adc_code_raw[7:0];      // ADC 码值低 8 位
                default: tx_byte <= u_abs;                  // PWM 幅值
            endcase
            tx_valid <= 1'b1;
            if (tx_idx == 2'd3) tx_send <= 1'b0;
            else                tx_idx  <= tx_idx + 1'b1;
        end
    end

    wire unused = &{1'b0, kext, adc_valid, adc_framing_err, tgt_x10, u_mag};
endmodule
