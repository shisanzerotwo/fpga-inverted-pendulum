# GD32F303 摆角 ADC 采样 + 原码转发（FPGA 倒立摆采集前置）

## 作用

把摆角电位器的 12bit ADC 原码，按固定帧协议以 1 kHz 转发给 FPGA。**只采样、只转发**，
不滤波、不换算、不判断——滤波/角度换算/双环 PID/能量起摆/PWM 全部在 FPGA 内（赛题合规分工）。

## 链路与引脚

| 环节 | 引脚 | 说明 |
|---|---|---|
| 电位器输入 | `EX_PB0` = GD32 `PB0` = `ADC01_IN8` | 排针上的 ARM 6 脚之一，已实物核对 |
| 转发出口 | GD32 `PA2` = `USART1_TX` | 板内直连 FPGA `K11`（不引排针），FPGA 侧 `adc_rx` |
| 下载/调试 | 6P 排针，Windows 侧 `COM7` | FPGA/ARM 两通道互斥，需按键切换 |

## 帧协议（与 `fpga/pendulum/src/adc_bridge.v` 严格一致）

```
1 Mbaud, 8N1, 每帧 4 字节, 1 kHz
[0] 0xA5                    帧同步
[1] {4'b0, code[11:8]}      高 4 位恒 0（接收侧据此判错位并就地重同步）
[2] code[7:0]
[3] 0xA5 ^ [1] ^ [2]        XOR 校验
```

接收侧容限实测 −4.8%~+5.5%（`adc_bridge.v` 头注释有推导）。

## 时钟与节拍

- 系统时钟按 GD32F303 常规 120 MHz 配置，`CK_APB2 = 120 MHz`。
- ADC 时钟 `CK_APB2 / 12 = 10 MHz`（手册上限 14 MHz，取 /8 = 15 MHz 会超）。
- `TIMER2` 1 kHz 溢出中断触发一次采样 + 发送；主循环空转。

## 编译与烧录

**本机没有 ARM 工具链**（已核实无 Keil / IAR / `arm-none-eabi-gcc`，官方环境包里
只有 GigaDevice 的 Keil/IAR 器件支持包 DFP，不含编译器），因此本目录只有源码、未编译。

需要你这边补工具链后：

1. Keil MDK：装 `GD32F30x_AddOn_V2.2.3/GigaDevice.GD32F30x_DFP.2.2.3.pack`，新建工程加入
   - `src/main.c`
   - `GD32F30x_Firmware_Library_V2.1.5/Firmware/GD32F30x_standard_peripheral/Source/*.c`
   - 启动文件 `startup_gd32f30x_hd.s`（F303 属高密度）
   - 链接脚本/散列文件用库里的默认配置
2. 烧录走 6P/`COM7`。若芯片被锁：按住 BOOT 再复位进 DFU，先 `Erase` 再烧（wiki 常见问题页）。
3. 上板后用示波器/逻辑分析仪看 `PA2`，或直接把 FPGA 侧的 `adc_rx` 接到 `adc_bridge` 上，
   用 `top.v` 的 4 字节自检帧读 `adc_code` 低 8 位。

## 待实测确认（未核实，不要当事实用）

- `ADC_SAMPLETIME_239POINT5` 是否足够/是否必要——取决于电位器输出阻抗，上板看读数稳定性再定。
- 120 MHz 主频的具体 PLL 配置由 Keil 工程的 `system_gd32f30x.c` 决定，本文件未包含该配置。
- 1 kHz 节拍下 USART1 发送 4 字节（40 µs）占用中断时间很短，但未实测 CPU 负载。
