`timescale 1ns/1ps
// top 冒烟 TB：只验证 uart_tx 集成后真能出帧（心跳沿触发）。心跳周期太长，TB 内用 force 加速。
module top_tb;
    reg        sys_clk = 0;
    reg  [1:0] key = 2'b11;
    wire [5:0] led;
    wire       uart_tx;
    reg        uart_rx = 1;
    wire       pwma, ain1, ain2, adc_cs, adc_sck, adc_mosi;
    reg        enc_a = 0, enc_b = 0, adc_miso = 0;
    reg  [3:0] kext = 4'b1111;
    integer    errors = 0, frames = 0;

    top dut (.sys_clk(sys_clk), .key(key), .led(led), .uart_tx(uart_tx), .uart_rx(uart_rx),
             .pwma(pwma), .ain1(ain1), .ain2(ain2), .enc_a(enc_a), .enc_b(enc_b),
             .adc_cs(adc_cs), .adc_sck(adc_sck), .adc_mosi(adc_mosi), .adc_miso(adc_miso), .kext(kext));

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

    // 产生一次心跳上升沿并收下随之发出的字节
    task heartbeat_and_recv(output [7:0] b);
        begin
            force dut.cnt[24] = 1'b0; repeat (4) @(posedge sys_clk);
            force dut.cnt[24] = 1'b1;
            recv_byte(b);
            frames = frames + 1;
            #(2 * BIT_CLKS * 20);                   // 等停止位结束、ready 恢复
        end
    endtask
    initial begin
        #20_000_000 $display("FAIL: watchdog"); $finish;
    end

    initial begin
        // 安全态断言
        repeat (20) @(posedge sys_clk); #1;
        if (pwma !== 0 || ain1 !== 0 || ain2 !== 0 || adc_cs !== 1) begin
            errors = errors + 1; $display("FAIL: motor/adc not in safe state");
        end
        if (uart_tx !== 1'b1) begin errors = errors + 1; $display("FAIL: uart_tx idle not high"); end

        // 心跳加速：force cnt[24] 产生上升沿，触发发送一个字节 = 编码器计数低 8 位
        // 1) 静止：期望 0x00
        heartbeat_and_recv(got);
        if (got !== 8'h00) begin errors = errors + 1; $display("FAIL: idle count byte %h want 00", got); end

        // 2) 正转 1 个周期 = +4：期望 0x04
        fwd_cycle;
        heartbeat_and_recv(got);
        if (got !== 8'h04) begin errors = errors + 1; $display("FAIL: after +1 cycle byte %h want 04", got); end

        // 3) 反转 2 个周期 = -8，累计 -4：期望补码 0xFC
        rev_cycle; rev_cycle;
        heartbeat_and_recv(got);
        if (got !== 8'hFC) begin errors = errors + 1; $display("FAIL: after -2 cycles byte %h want FC", got); end

        if (errors == 0) $display("PASS: top smoke, %0d frames", frames);
        else             $display("RESULT: %0d failure(s)", errors);
        $finish;
    end
endmodule
