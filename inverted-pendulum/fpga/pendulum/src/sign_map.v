// 安装坐标 <-> 物理坐标 的唯一边界（纪律 §2）。
// 三个方向常数（ANGLE_SIGN / MOTOR_SIGN / ENC_SIGN）只在本模块定义并各应用一次：
//   adc_code : 传感器安装方向。ANGLE_SIGN=+1 直通；-1 时围绕 CENTER_CODE 反射。
//   enc      : 编码器安装方向。
//   u        : 控制律输出 -> 执行器方向（MOTOR_SIGN=-1 表示电机接线与模型约定相反）。
// 其余模块（pid / balance_ctrl / pwm_gen）一律在物理坐标工作，不做任何方向映射。
// 上板 bring-up 时手拨实测三个常数，只改这一个文件的参数。
module sign_map #(
    parameter integer CENTER_CODE = 2010,   // 摆角垂直位 ADC 码值（实物标定）
    parameter integer ANGLE_SIGN  = 1,
    parameter integer MOTOR_SIGN  = -1,
    parameter integer ENC_SIGN    = 1
) (
    input  wire [11:0]        adc_code_raw,
    input  wire signed [31:0] enc_raw,
    input  wire signed [7:0]  u_ctrl,
    output wire [11:0]        adc_code,
    output wire signed [31:0] enc,
    output wire signed [7:0]  u
);
    // 传感器方向：反射时用"两倍中心减原值"，结果钳位回 12 位码值域（不是回绕）。
    // 例：CENTER=2010 时 4095 -> -75 -> 钳到 0；-5 -> 钳到 0。极端值本就落在控制窗口外。
    localparam integer TWO_CENTER = CENTER_CODE * 2;
    wire signed [13:0] adc_mirror = TWO_CENTER[13:0] - $signed({2'b0, adc_code_raw});
    wire        [11:0] adc_clamped = (adc_mirror < 0)     ? 12'd0 :
                                     (adc_mirror > 4095)  ? 12'd4095 :
                                                            adc_mirror[11:0];
    assign adc_code = (ANGLE_SIGN > 0) ? adc_code_raw : adc_clamped;

    assign enc = (ENC_SIGN > 0) ? enc_raw : -enc_raw;

    // 执行器方向：-u 在 8 位补码下对 -128 仍为 -128（该点无正对应值，按饱和处理）
    assign u = (MOTOR_SIGN > 0) ? u_ctrl : -u_ctrl;
endmodule
