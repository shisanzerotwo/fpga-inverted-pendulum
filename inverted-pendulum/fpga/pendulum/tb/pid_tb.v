`timescale 1ns/1ps
// pid 端口级 TB。期望值为手算字面量（对照江协 PID_Update：Out = Kp·E0 + Ki·ΣE + Kd·(E0−E1)，
// 限幅 ±100，float→int8_t 向零截断）。角度环实例输入为 0.1 码值单位（adc*10）。
module pid_tb;
    reg                clk = 0;
    reg                rst_n = 0;
    reg                tick = 0;
    reg                clr_int = 0;
    reg  signed [31:0] target = 0, actual = 0;
    wire signed [31:0] out_ang;
    wire               done_ang;
    integer            errors = 0;

    // 角度环：0.3 / 0.01 / 0.4 = 30/1/40 ÷ 1000（输入 ×10 → 再 ÷10），限幅 ±100
    pid #(.KP(30), .KI(1), .KD(40), .DIV(1000), .OUT_MAX(100), .INT_LIM(100000)) u_ang (
        .clk(clk), .rst_n(rst_n), .tick(tick), .clr_int(clr_int),
        .target(target), .actual(actual), .out(out_ang), .done(done_ang));

    // 同增益、积分限幅很小（ΣE 限 ±500 个 0.1 码值 = ±50 码值）的实例：用于切片 4 抗饱和
    wire signed [31:0] out_lim;
    wire               done_lim;
    pid #(.KP(30), .KI(1), .KD(40), .DIV(1000), .OUT_MAX(100), .INT_LIM(500)) u_lim (
        .clk(clk), .rst_n(rst_n), .tick(tick), .clr_int(clr_int),
        .target(target), .actual(actual), .out(out_lim), .done(done_lim));

    // 位置环实例（对拍用，独立激励）：0.4 / 0 / 4 ×10 = 4/0/40，输入为计数、输出直接为 0.1 码值单位
    // （DIV=1：增益已含 ×10，输出 = 10·Out，精确无截断），限幅 ±1000（= ±100 码值）
    reg                tick_l = 0;
    reg  signed [31:0] target_l = 0, actual_l = 0;
    wire signed [31:0] out_loc;
    wire               done_loc;
    pid #(.KP(4), .KI(0), .KD(40), .DIV(1), .OUT_MAX(1000), .INT_LIM(100000)) u_loc (
        .clk(clk), .rst_n(rst_n), .tick(tick_l), .clr_int(1'b0),
        .target(target_l), .actual(actual_l), .out(out_loc), .done(done_loc));

    always #10 clk = ~clk;   // 50MHz

    task check(input cond, input [8*64-1:0] msg);
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %0s", msg);
        end
    endtask

    integer w, i;
    integer fd, nr, v_t, v_a, v_o, n_vec, n_mis, max_diff, d;

    task step_loc(input signed [31:0] tgt, input signed [31:0] act);
        begin
            @(negedge clk);
            target_l = tgt; actual_l = act; tick_l = 1;
            @(negedge clk);
            tick_l = 0;
            w = 0;
            while (done_loc !== 1'b1 && w < 100) begin @(posedge clk); w = w + 1; end
            repeat (2) @(posedge clk);
            if (w >= 100) begin errors = errors + 1; $display("FAIL: loc done not seen within 100 clocks"); end
            #1;
        end
    endtask

    // 复位一次（清全部内部状态），用于各切片之间隔离
    task do_reset;
        begin
            @(negedge clk); rst_n = 0;
            repeat (2) @(negedge clk); rst_n = 1;
            repeat (2) @(negedge clk);
        end
    endtask

    // 单独打一拍 clr_int（不带 tick）
    task pulse_clr;
        begin
            @(negedge clk); clr_int = 1;
            @(negedge clk); clr_int = 0;
            repeat (2) @(negedge clk);
        end
    endtask

    // 送一拍：下降沿给输入与 tick 脉冲（1 时钟），然后有界等待 done（<= 100 时钟）
    // with_clr=1：clr_int 与 tick 同拍
    task step_c(input signed [31:0] tgt, input signed [31:0] act, input with_clr);
        begin
            @(negedge clk);
            target = tgt; actual = act; tick = 1; clr_int = with_clr;
            @(negedge clk);
            tick = 0; clr_int = 0;
            w = 0;
            while (done_ang !== 1'b1 && w < 100) begin @(posedge clk); w = w + 1; end
            repeat (2) @(posedge clk);
            if (w >= 100) begin errors = errors + 1; $display("FAIL: done not seen within 100 clocks"); end
            #1;
        end
    endtask

    // 送一拍：下降沿给输入与 tick 脉冲（1 时钟），然后有界等待 done（<= 100 时钟）
    task step(input signed [31:0] tgt, input signed [31:0] act);
        begin
            @(negedge clk);
            target = tgt; actual = act; tick = 1;
            @(negedge clk);
            tick = 0;
            w = 0;
            while (done_ang !== 1'b1 && w < 100) begin @(posedge clk); w = w + 1; end
            repeat (2) @(posedge clk);                  // 两实例时延相同；多等 2 拍确保都已更新
            if (w >= 100) begin errors = errors + 1; $display("FAIL: done not seen within 100 clocks"); end
            #1;
        end
    endtask

    initial begin
        #5_000_000 $display("FAIL: watchdog timeout");
        $finish;
    end

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("pid_tb.vcd");
            $dumpvars(0, pid_tb);
        end

        // 切片 1：复位后 out=0、done=0
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk); #1;
        check(out_ang === 32'sd0, "slice1: out 0 after reset");
        check(done_ang === 1'b0,  "slice1: done 0 after reset");

        // 切片 2：手算三拍（码值单位；Kp=0.3 Ki=0.01 Kd=0.4）
        //  拍1 Target=2010 Actual=2000：E0=10 ΣE=10 E1=0 -> 3+0.1+4 = 7.1 -> 7
        //  拍2 Target=2010 Actual=1990：E0=20 ΣE=30 E1=10 -> 6+0.3+4 = 10.3 -> 10
        //  拍3 Target=2010 Actual=2020：E0=-10 ΣE=20 E1=20 -> -3+0.2-12 = -14.8 -> -14（向零截断，非 -15）
        step(32'sd20100, 32'sd20000);
        check(out_ang === 32'sd7,   "slice2: tick1 E0=10 -> 7");
        if (out_ang !== 32'sd7) $display("  (tick1 out=%0d)", out_ang);
        step(32'sd20100, 32'sd19900);
        check(out_ang === 32'sd10,  "slice2: tick2 E0=20 -> 10");
        if (out_ang !== 32'sd10) $display("  (tick2 out=%0d)", out_ang);
        step(32'sd20100, 32'sd20200);
        check(out_ang === -32'sd14, "slice2: tick3 E0=-10 -> -14 (truncate toward zero)");
        if (out_ang !== -32'sd14) $display("  (tick3 out=%0d)", out_ang);

        // 切片 3：输出限幅 ±100（每段前复位，状态清零）
        //  E0=+500：150+5+200 = 355 -> +100；接着 E0=-500：-150+0-400 = -550 -> -100（ΣE=0）
        //  边界：E0=141 单拍：42.3+1.41+56.4 = 100.11 -> 100（真值恰为 100；区分"限到 99"）
        //  非饱和边界：E0=140 单拍：42+1.4+56 = 99.4 -> 99（区分"限幅门槛过低"）
        do_reset;
        step(32'sd20100, 32'sd15100);
        check(out_ang === 32'sd100,  "slice3: E0=+500 -> +100 (saturate)");
        if (out_ang !== 32'sd100) $display("  (+500 out=%0d)", out_ang);
        step(32'sd20100, 32'sd25100);
        check(out_ang === -32'sd100, "slice3: then E0=-500 -> -100 (saturate)");
        if (out_ang !== -32'sd100) $display("  (-500 out=%0d)", out_ang);
        do_reset;
        step(32'sd20100, 32'sd18690);
        check(out_ang === 32'sd100,  "slice3: E0=141 -> 100.11 -> 100 (true value exactly 100)");
        if (out_ang !== 32'sd100) $display("  (E0=141 out=%0d)", out_ang);
        do_reset;
        step(32'sd20100, 32'sd18700);
        check(out_ang === 32'sd99,   "slice3: E0=140 -> 99.4 -> 99 (not clamped)");
        if (out_ang !== 32'sd99) $display("  (E0=140 out=%0d)", out_ang);

        // 切片 4：积分限幅（抗饱和）。持续 E0=+10 码值（x10 输入 = 100）20 拍，再 E0=-10 30 拍。
        //  （以下均为 x10 单位：E0=100，sum = 30*E0 + 1*ΣE + 40*ΔE，Out = sum/1000 向零截断）
        //  不限幅 u_ang：第 20 拍 ΣE=2000、ΔE=0 -> 3000+2000 = 5000 -> 5
        //  限幅  u_lim：ΣE 卡在 500 -> 3000+500 = 3500 -> 3
        //  反向第 1 拍：u_ang ΣE=1900：-3000+1900-8000 = -9100 -> -9
        //               u_lim ΣE=400 ：-3000+400 -8000 = -10600 -> -10（无饱和拖尾）
        //  反向第 30 拍：u_ang ΣE=-1000：-3000-1000 = -4000 -> -4
        //                u_lim ΣE 卡在 -500：-3000-500 = -3500 -> -3（下限对称）
        do_reset;
        for (i = 0; i < 20; i = i + 1) step(32'sd20100, 32'sd20000);
        check(out_ang === 32'sd5,  "slice4: unclamped after 20 ticks E0=+10 -> 5 (positive control)");
        check(out_lim === 32'sd3,  "slice4: clamped sumE=+500 -> 3");
        if (out_ang !== 32'sd5 || out_lim !== 32'sd3) $display("  (20 ticks: ang=%0d lim=%0d)", out_ang, out_lim);
        step(32'sd20100, 32'sd20200);
        check(out_ang === -32'sd9,  "slice4: unclamped first reverse tick -> -9");
        check(out_lim === -32'sd10, "slice4: clamped first reverse tick -> -10 (no windup lag)");
        if (out_ang !== -32'sd9 || out_lim !== -32'sd10) $display("  (rev1: ang=%0d lim=%0d)", out_ang, out_lim);
        for (i = 0; i < 29; i = i + 1) step(32'sd20100, 32'sd20200);
        check(out_ang === -32'sd4, "slice4: unclamped after 30 reverse ticks -> -4");
        check(out_lim === -32'sd3, "slice4: clamped sumE=-500 -> -3 (symmetric lower bound)");
        if (out_ang !== -32'sd4 || out_lim !== -32'sd3) $display("  (rev30: ang=%0d lim=%0d)", out_ang, out_lim);

        // 切片 5：clr_int 只清 sumE，不清 E0/E1（参考：进入平衡态仅 ErrorInt=0）。x10 单位，E0=500
        //  10 拍后 sumE=5000：15000+5000 = 20000 -> 20
        //  单独 clr 后再一拍：sumE=500、dE=0 -> 15500 -> 15
        //    （若没清 -> 20500 -> 20；若连 E0 也清了 -> dE=500 -> 35500 -> 35）
        //  再 4 拍 sumE=2500 -> 17500 -> 17；然后 clr 与 tick 同拍：sumE=500 -> 15；下一拍 sumE=1000 -> 16
        //    （若同拍 clr 被忽略 -> 18；若"先累加后清" -> 本拍 18、下拍 15）
        do_reset;
        for (i = 0; i < 10; i = i + 1) step(32'sd20100, 32'sd19600);
        check(out_ang === 32'sd20, "slice5: 10 ticks E0=+50 -> 20");
        if (out_ang !== 32'sd20) $display("  (10 ticks out=%0d)", out_ang);
        pulse_clr;
        step(32'sd20100, 32'sd19600);
        check(out_ang === 32'sd15, "slice5: after clr_int -> 15 (sumE cleared, E0/E1 kept)");
        if (out_ang !== 32'sd15) $display("  (after clr out=%0d)", out_ang);
        for (i = 0; i < 4; i = i + 1) step(32'sd20100, 32'sd19600);
        check(out_ang === 32'sd17, "slice5: 4 more ticks -> 17");
        if (out_ang !== 32'sd17) $display("  (4 more out=%0d)", out_ang);
        step_c(32'sd20100, 32'sd19600, 1'b1);
        check(out_ang === 32'sd15, "slice5: clr_int with tick -> clear then accumulate -> 15");
        if (out_ang !== 32'sd15) $display("  (clr+tick out=%0d)", out_ang);
        step(32'sd20100, 32'sd19600);
        check(out_ang === 32'sd16, "slice5: next tick -> 16");
        if (out_ang !== 32'sd16) $display("  (next out=%0d)", out_ang);

        // 切片 6：对拍。向量由 sim/export_vectors.py 从阶段 0 闭环稳摆轨迹导出，
        // 期望值为 Fraction 精确模型（非 RTL 写法复刻）。纪律 §4：逐拍容差 ±2 LSB；
        // 本实现为精确整数运算，额外要求 0 分歧。
        do_reset;
        fd = $fopen("vectors/pid_ang.txt", "r");
        if (fd == 0) begin errors = errors + 1; $display("FAIL: slice6: cannot open vectors/pid_ang.txt"); end
        else begin
            n_vec = 0; n_mis = 0; max_diff = 0;
            nr = $fscanf(fd, "%d %d %d\n", v_t, v_a, v_o);
            while (nr == 3) begin
                step(v_t, v_a);
                d = out_ang - v_o; if (d < 0) d = -d;
                if (d > max_diff) max_diff = d;
                if (d != 0) begin
                    n_mis = n_mis + 1;
                    if (n_mis <= 3) $display("  (ang vec %0d: tgt=%0d act=%0d got %0d want %0d)", n_vec, v_t, v_a, out_ang, v_o);
                end
                n_vec = n_vec + 1;
                nr = $fscanf(fd, "%d %d %d\n", v_t, v_a, v_o);
            end
            $fclose(fd);
            $display("  slice6 angle loop: %0d vectors, %0d mismatches, max|diff|=%0d", n_vec, n_mis, max_diff);
            check(n_vec == 2000,  "slice6: angle vectors fully read (2000)");
            check(max_diff <= 2,  "slice6: angle loop within +-2 LSB (discipline 4)");
            check(n_mis == 0,     "slice6: angle loop bit-exact vs exact model");
        end

        fd = $fopen("vectors/pid_loc.txt", "r");
        if (fd == 0) begin errors = errors + 1; $display("FAIL: slice6: cannot open vectors/pid_loc.txt"); end
        else begin
            n_vec = 0; n_mis = 0; max_diff = 0;
            nr = $fscanf(fd, "%d %d %d\n", v_t, v_a, v_o);
            while (nr == 3) begin
                step_loc(v_t, v_a);
                d = out_loc - v_o; if (d < 0) d = -d;
                if (d > max_diff) max_diff = d;
                if (d != 0) begin
                    n_mis = n_mis + 1;
                    if (n_mis <= 3) $display("  (loc vec %0d: tgt=%0d act=%0d got %0d want %0d)", n_vec, v_t, v_a, out_loc, v_o);
                end
                n_vec = n_vec + 1;
                nr = $fscanf(fd, "%d %d %d\n", v_t, v_a, v_o);
            end
            $fclose(fd);
            $display("  slice6 position loop: %0d vectors, %0d mismatches, max|diff|=%0d", n_vec, n_mis, max_diff);
            check(n_vec == 200,   "slice6: position vectors fully read (200)");
            check(n_mis == 0,     "slice6: position loop bit-exact (x10 output)");
        end

        if (errors == 0) $display("PASS: all slices");
        else             $display("RESULT: %0d failure(s)", errors);
        $finish;
    end
endmodule
