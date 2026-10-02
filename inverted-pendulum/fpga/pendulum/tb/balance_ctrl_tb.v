`timescale 1ns/1ps
// balance_ctrl 端口级 TB：只观察端口（ang_tick/loc_tick/tgt_x10/en/u_dir/u_mag）。
// 节拍：50MHz 基准，摆角环每 5000 时钟（200Hz）、位置环每 50000 时钟（20Hz），两者同拍时先摆角后位置。
module balance_ctrl_tb;
    reg                clk = 0;
    reg                rst_n = 0;
    reg                stale = 0;
    reg  [11:0]        adc_code = 0;
    reg  signed [31:0] loc = 0;
    wire               ang_tick, loc_tick;
    wire signed [31:0] tgt_x10;
    wire signed [7:0]  u_dir;
    wire               u_mag, en;
    integer            errors = 0;
    integer            i, k;
    integer            fd, nr, v_adc, v_loc, v_tgt, v_u, n_vec, n_mis, max_diff, d;

    // 用 100kHz 缩小仿真周期（节拍比例与 50MHz 完全一致），50MHz 的真实计数器宽度到集成时再验
    balance_ctrl #(.CLK_HZ(100_000), .ANG_DIV(5), .LOC_DIV(50)) dut (
        .clk(clk), .rst_n(rst_n), .stale(stale), .adc_code(adc_code), .loc(loc),
        .ang_tick(ang_tick), .loc_tick(loc_tick), .tgt_x10(tgt_x10),
        .u_dir(u_dir), .u_mag(u_mag), .en(en));

    always #200 clk = ~clk;    // 2.5MHz 时钟：TICK_DIV=100 时 1kHz 基准 = 400ns/拍（与参数 CLK_HZ=100k 对应）

    task check(input cond, input [8*64-1:0] msg);
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %0s", msg);
        end
    endtask

    // 等待 ang_tick 脉冲，返回距上次的时钟数
    integer d_clocks;
    task wait_ang;
        begin
            d_clocks = 0;
            while (ang_tick !== 1'b1 && d_clocks < 30 * 500) begin @(posedge clk); d_clocks = d_clocks + 1; end
            if (ang_tick === 1'b1) d_clocks = d_clocks + 1;
        end
    endtask

    // 全局计数，用于测量两个 tick 各自的间距
    integer nclk = 0, last_ang = 0, last_loc = 0, d_ang = 0, d_loc = 0, nang = 0, nloc = 0;
    always @(posedge clk) begin
        nclk = nclk + 1;
        if (ang_tick) begin d_ang = nclk - last_ang; last_ang = nclk; nang = nang + 1; end
        if (loc_tick) begin d_loc = nclk - last_loc; last_loc = nclk; nloc = nloc + 1; end
    end

    // 等 n 个摆角拍（利用 always 块里的计数器，脉冲不漏计）
    integer s_ang;
    task step_ang_ticks(input integer n);
        begin
            s_ang = nang;
            while (nang < s_ang + n) @(posedge clk);
            repeat (40) @(posedge clk);                   // 等 PID 算完（约 QB+4 拍）
        end
    endtask

    // 等 n 个位置环拍
    integer s_loc;
    task step_loc_ticks(input integer n);
        begin
            s_loc = nloc;
            while (nloc < s_loc + n) @(posedge clk);
            repeat (40) @(posedge clk);
        end
    endtask

    // 等一个 ang_tick，并在"该拍"捕获 tgt_x10 —— 位置环与角度环同拍时，tgt 要到约 14 拍后才被改写，
    // 故此处读到的正是本拍角度环实际使用的目标值（与向量语义一致）
    reg signed [31:0] tgt_tick;
    task step_ang_capture;
        begin
            s_ang = nang;
            while (nang < s_ang + 1) @(posedge clk);
            tgt_tick = tgt_x10;
            repeat (40) @(posedge clk);
        end
    endtask

    task do_reset;
        begin
            rst_n = 0;
            repeat (4) @(posedge clk);
            rst_n = 1;
            repeat (4) @(posedge clk);
            nclk = 0; last_ang = 0; last_loc = 0; nang = 0; nloc = 0;
        end
    endtask

    initial begin
        #200_000_000 $display("FAIL: watchdog timeout at %0t (nclk=%0d nang=%0d)", $time, nclk, nang);
        $finish;
    end

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("balance_ctrl_tb.vcd");
            $dumpvars(0, balance_ctrl_tb);
        end

        // 切片 1：节拍。CLK_HZ=100kHz，clk 半周期 5us -> 1kHz 基准 = 100 时钟；
        // 摆角环每 ANG_DIV=5 拍 = 500 时钟（200Hz）；位置环每 LOC_DIV=50 拍 = 5000 时钟（20Hz）。
        // ang_tick/loc_tick 是 1 拍脉冲，用 always 块计数（脉冲不漏计）。
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        nclk = 0; last_ang = 0; last_loc = 0; nang = 0; nloc = 0;
        repeat (11000) @(posedge clk);                 // 覆盖 2 个 loc_tick 周期（5000 x 2）
        check(nang >= 12, "slice1: ang_tick present (>=12 in window)");
        check(d_ang == 500, "slice1: ang_tick spacing = 500 clocks (200Hz)");
        if (d_ang != 500) $display("  (ang spacing=%0d count=%0d)", d_ang, nang);
        check(nloc >= 2, "slice1: loc_tick present twice in window");
        check(d_loc == 5000, "slice1: loc_tick spacing = 5000 clocks (20Hz)");
        if (d_loc != 5000) $display("  (loc spacing=%0d count=%0d)", d_loc, nloc);

        // 切片 2：级联 PID 手算（1kHz 基准 100 时钟，摆角环每 5 拍 = 500 时钟）
        //  目标 = CENTER(2010)，位置环起点 loc=0 故目标不变
        //  连续 3 个摆角拍 act=2000,1990,2020：期望 7, 10, -14（同 pid_tb 切片 2 的手算）
        do_reset;
        stale = 0; loc = 0;
        adc_code = 12'd2000;
        step_ang_ticks(1);
        check(u_dir === 8'sd7,  "slice2: tick1 adc=2009 (d=1 code) -> u=+7");
        if (u_dir !== 8'sd7) $display("  (tick1 u=%0d)", u_dir);
        adc_code = 12'd1990;
        step_ang_ticks(1);
        check(u_dir === 8'sd10, "slice2: tick2 adc=2008 (d=2 code) -> u=+10");
        if (u_dir !== 8'sd10) $display("  (tick2 u=%0d)", u_dir);
        adc_code = 12'd2020;
        step_ang_ticks(1);
        check(u_dir === -8'sd14, "slice2: tick3 adc=2011 (d=-1 code) -> u=-14 (truncate toward zero)");
        if (u_dir !== -8'sd14) $display("  (tick3 u=%0d)", u_dir);

        // 切片 3：出窗失效安全。CENTER+WIN(5000/10=500 码值) 之外 -> en=0、u=0
        adc_code = 12'd2010 + 12'd600;
        step_ang_ticks(1);
        check(en === 1'b0 && u_dir === 8'sd0 && u_mag === 1'b0, "slice3: out of window -> safe state");
        adc_code = 12'd2010 + 12'd400;                   // 回到窗内
        step_ang_ticks(1);
        check(en === 1'b1, "slice3: back inside window -> en=1");

        // 切片 4：数据失效 safe 态
        stale = 1;
        step_ang_ticks(1);
        check(en === 1'b0 && u_dir === 8'sd0 && u_mag === 1'b0, "slice4: stale -> safe state");
        stale = 0;
        step_ang_ticks(1);
        check(en === 1'b1, "slice4: stale cleared -> en=1");

        // 切片 5：位置环级联符号。loc=100 计数，位置环首拍（Kp=4, Ki=0, Kd=40）：
        //   E0=0-100=-100，dE=-100-0=-100 -> sum = 4*(-100) + 40*(-100) = -4400，DIV=1 -> -4400
        //   限幅 ±1000 -> -1000，即 -100.0 码值；tgt = 20100 - (-1000) = 21100
        //   （若级联符号写成 +，tgt 会是 19100）
        do_reset;
        stale = 0; adc_code = 12'd2010; loc = 32'sd100;
        step_loc_ticks(1);
        check(tgt_x10 === 32'sd21100, "slice5: loc=100 -> position loop pulls target to 21100");
        if (tgt_x10 !== 32'sd21100) $display("  (tgt=%0d)", tgt_x10);
        // 位置环输出为 -1000（-100.0 码值）：目标偏离 100 码值，而角度误差窗是 500 码值 -> 仍在窗内
        check(en === 1'b1, "slice5: 100-code offset still inside window (en=1)");
        // 位置回零后的收敛依赖于位置环积分/微分历史（Ki=0 时只是 PD），不在此切片断言
        loc = 32'sd0;

        // 切片 6：整链对拍。向量由 sim/export_balance_vectors.py 从阶段 0 闭环稳摆轨迹导出，
        //  期望值为 Fraction 精确模型复刻"级联 + 先角环后位置环"；逐位一致（整数域零容差）。
        //  每行 = 一个角度环拍（adc_code loc tgt_x10 expected_u），按拍推进 ang_tick。
        do_reset;
        stale = 0; loc = 32'sd0; adc_code = 12'd0;
        fd = $fopen("vectors/bal_vec.txt", "r");
        if (fd == 0) begin
            errors = errors + 1;
            $display("FAIL: slice6: cannot open vectors/bal_vec.txt");
        end else begin
            n_vec = 0; n_mis = 0; max_diff = 0;
            nr = $fscanf(fd, "%d %d %d %d\n", v_adc, v_loc, v_tgt, v_u);
            while (nr == 4) begin
                loc      = v_loc;
                adc_code = v_adc[11:0];
                step_ang_capture;
                d = u_dir - v_u; if (d < 0) d = -d;
                if (d > max_diff) max_diff = d;
                if (d != 0 || tgt_tick !== v_tgt) begin
                    n_mis = n_mis + 1;
                    if (n_mis <= 3)
                        $display("  (bal vec %0d: adc=%0d loc=%0d got u=%0d tgt=%0d, want u=%0d tgt=%0d)",
                                 n_vec, v_adc, v_loc, u_dir, tgt_tick, v_u, v_tgt);
                end
                n_vec = n_vec + 1;
                if (!(en === 1'b1)) begin
                    errors = errors + 1;
                    $display("FAIL: slice6: en=0 at vector %0d (unexpected safe state)", n_vec);
                end
                nr = $fscanf(fd, "%d %d %d %d\n", v_adc, v_loc, v_tgt, v_u);
            end
            $fclose(fd);
            $display("  slice6 balance chain: %0d vectors, %0d mismatches, max|diff|=%0d", n_vec, n_mis, max_diff);
            check(n_vec == 400,   "slice6: bal vectors fully read (400 angle ticks)");
            check(n_mis == 0,     "slice6: balance chain bit-exact vs exact model");
        end

        if (errors == 0) $display("PASS: all slices");
        else             $display("RESULT: %0d failure(s)", errors);
        $finish;
    end
endmodule
