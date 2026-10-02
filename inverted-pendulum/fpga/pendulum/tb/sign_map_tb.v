`timescale 1ns/1ps
// sign_map 端口级 TB：纯组合的"安装坐标 <-> 物理坐标"边界（纪律 §2）。
// 三个方向常数只在这个模块里定义并应用一次，其余模块一律在物理坐标工作。
module sign_map_tb;
    reg  [11:0]        adc_raw;
    reg  signed [31:0] enc_raw;
    reg  signed [7:0]  u_ctrl;
    wire [11:0]        adc;
    wire signed [31:0] enc;
    wire signed [7:0]  u;
    integer            errors = 0;

    // 默认安装（与阶段 0 仿真一致）：ANGLE +1 / MOTOR -1 / ENC +1
    sign_map #(.CENTER_CODE(2010), .ANGLE_SIGN(1), .MOTOR_SIGN(-1), .ENC_SIGN(1)) dut (
        .adc_code_raw(adc_raw), .enc_raw(enc_raw), .u_ctrl(u_ctrl),
        .adc_code(adc), .enc(enc), .u(u));

    reg [11:0]        adc_b;  reg signed [31:0] enc_b;  reg signed [7:0] u_b;
    sign_map #(.CENTER_CODE(2010), .ANGLE_SIGN(-1), .MOTOR_SIGN(1), .ENC_SIGN(-1)) dut_b (
        .adc_code_raw(adc_raw), .enc_raw(enc_raw), .u_ctrl(u_ctrl),
        .adc_code(adc_b), .enc(enc_b), .u(u_b));

    task check(input cond, input [8*64-1:0] msg);
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %0s", msg);
        end
    endtask

    initial begin
        // 切片 1：默认安装下 adc/enc 直通、u 取反（MOTOR_SIGN=-1）
        adc_raw = 12'd2010; enc_raw = 32'sd100; u_ctrl = 8'sd40;
        #1;
        check(adc === 12'd2010, "slice1: ANGLE_SIGN=+1 -> adc passthrough");
        check(enc === 32'sd100,  "slice1: ENC_SIGN=+1 -> enc passthrough");
        check(u === -8'sd40,     "slice1: MOTOR_SIGN=-1 -> u negated");

        // 切片 2：ANGLE_SIGN=-1 时围绕中心反射
        adc_raw = 12'd2110;                       // 中心 +100
        #1;
        check(adc_b === 12'd1910, "slice2: ANGLE_SIGN=-1 -> 2*CENTER-code (2110 -> 1910)");
        adc_raw = 12'd1910;
        #1;
        check(adc_b === 12'd2110, "slice2: ANGLE_SIGN=-1 mirrors back (1910 -> 2110)");

        // 切片 2b：反射结果钳位（不回绕）。CENTER=2010：4095 -> 2*2010-4095 = -75 -> 0
        adc_raw = 12'd4095;
        #1;
        check(adc_b === 12'd0, "slice2b: ANGLE_SIGN=-1 clamps below 0 (4095 -> 0)");
        adc_raw = 12'd0;
        #1;
        check(adc_b === 12'd4020, "slice2b: ANGLE_SIGN=-1 clamps above (0 -> 4020)");

        // 切片 3：ENC_SIGN=-1 取反
        enc_raw = -32'sd250;
        #1;
        check(enc_b === 32'sd250, "slice3: ENC_SIGN=-1 -> enc negated");

        // 切片 4：u=-128 在 MOTOR_SIGN=-1 下仍为 -128（-128 无正对应值，8 位饱和语义）
        u_ctrl = -8'sd128;
        #1;
        check(u === -8'sd128, "slice4: u=-128 negated stays -128 (8-bit)");
        u_ctrl = 8'sd127;
        #1;
        check(u === -8'sd127, "slice4: u=+127 with MOTOR_SIGN=-1 -> -127");

        if (errors == 0) $display("PASS: all slices");
        else             $display("RESULT: %0d failure(s)", errors);
        $finish;
    end
endmodule
