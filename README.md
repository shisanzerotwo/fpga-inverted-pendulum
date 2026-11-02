# 旋转倒立摆 FPGA 工程（2026 嵌赛·高云赛道）

竞赛旋转式倒立摆的 FPGA + GD32 完整工程。本仓库的历史继承了 [LeiWang1999/FPGA](https://github.com/LeiWang1999/FPGA) 学习资料镜像（`boards/`、`license/` 等目录来自上游），**倒立摆项目全部内容在 [`verilog/`](verilog/) 目录**，交接与验收以该目录为准。早期 M1 开发线（2026-09-29 ~ 10-02）保留在 `archive/m1-initial` 分支。

## 先看这几份

1. [HANDOVER.md](verilog/HANDOVER.md)：硬件、源码、烧录工具链和历史踩坑的总交接（唯一交接入口）。
2. [项目进度与验收状态](verilog/docs/项目进度与验收状态.md)：基础要求与拓展要求逐项进度。
3. [NEXT_SESSION.md](verilog/docs/verification/2026-10-23/NEXT_SESSION.md)：下一次接手的执行入口。
4. [REPORT.md](verilog/docs/verification/2026-10-23/REPORT.md)：旧板 ADC 证据和限制。
5. [ADC_REGRESSION.md](verilog/docs/verification/2026-10-23/ADC_REGRESSION.md)：旧板软件 A/B 排查的版本链与历史边界。
6. [2026-10-24 任务卡](verilog/docs/tasks/2026-10-24-adc-ab.md)：旧板 A/B 任务归档，不要按旧计划继续刷写。

## 当前状态（2026-11-02）

- 定版位流 **0x2AD3**（10-31）：旋钮运行时 AUTO/MANUAL 切换实机验收通过（SW 切换、MANUAL 无自动移动、旋钮调位置、AUTO 演示 12.9 s 周期 ±408）；端点折叠方案已 A/B 证伪并回退。
- 11-02 位流 **0x833D**：KEY1 加 30 ms 电平消抖，消除平衡中的幻影边沿停机。
- 剩余为线下硬件排查（电位器端点噪声、串口假帧、信号质量波动）与报告/答辩材料；比赛截止 2026-11-04。
- 一切以 [verilog/HANDOVER.md](verilog/HANDOVER.md) 顶部为准；带日期的"当前/下一步"只对当时快照成立。

## 当前架构

| 层 | 当前实现 | 入口 |
|---|---|---|
| FPGA 控制 | Gowin GW2A，位置/角度控制、PWM、编码器和遥测 | `verilog/fpga_project/src/top.v` |
| 远程 ADC | 板载 GD32F303 读取 PB0 / ADC0 CH8 | `verilog/gd32_fw/main_uart.c` |
| FPGA↔GD32 链路 | GD32 PA2（USART1 TX）→ FPGA K11，1 Mbps 8N1；帧为 `[seq4\|adc12]` | `verilog/fpga_project/src/arm_adc_uart.v`、`verilog/gd32_fw/main_uart.c` |
| 角度输入 | 配件板 J1-2（OUT）→ GD32 PB0 / CH8；电位器供电来自配件板 | [verilog/docs/排针引脚表.md](verilog/docs/排针引脚表.md)、[verilog/docs/kitdoc/](verilog/docs/kitdoc/) |
| 调试串口 | GD32 USART0 PA9/PA10，经 CN1 输出 `Axxxx` | `verilog/gd32_fw/main_uart.c` |

旧的 SPI 主从链路仍保存在 `verilog/gd32_fw/main.c` 和 `verilog/fpga_project/src/arm_adc_link.v` 中，作为历史/备回切资料；当前 UART 位流不使用它们。旧 MCP3202、外挂 SPI ADC 和"FPGA 不使用 MCU"的说明也都是历史方案，不能作为当前接线或采购依据。

## 目录地图

- [`verilog/fpga_project/`](verilog/fpga_project/)：Gowin 工程、RTL、约束、testbench 和可复现构建脚本。
- [`verilog/gd32_fw/`](verilog/gd32_fw/)：GD32 固件源码；当前生产源是 `main_uart.c`，构建脚本 `build.sh`（`build*` 产物目录不入库）。
- [`verilog/docs/`](verilog/docs/)：板卡资料、引脚表、硬件资料和验证证据。
- `verilog/_tools/`：构建、采集、分析和烧录辅助工具。涉及写入时先读 [HANDOVER.md](verilog/HANDOVER.md) 的限制。

## 本地构建

FPGA（不打开 GUI）：

```text
"D:\Gowin\Gowin_V1.9.10.02_x64\IDE\bin\gw_sh.exe" verilog/_tools/gw_build.tcl
```

GD32 当前 UART 固件：

```text
bash verilog/_tools/build_gd32_uart.sh
```

烧录、读回和 12V 安全前提统一以 [HANDOVER.md](verilog/HANDOVER.md) 和 [NEXT_SESSION.md](verilog/docs/verification/2026-10-23/NEXT_SESSION.md) 为准。旧 `_tools/gd32_isp.py flash` 没有成功证据，禁止把它当作生产恢复路径。

## 资料和版本边界

- 原始验证文件不删除、不覆盖；报告中带日期的"当前/下一步"只对当时快照成立，最新状态以 [verilog/HANDOVER.md](verilog/HANDOVER.md) 顶部为准。
- 如果硬件更换芯片或板卡，必须重新核对芯片型号、Flash 容量、引脚和烧录边界；旧设备身份和旧哈希不能直接套用。
