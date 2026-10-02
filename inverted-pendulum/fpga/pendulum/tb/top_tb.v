`timescale 1ns/1ps
// top 冒烟 TB：只验证 uart_tx 集成后真能出帧（心跳沿触发）。心跳周期太长，TB 内用 force 加速。
module top_tb;
    reg        sys_clk = 0;
    reg  [1:0] key = 2'b11;
    wire [5:0] led;
    wire       uart_tx;
    reg        uart_rx = 1;
    wire       pwma, ain1, ain2;
    reg        enc_a = 0, enc_b = 0;
    reg        adc_rx = 1;                 // GD32 未发帧：线路空闲为高
    reg  [3:0] kext = 4'b1111;
    integer    errors = 0, frames = 0;

    top dut (.sys_clk(sys_clk), .key(key), .led(led), .uart_tx(uart_tx), .uart_rx(uart_rx),
             .pwma(pwma), .ain1(ain1), .ain2(ain2), .enc_a(enc_a), .enc_b(enc_b),
             .adc_rx(adc_rx), .kext(kext));

    always #10 sys_clk = ~sys_clk;

    localparam BIT_CLKS = 434;

    // 独立 UART 接收器：按协议中点采样，解出字节
    task recv_byte(output [7:0] b);
        integer i;
        begin
            @(negedge uart_tx);
            #((BIT_CLKS / 2) * 20);
            if (uart_tx !== 1'b0) begin errors = errors + 1; $display("FAIL: start bit not 0"); end
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_CLKS * 20);
                b[i] = uart_tx;
            end
            #(BIT_CLKS * 20);
            if (uart_tx !== 1'b1) begin errors = errors + 1; $display("FAIL: stop bit not 1"); end
        end
    endtask

    reg [7:0] got;

    // 编码器激励：格雷码一步保持 HOLD 拍（与 quad_decoder_tb 同一协议，独立手写）
    localparam HOLD = 20;
    task set_ab(input a, input b);
        begin enc_a = a; enc_b = b; repeat (HOLD) @(posedge sys_clk); end
    endtask
    task fwd_cycle; begin set_ab(1,0); set_ab(1,1); set_ab(0,1); set_ab(0,0); end endtask
    task rev_cycle; begin set_ab(0,1); set_ab(1,1); set_ab(1,0); set_ab(0,0); end endtask

    // 4 字节自检帧：[0]=0xA5 帧头  [1]=编码器低 8 位  [2]=ADC 码值低 8 位  [3]=|u|
    reg [7:0] b0, b1, b2, b3;
    task heartbeat_and_recv_frame;
        begin
            force dut.cnt[24] = 1'b0; repeat (4) @(posedge sys_clk);
            force dut.cnt[24] = 1'b1;
            recv_byte(b0); recv_byte(b1); recv_byte(b2); recv_byte(b3);
            frames = frames + 1;
            #(2 * BIT_CLKS * 20);                   // 等停止位结束、ready 恢复
        end
    endtask
    initial begin
        #20_000_000 $display("FAIL: watchdog"); $finish;
    end

    initial begin
        // 安全态断言：上电 + ADC stale -> 电机三路输出为 0
        repeat (20) @(posedge sys_clk); #1;
        if (pwma !== 0 || ain1 !== 0 || ain2 !== 0) begin
            errors = errors + 1; $display("FAIL: motor not in safe state");
        end
        // GD32 未发帧：ADC 桥 stale=1，balance_ctrl 应输出 en=0（led[4] 反映 en）
        if (led[4] !== 1'b0) begin
            errors = errors + 1; $display("FAIL: en should be 0 while stale (led[4]=%b)", led[4]);
        end
        if (uart_tx !== 1'b1) begin errors = errors + 1; $display("FAIL: uart_tx idle not high"); end

        // 心跳加速：force cnt[24] 产生上升沿，触发 4 字节自检帧
        // 1) 静止：编码器 0、ADC 0（无帧）、|u|=0
        heartbeat_and_recv_frame;
        if (b0 !== 8'hA5) begin errors = errors + 1; $display("FAIL: frame header %h want A5", b0); end
        if (b1 !== 8'h00) begin errors = errors + 1; $display("FAIL: idle enc byte %h want 00", b1); end
        if (b3 !== 8'h00) begin errors = errors + 1; $display("FAIL: |u| byte %h want 00 (stale -> en=0)", b3); end

        // 2) 正转 1 个周期 = +4：编码器字节应为 0x04
        fwd_cycle;
        heartbeat_and_recv_frame;
        if (b1 !== 8'h04) begin errors = errors + 1; $display("FAIL: after +1 cycle enc byte %h want 04", b1); end

        // 3) 反转 2 个周期 = 累计 -4：编码器字节应为 0xFC
        rev_cycle; rev_cycle;
        heartbeat_and_recv_frame;
        if (b1 !== 8'hFC) begin errors = errors + 1; $display("FAIL: after -2 cycles enc byte %h want FC", b1); end

        // 4) 全程 stale -> 电机始终安全态、en 始终 0
        if (pwma !== 0 || ain1 !== 0 || ain2 !== 0) begin
            errors = errors + 1; $display("FAIL: motor moved while stale");
        end

        if (errors == 0) $display("PASS: top smoke, %0d frames", frames);
        else             $display("RESULT: %0d failure(s)", errors);
        $finish;
    end
endmodule
