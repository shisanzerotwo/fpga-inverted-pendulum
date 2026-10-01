`timescale 1ns/1ps
// adc_bridge 端口级 TB：独立 UART 发送器产生 8N1 字节流，只观察 code/valid/stale。
// 帧格式：0xA5 | {4'b0, code[11:8]} | code[7:0] | chk = A5 ^ hi ^ lo。
// 手写帧的 chk 均为手算字面量（独立于 RTL）。波形：vvp adc_bridge_tb.vvp +vcd
module adc_bridge_tb;
    reg         clk = 0;
    reg         rst_n = 0;
    reg         rx = 1;
    wire [11:0] code;
    wire        valid;
    wire        stale;
    integer     errors = 0;

    adc_bridge #(.CLK_HZ(50_000_000), .BAUD(1_000_000), .TIMEOUT_MS(5)) dut (
        .clk(clk), .rst_n(rst_n), .rx(rx), .code(code), .valid(valid), .stale(stale));

    always #10 clk = ~clk;   // 50MHz

    task check(input cond, input [8*64-1:0] msg);
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %0s", msg);
        end
    endtask

    // ---- 独立 UART 发送器（8N1，LSB 先发）。位宽为实数 ns，便于切片 8 注入波特率偏差 ----
    real bit_ns = 1000.0;          // 1Mbaud 名义位宽
    task send_byte(input [7:0] b);
        integer k;
        begin
            rx = 1'b0; #(bit_ns);                       // 起始位
            for (k = 0; k < 8; k = k + 1) begin
                rx = b[k]; #(bit_ns);
            end
            rx = 1'b1; #(bit_ns);                       // 停止位
        end
    endtask
    task send_frame(input [7:0] b0, input [7:0] b1, input [7:0] b2, input [7:0] b3);
        begin send_byte(b0); send_byte(b1); send_byte(b2); send_byte(b3); end
    endtask

    // ---- valid 监视器：计脉冲数并记下每个脉冲时刻的 code ----
    // ---- 序列帧（切片 7/8）：code_k = (k*41 + 7) mod 4096；chk 由协议定义 A5^hi^lo 计算 ----
    // 此处 chk 的计算是协议本身的定义（不是复刻 RTL 内部结构）；其正确性已由切片 2/3/6 的手算字面量锚定
    integer i;
    function [11:0] seq_code(input integer k);
        seq_code = (k * 41 + 7) % 4096;
    endfunction
    task send_code(input [11:0] c);
        reg [7:0] hi, lo;
        begin
            hi = {4'b0, c[11:8]};
            lo = c[7:0];
            send_frame(8'hA5, hi, lo, 8'hA5 ^ hi ^ lo);
        end
    endtask
    reg     seq_check = 0;
    integer seq_k = 0, seq_err = 0;
    always @(posedge clk) if (valid && seq_check) begin
        if (code !== seq_code(seq_k)) begin
            seq_err = seq_err + 1;
            if (seq_err <= 3) $display("  (seq frame %0d: got %h want %h)", seq_k, code, seq_code(seq_k));
        end
        seq_k = seq_k + 1;
    end

    integer     n_valid = 0;
    reg  [11:0] last_code = 12'hFFF;
    // expect_code：当前允许出现的唯一码值；valid 时 code 不等于它就计一次"错误码值"
    reg  [11:0] expect_code = 12'hXXX;
    integer     bad_code_seen = 0;
    always @(posedge clk) if (valid) begin
        n_valid   = n_valid + 1;
        last_code = code;
        if (expect_code !== 12'hXXX && code !== expect_code) begin
            bad_code_seen = bad_code_seen + 1;
            $display("  (valid with unexpected code %h, expect %h)", code, expect_code);
        end
    end

    // ---- 切片 8：以 pm（千分比）偏差发 20 帧背靠背序列帧，返回是否全部正确 ----
    integer err_pm;
    reg     ok;
    task run_baud_err(input integer pm, output reg pass);
        begin
            bit_ns = 1000.0 * (1.0 + pm / 1000.0);
            #(20_000);                                  // 线路空闲 20us，隔开上一段
            seq_check = 1; seq_k = 0; seq_err = 0;
            n_valid = 0;
            for (i = 0; i < 20; i = i + 1) send_code(seq_code(i));
            repeat (20) @(posedge clk);
            seq_check = 0;
            pass   = (n_valid == 20) && (seq_err == 0);
            bit_ns = 1000.0;
        end
    endtask

    initial begin
        #300_000_000 $display("FAIL: watchdog timeout");
        $finish;
    end

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("adc_bridge_tb.vcd");
            $dumpvars(0, adc_bridge_tb);
        end

        // 切片 1：复位态 code=0、valid=0；未收到任何合法帧前 stale=1（失效安全）
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (20) @(posedge clk);
        #1;
        check(code === 12'd0,  "slice1: code 0 after reset");
        check(valid === 1'b0,  "slice1: valid 0 after reset");
        check(stale === 1'b1,  "slice1: stale 1 before first good frame");

        // 切片 2：一帧合法帧还原码值。code=0x5A3：hi=05 lo=A3，chk=A5^05^A3=03
        n_valid = 0;
        send_frame(8'hA5, 8'h05, 8'hA3, 8'h03);
        repeat (20) @(posedge clk);                 // 等停止位采样 + 输出寄存
        check(n_valid == 1,         "slice2: exactly one valid pulse");
        check(last_code === 12'h5A3, "slice2: code captured at valid = 0x5A3");
        check(code === 12'h5A3,      "slice2: code holds 0x5A3");
        check(stale === 1'b0,        "slice2: stale cleared by good frame");

        // 切片 3：校验错的帧丢弃。code=0x123：hi=01 lo=23，正确 chk=A5^01^23=87，这里故意发 86
        n_valid = 0;
        send_frame(8'hA5, 8'h01, 8'h23, 8'h86);
        repeat (20) @(posedge clk);
        check(n_valid == 0,          "slice3: bad checksum -> no valid pulse");
        check(code === 12'h5A3,      "slice3: code unchanged after bad frame");
        // 紧跟一帧正确的 0x123，确认解析器回到同步态、没被坏帧卡住
        send_frame(8'hA5, 8'h01, 8'h23, 8'h87);
        repeat (20) @(posedge clk);
        check(n_valid == 1,          "slice3: next good frame accepted");
        check(code === 12'h123,      "slice3: code = 0x123 after good frame");

        // 切片 4a：帧前有垃圾字节（含不完整帧尾巴），之后的合法帧必须被接收
        // code=0x7FF：hi=07 lo=FF，chk=A5^07^FF=5D
        n_valid = 0;
        send_byte(8'h3C); send_byte(8'hFF); send_byte(8'h00);
        send_frame(8'hA5, 8'h07, 8'hFF, 8'h5D);
        repeat (20) @(posedge clk);
        check(n_valid == 1,          "slice4a: good frame after garbage accepted");
        check(code === 12'h7FF,      "slice4a: code = 0x7FF");

        // 切片 4b：从帧中间开始收（数据里恰好有 A5）。码值 0x0A5：hi=00 lo=A5 chk=A5^00^A5=00
        // 先只发半帧尾巴 "A5 00"（= 上一帧的 lo、chk），解析器会把这里的 A5 误当同步，
        // 随后连续发 3 个完整的 0x0A5 帧：至多丢 1 帧，之后必须恢复且不能吐出错误码值。
        n_valid = 0;
        expect_code = 12'h0A5;
        send_byte(8'hA5); send_byte(8'h00);
        send_frame(8'hA5, 8'h00, 8'hA5, 8'h00);
        send_frame(8'hA5, 8'h00, 8'hA5, 8'h00);
        send_frame(8'hA5, 8'h00, 8'hA5, 8'h00);
        repeat (20) @(posedge clk);
        check(n_valid >= 2,          "slice4b: resync within 1 frame (>=2 of 3 accepted)");
        check(code === 12'h0A5,      "slice4b: code = 0x0A5 after resync");
        check(bad_code_seen == 0,    "slice4b: no wrong code ever emitted during resync");

        // 切片 4c：错位解析也能通过 XOR 校验的情形。码值 0x303：hi=03 lo=03 chk=A5^03^03=A5，
        // 校验字节恰好等于同步字节。从上一帧的 chk(=A5) 开始收：若不检查 hi 高 4 位为 0，
        // 解析器会把下一帧的 A5 当 hi，得到 A5^A5^03=03 == 03 校验通过，吐出错误码值 0x503，
        // 且之后每帧都锁在错位上。期望：从不吐错误码值，且很快恢复为 0x303。
        n_valid = 0;
        bad_code_seen = 0;
        expect_code = 12'h303;
        send_byte(8'hA5);
        send_frame(8'hA5, 8'h03, 8'h03, 8'hA5);
        send_frame(8'hA5, 8'h03, 8'h03, 8'hA5);
        send_frame(8'hA5, 8'h03, 8'h03, 8'hA5);
        repeat (20) @(posedge clk);
        check(bad_code_seen == 0,    "slice4c: no wrong code (e.g. 0x503) from misaligned parse");
        check(n_valid >= 2,          "slice4c: recovers to aligned frames (>=2 of 3)");
        check(code === 12'h303,      "slice4c: code = 0x303");
        expect_code = 12'hXXX;

        // 切片 5：超时。TIMEOUT_MS=5 -> 5ms 无合法帧 stale 置 1；收到合法帧后清 0。
        // 边界：最后一帧后 4.5ms 仍为 0（未超时），5.5ms 已为 1（超时）。
        check(stale === 1'b0,        "slice5: stale 0 right after good frames");
        #4_500_000;
        check(stale === 1'b0,        "slice5: stale still 0 at 4.5ms (< TIMEOUT_MS)");
        #1_000_000;
        check(stale === 1'b1,        "slice5: stale 1 at 5.5ms (> TIMEOUT_MS)");
        // 超时后只有坏帧：不能清 stale
        send_frame(8'hA5, 8'h01, 8'h23, 8'h86);
        repeat (20) @(posedge clk);
        check(stale === 1'b1,        "slice5: bad frame does not clear stale");
        // 合法帧清 stale，且码值照常更新。code=0x456：hi=04 lo=56 chk=A5^04^56=F7
        send_frame(8'hA5, 8'h04, 8'h56, 8'hF7);
        repeat (20) @(posedge clk);
        check(stale === 1'b0,        "slice5: good frame clears stale");
        check(code === 12'h456,      "slice5: code = 0x456");

        // 切片 6：边界码值。0x000：hi=00 lo=00 chk=A5；0xFFF：hi=0F lo=FF chk=A5^0F^FF=55
        n_valid = 0;
        send_frame(8'hA5, 8'h00, 8'h00, 8'hA5);
        repeat (20) @(posedge clk);
        check(code === 12'h000,      "slice6: code = 0 (min)");
        send_frame(8'hA5, 8'h0F, 8'hFF, 8'h55);
        repeat (20) @(posedge clk);
        check(code === 12'hFFF,      "slice6: code = 4095 (max)");
        check(n_valid == 2,          "slice6: both boundary frames accepted");
        // 越界帧：hi=10（高 4 位非 0），即使 chk 正确（A5^10^00=B5）也必须拒收
        send_frame(8'hA5, 8'h10, 8'h00, 8'hB5);
        repeat (20) @(posedge clk);
        check(code === 12'hFFF,      "slice6: out-of-range hi=0x10 rejected, code holds");
        check(n_valid == 2,          "slice6: no valid pulse for out-of-range frame");

        // 切片 7a：1kHz 连发 100 帧（每 1ms 一帧，帧本身 40us），无漏帧、无错帧
        // 切片 7b：背靠背 100 帧（帧间无空闲，帧间隔 = 一帧时间 40us = 25kHz），同样无漏/错
        // 码值序列 code_k = (k*41 + 7) mod 4096，覆盖高 4 位各种取值；期望序列在监视器里逐帧比对
        if (!$test$plusargs("skip7")) begin
        // 期望序列锚点（手算字面量）：k=1 -> 48=0x030；k=99 -> 4066=0xFE2；k=100 -> 4107 mod 4096 = 0x00B
        check(seq_code(1)   === 12'h030, "slice7: seq anchor k=1 = 0x030");
        check(seq_code(99)  === 12'hFE2, "slice7: seq anchor k=99 = 0xFE2");
        check(seq_code(100) === 12'h00B, "slice7: seq anchor k=100 wraps to 0x00B");

        seq_check = 1; seq_k = 0; seq_err = 0;
        n_valid = 0;
        for (i = 0; i < 100; i = i + 1) begin
            send_code(seq_code(i));
            #(1_000_000 - 40_000);                     // 补足到 1ms 周期
        end
        repeat (20) @(posedge clk);
        check(n_valid == 100,        "slice7a: 1kHz x100 -> 100 valid pulses (no drop)");
        check(seq_err == 0,          "slice7a: every frame decoded to expected code");

        seq_k = 0; seq_err = 0;
        n_valid = 0;
        for (i = 0; i < 100; i = i + 1) send_code(seq_code(i));
        repeat (20) @(posedge clk);
        check(n_valid == 100,        "slice7b: back-to-back x100 -> 100 valid pulses");
        check(seq_err == 0,          "slice7b: every back-to-back frame decoded correctly");
        seq_check = 0;
        end   // !skip7

        // 切片 8：发送端波特率偏差 ±2%（GD32 与 FPGA 时钟独立），背靠背 20 帧全部正确。
        // 容限（推导见 adc_bridge.v 头注释）：理论约 -5.1% ~ +5.4%；
        // 实测扫描（2026-10-01，背靠背 20 帧）：-4.8% ~ +5.5% 全对，-5.0% 与 +6.0% 失败。
        // 扫描模式：+err_pm=<千分比> 只跑这一档并打印结果，用于实测容限边界。
        if ($value$plusargs("err_pm=%d", err_pm)) begin
            run_baud_err(err_pm, ok);
            $display("SWEEP err=%0d permille -> %0s (valid=%0d seq_err=%0d)",
                     err_pm, ok ? "OK" : "FAIL", n_valid, seq_err);
        end else begin
            run_baud_err(-20, ok);
            check(ok, "slice8: sender -2% baud -> 20/20 frames correct");
            run_baud_err(20, ok);
            check(ok, "slice8: sender +2% baud -> 20/20 frames correct");
        end

        if (errors == 0) $display("PASS: all slices");
        else             $display("RESULT: %0d failure(s)", errors);
        $finish;
    end
endmodule
