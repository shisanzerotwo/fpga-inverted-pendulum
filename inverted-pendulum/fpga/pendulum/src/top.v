// M1 工程骨架顶层：全部端口到位，电机输出恒为安全态（PWM=0、AIN1=AIN2=0）。
// 兼作 D1 空板验证：LED 心跳 + 输入回显，用于确认 .cst 引脚与实物一致。
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
    assign pwma     = 1'b0;
    assign ain1     = 1'b0;
    assign ain2     = 1'b0;
    assign adc_cs   = 1'b1;
    assign adc_sck  = 1'b0;
    assign adc_mosi = 1'b0;
    assign uart_tx  = 1'b1;

    reg [24:0] cnt;
    always @(posedge sys_clk) begin
        cnt <= cnt + 1'b1;
        led[0] <= cnt[24];
        led[1] <= ~key[0] | ~kext[0] | ~kext[1];
        led[2] <= ~key[1] | ~kext[2] | ~kext[3];
        led[3] <= enc_a ^ enc_b;
        led[4] <= adc_miso;
        led[5] <= uart_rx;
    end
endmodule
