module uart_tx #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       valid,
    output wire       ready,
    output wire       tx
);
    localparam BIT_CLKS = CLK_HZ / BAUD;

    reg [15:0] baud_cnt;
    reg [3:0]  bit_idx;     // 0=起始位, 1..8=数据位, 9=停止位
    reg [9:0]  shifter;     // {停止位, D7..D0, 起始位}，LSB 先出
    reg        busy;

    assign ready = ~busy & rst_n;   // 复位期间不接收，避免上游误以为字节已被收下
    assign tx    = busy ? shifter[0] : 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy     <= 1'b0;
            baud_cnt <= 16'd0;
            bit_idx  <= 4'd0;
            shifter  <= 10'h3FF;
        end else if (!busy) begin
            if (valid) begin
                shifter  <= {1'b1, data, 1'b0};
                busy     <= 1'b1;
                baud_cnt <= 16'd0;
                bit_idx  <= 4'd0;
            end
        end else if (baud_cnt == BIT_CLKS - 1) begin
            baud_cnt <= 16'd0;
            if (bit_idx == 4'd9) begin
                busy <= 1'b0;
            end else begin
                bit_idx <= bit_idx + 1'b1;
                shifter <= {1'b1, shifter[9:1]};
            end
        end else begin
            baud_cnt <= baud_cnt + 1'b1;
        end
    end
endmodule
