`timescale 1ns/1ps
// pwm_gen 端口级 TB：只观察 pwma/ain1/ain2。期望时钟数为手写字面量：
// 50MHz / 20kHz = 2500 时钟/周期；每 1% = 25 时钟（+50 -> 1250，-30 -> 750）。
// 方向语义照搬江协 Motor_SetPWM：u>=0 -> AIN1=0/AIN2=1；u<0 -> AIN1=1/AIN2=0。
module pwm_gen_tb;
    reg               clk = 0;
    reg               rst_n = 0;
    reg               en = 0;
    reg  signed [7:0] u = 0;
    wire              pwma, ain1, ain2;
    integer           errors = 0;

    pwm_gen #(.CLK_HZ(50_000_000), .PWM_HZ(20_000)) dut (
        .clk(clk), .rst_n(rst_n), .en(en), .u(u), .pwma(pwma), .ain1(ain1), .ain2(ain2));

    always #10 clk = ~clk;   // 50MHz

    task check(input cond, input [8*64-1:0] msg);
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %0s", msg);
        end
    endtask

    // 测一个完整 PWM 周期：从 pwma 上升沿起，数高电平时钟数 hi 与整周期时钟数 per。
    // 有界：等待/计数均不超过 3 个周期（7500 时钟），超时返回 -1（用于 0% / 100% 情形）。
    // 同时检查测量期间 ain1/ain2 恒等于 (exp_a1, exp_a2)。
    integer hi, per, k;
    reg     dir_bad;
    reg     low_seen;
    task measure(input exp_a1, input exp_a2);
        begin
            hi = -1; per = -1; dir_bad = 0;
            k = 0;
            while (pwma !== 1'b0 && k < 7500) begin @(posedge clk); k = k + 1; end
            while (pwma !== 1'b1 && k < 7500) begin @(posedge clk); k = k + 1; end
            if (k < 7500) begin
                hi = 0;
                while (pwma === 1'b1 && hi < 7500) begin
                    if (ain1 !== exp_a1 || ain2 !== exp_a2) dir_bad = 1;
                    @(posedge clk); hi = hi + 1;
                end
                per = hi;
                while (pwma === 1'b0 && per < 7500) begin
                    if (ain1 !== exp_a1 || ain2 !== exp_a2) dir_bad = 1;
                    @(posedge clk); per = per + 1;
                end
            end
        end
    endtask

    initial begin
        #20_000_000 $display("FAIL: watchdog timeout");
        $finish;
    end

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("pwm_gen_tb.vcd");
            $dumpvars(0, pwm_gen_tb);
        end

        // 切片 1：复位期间、以及 en=0 时全部输出为 0（安全态）
        repeat (3) @(posedge clk); #1;
        check(pwma === 1'b0 && ain1 === 1'b0 && ain2 === 1'b0, "slice1: all low during reset");
        rst_n = 1;
        u = 8'sd50;                                 // en=0 时即使给了 u 也不能输出
        repeat (3 * 2500) @(posedge clk); #1;
        check(pwma === 1'b0 && ain1 === 1'b0 && ain2 === 1'b0, "slice1: all low with en=0 (u=+50 ignored)");

        // 切片 2：u=+50 -> AIN1=0/AIN2=1，周期 2500 时钟，高电平 1250 时钟
        en = 1;
        repeat (2 * 2500) @(posedge clk);           // 跳过使能后的首个（可能残缺的）周期
        measure(1'b0, 1'b1);
        check(per == 2500,    "slice2: period = 2500 clocks (20kHz)");
        check(hi  == 1250,    "slice2: u=+50 -> high 1250 clocks");
        check(!dir_bad,       "slice2: direction AIN1=0 AIN2=1 held for whole period");
        if (per != 2500 || hi != 1250) $display("  (slice2 measured hi=%0d per=%0d)", hi, per);

        // 切片 3：u=-30 -> AIN1=1/AIN2=0，高电平 750 时钟
        u = -8'sd30;
        repeat (2 * 2500) @(posedge clk);
        measure(1'b1, 1'b0);
        check(per == 2500,    "slice3: period = 2500 clocks");
        check(hi  == 750,     "slice3: u=-30 -> high 750 clocks");
        check(!dir_bad,       "slice3: direction AIN1=1 AIN2=0 held for whole period");
        if (per != 2500 || hi != 750) $display("  (slice3 measured hi=%0d per=%0d)", hi, per);

        // 切片 4：u=0 -> pwma 恒低（3 个周期内无上升沿），方向同参考 >=0 分支：AIN1=0/AIN2=1
        u = 8'sd0;
        repeat (2 * 2500) @(posedge clk);
        measure(1'b0, 1'b1);
        check(hi == -1,       "slice4: u=0 -> no high pulse within 3 periods");
        check(pwma === 1'b0,  "slice4: pwma low");
        check(ain1 === 1'b0 && ain2 === 1'b1, "slice4: u=0 direction AIN1=0 AIN2=1 (ref >=0 branch)");

        // 切片 5：饱和。u=+127 / -128（超出 ±100）按 100% 处理：3 个周期内 pwma 恒高、无低电平毛刺
        u = 8'sd127;
        repeat (2 * 2500) @(posedge clk);
        low_seen = 0;
        for (k = 0; k < 3 * 2500; k = k + 1) begin @(posedge clk); if (pwma !== 1'b1) low_seen = 1; end
        check(!low_seen,                      "slice5: u=+127 -> pwma always high (100%)");
        check(ain1 === 1'b0 && ain2 === 1'b1, "slice5: u=+127 direction forward");
        u = -8'sd128;
        repeat (2 * 2500) @(posedge clk);
        low_seen = 0;
        for (k = 0; k < 3 * 2500; k = k + 1) begin @(posedge clk); if (pwma !== 1'b1) low_seen = 1; end
        check(!low_seen,                      "slice5: u=-128 -> pwma always high (100%)");
        check(ain1 === 1'b1 && ain2 === 1'b0, "slice5: u=-128 direction reverse");

        // 切片 6：周期中途改 u（含换向）：当前周期保持旧占空比与旧方向，下个周期才生效。
        // u=+80 -> 高 2000 时钟；在高电平第 1000 拍改成 u=-20（-20 -> 高 500 时钟、反向）
        u = 8'sd80;
        repeat (2 * 2500) @(posedge clk);
        while (pwma !== 1'b0) @(posedge clk);
        while (pwma !== 1'b1) @(posedge clk);
        hi = 0; dir_bad = 0;
        while (pwma === 1'b1 && hi < 7500) begin
            if (ain1 !== 1'b0 || ain2 !== 1'b1) dir_bad = 1;
            if (hi == 1000) u = -8'sd20;
            @(posedge clk); hi = hi + 1;
        end
        check(hi == 2000,     "slice6: mid-period u change -> current pulse keeps 2000 clocks");
        check(!dir_bad,       "slice6: direction unchanged during current period");
        if (hi != 2000) $display("  (slice6 current pulse hi=%0d)", hi);
        measure(1'b1, 1'b0);
        check(hi == 500,      "slice6: next period uses new u=-20 -> high 500 clocks");
        check(!dir_bad,       "slice6: next period direction reversed");
        if (hi != 500) $display("  (slice6 next period hi=%0d per=%0d)", hi, per);

        // 切片 7：周期中途 en 拉低 -> 下一拍即安全态（不等周期边界）
        u = 8'sd80;
        repeat (2 * 2500) @(posedge clk);
        while (pwma !== 1'b0) @(posedge clk);
        while (pwma !== 1'b1) @(posedge clk);
        repeat (300) @(posedge clk);
        @(negedge clk); en = 0;
        @(posedge clk); #1;
        check(pwma === 1'b0 && ain1 === 1'b0 && ain2 === 1'b0, "slice7: en low mid-pulse -> safe state next clock");
        repeat (2 * 2500) @(posedge clk); #1;
        check(pwma === 1'b0 && ain1 === 1'b0 && ain2 === 1'b0, "slice7: stays safe while en=0");

        if (errors == 0) $display("PASS: all slices");
        else             $display("RESULT: %0d failure(s)", errors);
        $finish;
    end
endmodule
