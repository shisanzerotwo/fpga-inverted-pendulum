`timescale 1ns/1ps
// quad_decoder 端口级 TB：只观察 count，期望值按正交编码（格雷码）协议手写。
module quad_decoder_tb;
    reg         clk = 0;
    reg         rst_n = 0;
    reg         enc_a = 0;
    reg         enc_b = 0;
    wire signed [31:0] count;
    integer     errors = 0;
    integer     i;

    quad_decoder #(.FILTER(4)) dut (.clk(clk), .rst_n(rst_n), .enc_a(enc_a), .enc_b(enc_b), .count(count));

    always #10 clk = ~clk;   // 50MHz

    task check_count(input signed [31:0] want, input [8*64-1:0] msg);
        if (count !== want) begin
            errors = errors + 1;
            $display("FAIL: %0s got %0d want %0d", msg, count, want);
        end
    endtask

    localparam HOLD = 20;   // 每个相位状态保持的时钟数（远大于 FILTER，属于"干净"波形）

    // 正交波形发生器：AB 按格雷码序列走一步并保持 HOLD 拍。
    // 正转（A 超前 B）：00 -> 10 -> 11 -> 01 -> 00；反转为逆序。
    task set_ab(input a, input b);
        begin
            enc_a = a;
            enc_b = b;
            repeat (HOLD) @(posedge clk);
        end
    endtask

    task fwd_cycle;   // 正转一个完整周期 = 4 个边沿
        begin
            set_ab(1, 0);
            set_ab(1, 1);
            set_ab(0, 1);
            set_ab(0, 0);
        end
    endtask

    task rev_cycle;   // 反转一个完整周期：00 -> 01 -> 11 -> 10 -> 00
        begin
            set_ab(0, 1);
            set_ab(1, 1);
            set_ab(1, 0);
            set_ab(0, 0);
        end
    endtask

    // A 相脉冲：在下降沿改输入（避开与 DUT 采样沿的竞争），保持 width 个时钟后恢复
    task pulse_a(input integer width);
        begin
            @(negedge clk);
            enc_a = ~enc_a;
            repeat (width) @(posedge clk);
            @(negedge clk);
            enc_a = ~enc_a;
            repeat (HOLD) @(posedge clk);   // 等滤波/同步流水线排空
        end
    endtask

    // 监视器：watch 期间 count 只要变过一次就置位（毛刺误计会先 +1 再 -1，只看终值抓不到）
    reg watch = 0;
    reg changed = 0;
    always @(count) if (watch) changed = 1;

    initial begin
        #50_000_000 $display("FAIL: watchdog timeout");
        $finish;
    end

    initial begin
        $dumpfile("quad_decoder_tb.vcd");
        $dumpvars(0, quad_decoder_tb);

        // 切片 1：复位后 count = 0
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (20) @(posedge clk);
        #1;
        check_count(0, "slice1: count zero after reset");

        // 切片 2：正转一个格雷码周期 -> +4
        fwd_cycle;
        #1;
        check_count(4, "slice2: one forward cycle = +4");

        // 切片 3：反转一个周期 -> 回到 0（正反对称）；再反转一个 -> -4（可过零为负）
        rev_cycle;
        #1;
        check_count(0, "slice3: forward then reverse = 0");
        rev_cycle;
        #1;
        check_count(-4, "slice3: one more reverse cycle = -4");

        // 切片 4：短于 FILTER(=4) 拍的毛刺不计数（宽 1 拍、3 拍）
        changed = 0; watch = 1;
        pulse_a(1);
        pulse_a(3);
        watch = 0;
        if (changed) begin errors = errors + 1; $display("FAIL: slice4: count moved during glitch (<FILTER clocks)"); end
        check_count(-4, "slice4: count unchanged after glitches");

        // 切片 4 阳性对照：HOLD(=20) 拍的脉冲是真实的一来一回，监视器必须看到 count 变化
        changed = 0; watch = 1;
        pulse_a(HOLD);
        watch = 0;
        if (!changed) begin errors = errors + 1; $display("FAIL: slice4 positive control: monitor missed a real pulse"); end
        check_count(-4, "slice4: real back-and-forth pulse nets 0");

        // 切片 5：正转 102 个周期 = 408 计数（输出轴一圈，备赛总结 §硬件参数）
        for (i = 0; i < 102; i = i + 1) fwd_cycle;
        #1;
        check_count(-4 + 408, "slice5: 102 forward cycles = +408 (one output-shaft rev)");

        // 切片 6：非法跳变（两相同时变）不计数：00 -> 11 -> 00
        changed = 0; watch = 1;
        set_ab(1, 1);
        set_ab(0, 0);
        watch = 0;
        if (changed) begin errors = errors + 1; $display("FAIL: slice6: illegal 00<->11 jump changed count"); end
        check_count(404, "slice6: count unchanged after illegal jumps");

        if (errors == 0) $display("PASS: all slices");
        else             $display("RESULT: %0d failure(s)", errors);
        $finish;
    end
endmodule
