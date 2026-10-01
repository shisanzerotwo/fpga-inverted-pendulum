`timescale 1ns/1ps
// uart_tx 端口级 TB：只观察 tx/ready，期望值按 UART 8N1 协议手写。
module uart_tx_tb;
    reg        clk = 0;
    reg        rst_n = 0;
    reg  [7:0] data = 0;
    reg        valid = 0;
    wire       ready;
    wire       tx;
    integer    errors = 0;

    uart_tx dut (.clk(clk), .rst_n(rst_n), .data(data), .valid(valid), .ready(ready), .tx(tx));

    always #10 clk = ~clk;   // 50MHz

    task check(input cond, input [8*64-1:0] msg);
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %0s", msg);
        end
    endtask

    localparam BIT_CLKS = 434;                 // 50e6/115200 取整
    // 时间顺序：[0]=起始位, [1..8]=D0..D7, [9]=停止位（协议手写字面量）
    localparam [0:9] EXP_55 = 10'b0_10101010_1;
    localparam [0:9] EXP_A5 = 10'b0_10100101_1;   // 0xA5 = 1010_0101，LSB 先发 -> 1,0,1,0,0,1,0,1
    localparam [0:9] EXP_3C = 10'b0_00111100_1;   // 0x3C = 0011_1100，LSB 先发 -> 0,0,1,1,1,1,0,0
    localparam [0:9] EXP_00 = 10'b0_00000000_1;
    localparam [0:9] EXP_FF = 10'b0_11111111_1;

    task send_byte(input [7:0] b);
        begin
            @(posedge clk);
            data  <= b;
            valid <= 1'b1;
            @(posedge clk);
            valid <= 1'b0;
        end
    endtask

    // 从 tx 下降沿（起始位开始）起，在每位中点采样
    task check_frame(input [0:9] exp, input [8*64-1:0] msg);
        integer i;
        begin
            @(negedge tx);
            #((BIT_CLKS / 2) * 20);
            for (i = 0; i < 10; i = i + 1) begin
                if (tx !== exp[i]) begin
                    errors = errors + 1;
                    $display("FAIL: %0s bit %0d got %b want %b", msg, i, tx, exp[i]);
                end
                #(BIT_CLKS * 20);
            end
        end
    endtask

    initial begin
        #5_000_000 $display("FAIL: watchdog timeout");
        $finish;
    end

    initial begin
        $dumpfile("uart_tx_tb.vcd");
        $dumpvars(0, uart_tx_tb);

        // 切片 1：复位后 tx 为高、ready 为高
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        #1;
        check(tx === 1'b1,    "slice1: tx idle high after reset");
        check(ready === 1'b1, "slice1: ready high after reset");

        // 切片 2：发 0x55，起始位 0 + 数据位 LSB 先发 + 停止位 1，每位 434 个时钟
        send_byte(8'h55);
        check_frame(EXP_55, "slice2: 0x55 frame");

        // 切片 3：帧发送期间 ready 为低；期间的 valid（数据 0x00）被忽略
        send_byte(8'h55);
        fork
            check_frame(EXP_55, "slice3: 0x55 frame unaffected by mid-frame valid");
            begin
                #((BIT_CLKS * 3 + BIT_CLKS / 2) * 20);       // 第 3 位中点附近
                check(ready === 1'b0, "slice3: ready low mid-frame");
                send_byte(8'h00);
                #((BIT_CLKS * 6) * 20);                        // 停止位中点附近
                check(ready === 1'b0, "slice3: ready low during stop bit");
            end
        join
        #(2 * BIT_CLKS * 20);                                  // 帧后 2 位时间：不应出现第二帧
        check(tx === 1'b1,    "slice3: tx high after frame (no second frame)");
        check(ready === 1'b1, "slice3: ready high after frame");

        // 切片 4：两个字节连发（A5 后 ready 一拉高立刻送 3C），两帧完整无错位
        send_byte(8'hA5);
        fork
            check_frame(EXP_A5, "slice4: first frame 0xA5");
            begin
                wait (ready === 1'b0);
                wait (ready === 1'b1);
                send_byte(8'h3C);
                check_frame(EXP_3C, "slice4: second frame 0x3C");
            end
        join
        #(2 * BIT_CLKS * 20);

        // 切片 5：边界数据 0x00 / 0xFF
        send_byte(8'h00);
        check_frame(EXP_00, "slice5: 0x00 frame");
        send_byte(8'hFF);
        check_frame(EXP_FF, "slice5: 0xFF frame");
        #(2 * BIT_CLKS * 20);
        check(tx === 1'b1,    "slice5: tx idle high at end");
        check(ready === 1'b1, "slice5: ready high at end");

        if (errors == 0) $display("PASS: all slices");
        else             $display("RESULT: %0d failure(s)", errors);
        $finish;
    end
endmodule
