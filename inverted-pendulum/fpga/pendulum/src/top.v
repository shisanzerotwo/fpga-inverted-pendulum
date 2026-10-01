// M1 工程骨架顶层（D2 编码器自检版）：不做控制，验证引脚与采集链。
// 板载 2 个 RGB 彩灯 = led[0..5] 六通道（极性未核实，见 AGENTS.md §5.1）：
//   led[0]=R9 心跳（约 1.5Hz）        led[1]=C10 跟随 D11
//   led[2]=R7 跟随 F10                led[3]=N6  编码器计数最低位（转动时闪）
//   led[4]=T10 ADC 桥 stale（无合法帧）led[5]=P7  串口空闲时亮
// 串口（板上读 COM9）：每次心跳发一个字节 = 编码器计数低 8 位（有符号，补码）。
// 电机输出恒为安全态：PWM=0、AIN1=AIN2=0，上电不会驱动电机。
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
    // 电机输出停在安全态
    assign pwma     = 1'b0;
    assign ain1     = 1'b0;
    assign ain2     = 1'b0;

    // 上电后 FPGA 无独立复位脚，用计数器前几拍当复位。
    reg [3:0] rst_cnt = 4'd0;
    wire      rst_n   = &rst_cnt;
    always @(posedge sys_clk) if (!rst_n) rst_cnt <= rst_cnt + 1'b1;

    // 摆角 ADC 码值桥（GD32 只采样转发；GD32 固件未就绪前 stale 恒为 1）
    wire [11:0] adc_code;
    wire        adc_valid, adc_stale, adc_framing_err;
    adc_bridge #(.CLK_HZ(50_000_000), .BAUD(1_000_000), .TIMEOUT_MS(5)) u_ab (
        .clk(sys_clk), .rst_n(rst_n), .rx(adc_rx),
        .code(adc_code), .valid(adc_valid), .stale(adc_stale),
        .framing_err(adc_framing_err)      // 内部信号，暂不引到引脚；需要观察时可用 led 复用
    );

    // 编码器四倍频计数（输出轴一圈 408）
    wire signed [31:0] enc_count;
    quad_decoder #(.FILTER(4)) u_qd (
        .clk(sys_clk), .rst_n(rst_n),
        .enc_a(enc_a), .enc_b(enc_b), .count(enc_count)
    );

    reg [7:0] tx_byte = 8'd0;
    reg       tx_valid = 1'b0;
    wire      tx_ready;
    uart_tx u_tx (
        .clk(sys_clk), .rst_n(rst_n),
        .data(tx_byte), .valid(tx_valid), .ready(tx_ready), .tx(uart_tx)
    );

    wire unused = &{1'b0, kext, adc_framing_err};   // 本版未用的输入/输出占位，防止被优化掉

    reg [24:0] cnt;
    reg        hb_d;
    always @(posedge sys_clk) begin
        cnt    <= cnt + 1'b1;
        hb_d   <= cnt[24];
        led[0] <= cnt[24];            // 心跳
        led[1] <= key[0];             // 按下(0) 点亮
        led[2] <= key[1];
        led[3] <= enc_count[0];       // 计数最低位：转动时闪
        led[4] <= adc_stale;          // ADC 桥超时/未收到合法帧
        led[5] <= ~uart_rx;           // 串口空闲(高) 时点亮

        // 心跳上升沿发一个字节 = 编码器计数低 8 位；ready 为高才能被接收
        tx_valid <= 1'b0;
        if (cnt[24] & ~hb_d & tx_ready) begin
            tx_valid <= 1'b1;
            tx_byte  <= enc_count[7:0];
        end
    end
endmodule
