// 环境验收用最小工程：50MHz 计数器翻转 RGB LED（立创 wiki 同款验证思路）
module top (
    input  wire       sys_clk,
    input  wire [1:0] key,
    output reg  [5:0] led
);
    reg [25:0] cnt;

    always @(posedge sys_clk) begin
        cnt <= cnt + 1'b1;
        if (&cnt)
            led <= ~led;
    end
endmodule
