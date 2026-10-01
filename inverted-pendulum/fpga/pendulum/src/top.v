// M1 工程骨架顶层（D1 空板自检版）：不做控制，只验证 .cst 引脚与实物一致。
// 板载 2 个 RGB 彩灯 = led[0..5] 六通道，共阳，输出低电平点亮：
//   led[0]=R9 心跳（约 1.5Hz）        led[1]=C10 按 D11 亮
//   led[2]=R7 按 F10 亮               led[3]=N6  转编码器时变化
//   led[4]=T10 反映 ADC_DOUT 电平     led[5]=P7  串口空闲时亮
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
    output wire       adc_cs,
    output wire       adc_sck,
    output wire       adc_mosi,
    input  wire       adc_miso,
    input  wire [3:0] kext
);
    // 电机与 ADC 片选全部停在安全态
    assign pwma     = 1'b0;
    assign ain1     = 1'b0;
    assign ain2     = 1'b0;
    assign adc_cs   = 1'b1;   // 不选中，MCP3202 空闲
    assign adc_sck  = 1'b0;
    assign adc_mosi = 1'b0;
    assign uart_tx  = 1'b1;

    wire unused = &{1'b0, kext};   // K1~K4 本版未用，占位防止被优化

    reg [24:0] cnt;
    always @(posedge sys_clk) begin
        cnt    <= cnt + 1'b1;
        led[0] <= cnt[24];            // 心跳
        led[1] <= key[0];             // 按下(0) 点亮
        led[2] <= key[1];
        led[3] <= enc_a ^ enc_b;      // 静止时同相；转动时闪
        led[4] <= adc_miso;           // ADC 输出电平
        led[5] <= ~uart_rx;           // 串口空闲(高) 时点亮
    end
endmodule
