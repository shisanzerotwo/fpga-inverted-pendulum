# GD32F303 远程 ADC 固件

本目录保存逻辑派 FPGA-G1 板载 GD32F303CBT6 的 ADC 固件。当前工程使用 **UART 传输版本**；旧 SPI 版本只作为历史和备回切资料。

## 当前实现

| 项目 | 当前值 |
|---|---|
| 角度输入 | GD32 `PB0 / ADC0 CH8`，配件板 J1-2（SENSOR1 OUT） |
| ADC 配置 | 20 MHz ADC 时钟，`239.5` 周期采样；生产 A 使用规则组连续采样并读 `RDATA` |
| FPGA 链路 | GD32 `PA2 / USART1_TX` → FPGA `K11`，1 Mbps、8N1 |
| 数据帧 | 每帧 2 字节：高字节 `{seq[3:0], adc[11:8]}`，低字节 `adc[7:0]` |
| 调试输出 | GD32 `USART0`：`PA9` 经 CN1.1 输出 `Axxxx`，115200 8N1 |
| 当前现场状态 | 用户确认ADC修复通过并更换为相同型号新板；用户报告GD32固件和FPGA位流已烧入。FPGA UserCode=`0xFD3D`且STOP遥测安全字段通过；最后确认12V关闭、ARM/STOP、未按KEY1。GD32 Flash未读回比对；下一步在12V关闭时切FPGA档并复核STOP，再采供电角度基线、重标`ANG_OFFSET` |

生产源代码是 [`main_uart.c`](main_uart.c)。FPGA 接收端是 [`arm_adc_uart.v`](../fpga_project/src/arm_adc_uart.v)。

## 固件变体

| 变体 | 文件/产物 | 用途 | 当前规则 |
|---|---|---|---|
| 生产 A | `main_uart.c` → `build_uart/gd32_uart.hex` | 正常 UART 运行 | 用户报告已烧入新板；Flash读回比较未做。当前以现场运行遥测继续角度标定 |
| 诊断 B | `docs/verification/2026-10-23/adc_single_trial/` | 显式单次转换、带完成/超时计数的 STOP 诊断 | 仅旧板诊断固件；新板当前固件未知，不假设已安装 B |
| 历史 SPI | `main.c`、`diag_main.c` | 旧 SPI0 从机链路 | 当前 FPGA UART 位流不使用 |

诊断 B 的烧写和全范围比较证据见 [NEXT_SESSION.md](../docs/verification/2026-10-23/NEXT_SESSION.md)。B 的计数地址、采集器和 A 不兼容，不能混用。

## 构建

从工程根目录 `verilog` 执行当前 UART 固件构建：

```text
bash _tools/build_gd32_uart.sh
```

输出：`gd32_fw/build_uart/gd32_uart.elf`、`.hex` 和 `.map`。脚本会优先探测工程内的 `msys2-arm` 工具链。

`gd32_fw/build.sh` 及其默认产物属于旧 SPI 变体；除非明确进行历史回切，不要用它覆盖当前 UART 固件。

## 烧写与恢复边界

- 写入前必须保持配件板 12V 关闭、ARM 档并核对目标芯片身份；更换芯片或板卡后重新核对容量和地址范围。
- 旧板生产 A 的 128 KiB 原始备份和哈希在 `docs/verification/2026-10-23/`，仅作为旧板证据/固件参考；不得据此推断新板当前内容。新板恢复流程以 [NEXT_SESSION.md](../docs/verification/2026-10-23/NEXT_SESSION.md) 为准。
- 旧 `_tools/gd32_isp.py flash` 的擦写 framing 没有成功证据，禁止直接用于生产恢复；使用已核验的官方 Pack/FLM 流程，并在写后读回比较。
- 用户已确认ADC修复通过。本轮12V关闭的STOP遥测只证明FPGA身份和安全输出，不用于角度标定；下一步在STOP下采供电后的摆杆姿态基线，以竖直ADC中位数更新`ANG_OFFSET`。基线与新FPGA位流核验完成前不启动电机，也不盲改`ANGLE_ADC_CH`。

## 历史资料定位

- ADC 版本链和暂停边界：[ADC_REGRESSION.md](../docs/verification/2026-10-23/ADC_REGRESSION.md)
- 总交接：[HANDOVER.md](../HANDOVER.md)
- 旧 SPI 协议细节：`main.c` 顶部注释和历史验证报告；不要把旧协议表格当作当前接口。
