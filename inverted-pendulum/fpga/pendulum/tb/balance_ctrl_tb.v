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

    initial begin
        #5_000_000 $display("FAIL: watchdog timeout at %0t (nclk=%0d nang=%0d)", $time, nclk, nang);
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

        if (errors == 0) $display("PASS: all slices");
        else             $display("RESULT: %0d failure(s)", errors);
        $finish;
    end
endmodule
