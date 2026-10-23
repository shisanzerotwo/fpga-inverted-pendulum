# 2026-10-23 现场预检与 ADC 软件诊断（进行中）

## 当前结论

**ADC 跟随未通过，不能标定或启动电机。当前 Flash 已证实是正式 UART 固件，版本错配假说排除。**按用户确认，后续以硬件、接线无误为排查前提，检查运行态 ADC 与数据路径。

最后一次用户确认的实物状态：配件板 **12V 关闭、USB 保留、ARM 档**；用户只点按 SW4 后，已从 GD32 CN1 调试串口采到应用输出。切换 ARM 档后尚未重新读取 FPGA UserCode，不能把切换前状态当作新的上板核实。

## 固定输入与离线证据

- 父 Git 仓库 `D:/GitHub/xiangmu/FPGA`，本轮开工 HEAD `e501be6`；活跃 `verilog/` 副本原先整体未跟踪。另一个正式仓库有用户暂存/未提交改动，本轮未操作。
- `source_snapshot.json` 冻结 23 项源码/输入；本轮未修改控制 RTL 或 GD32 固件源码。
- 14 个现有 testbench 首轮 **13/14**，`loc_target_tb` 在 90.091 秒超时。相同二进制用 `vvp <file> -none` 禁用波形补验，45.913 秒 PASS；历史首轮结果仍保留。
- Gowin 构建完成，50 MHz 约束，Setup/Hold 违例端点均 0，TNS 均 0，Fmax 53.911 MHz；仍有既有警告，不能表述为零警告。
- 新位流 `fpga_project/impl/pnr/fpga_project.fs`：UserCode **0xFD3D**，SHA256 `63cae0ec4fc8b4af6bb5c7f3dc1138d70bd7a411aa96de4b4275b38186eb6173`。
- 独立验证记录见 [INDEPENDENT.md](INDEPENDENT.md)。独立发现 `loc_target_gen` 的 8 位分频器不能容纳 DIV=500，属于另项既有问题，本轮未修改。

## FPGA 恢复与停止态

最初实际板上 UserCode 为 **0x0A37**；8 秒采集只有 80 字节、合法新协议遥测 0 帧。用户关 12V 后加载新 SRAM 位流；首次相对路径命令失败，改绝对路径成功，随后设备读取确认 **0xFD3D / Status 0x6020**。这些前后日志均保留。

`after_sram.bin`：381 个合法帧，序号无断裂，全部 **STOP / duty=0 / enable=0 / braking=1 / link=1**。这只证明该次采集的停止联锁及序号链路，不证明角度反馈正确。

## ADC 跟随原件

| 用户保持的姿态 | 原件 | 帧数 | ADC 范围 | 中位数 |
|---|---|---:|---|---:|
| 初次自然下垂 | `hanging.bin` | 286 | 3827–3855 | 3849 |
| 初次竖直朝上 | `upright.bin` | 285 | 3826–3853 | 3846 |
| 固定联轴器后下垂 | `hanging_fixed.bin` | 286 | 3839–3859 | 3852 |
| 固定联轴器后朝上 | `upright_fixed.bin` | 286 | 3846–3859 | 3853 |

以上完整帧全部 STOP、duty0、enable0、braking1、link1、序号连续。固定后的中位差 **1**，小于组内跨度 **20**。不能称机械修复已解决问题。

复跑命令（当前预期 **exit 1**，表示明确复现未跟随）：

```powershell
python docs/verification/2026-10-23/verify_adc_follow.py docs/verification/2026-10-23/hanging_fixed.bin docs/verification/2026-10-23/upright_fixed.bin --output docs/verification/2026-10-23
```

诊断门槛为：每组至少 100 个连续 STOP/link 帧，姿态中位差 > `max(200, 3×组内最大跨度)`。200 counts 用于把交接所需的“几百 counts”大范围响应与噪声分开，**不是角度标定参数**。当前即使用只要求“大于噪声”的弱门槛也仍不通过。

![ADC 跟随未通过：两组处于同一噪声带](adc_follow.png)

图片横轴仅是有效样本序号；没有采用旧 SPI 固定周期推算当前 UART 数据时间。

## 当前 Flash 身份：已经独立核实

只读命令（无 Flash 擦写、无 GO）：

```powershell
python docs/verification/2026-10-23/read_current_flash.py
```

首次等待按键 180 秒超时，记录在 `gd32_read_attempt1.{log,json}`。收到用户按键完成后再次打开，握手首试成功，设备 ID **0x0414**。

两遍读取 `0x08000000..0x08000FFF`，各 **4096 字节完全一致**：

```text
ac8d72a7021c2186e41af56eed80b9d181a6ca4943dd206d61b17de33952d1ae
```

向量表 SP=`0x20008000`、Reset=`0x08000131`。独立验证者自行解析 HEX 和 ELF32，确认正式 UART 的 **3300 个已定义加载字节全部匹配**，扫描版的 3524 个地址中有 **2730 字节差异**。其他候选均不匹配。

边界：只覆盖前 4 KB；“匹配”指候选 HEX/ELF 定义的地址，不能称整片 Flash 都与某镜像一致。读回工具的命令白名单只允许 GET/GET_ID/READ，独立 Mock 对照验证拒绝 GO/WRITE/ERASE/UNPROTECT。打开串口及 RTS/DTR 操作可能改变复位/启动状态，“只读”不等于不扰动运行。

历史 `_tools/_readback_20261021.bin` 与扫描版完全匹配，只能说明 10 月 21 日的状态，**不能作为当前故障根因**。本轮没有重刷正式固件。

## GD32 直接输出与后续探针

首次尝试从 ROM GO 返回应用时 GetID 收到 NACK，尚未发送 GO；失败脚本与日志保留为 `capture_gd32_debug_attempt1.py`、`gd32_cn1_attempt1.log`。随后改为用户只点按 SW4 正常复位，串口保持打开，仅接收数据。

`gd32_cn1_12v_off_normal.bin`：8.008 秒，400 条合法 `Axxxx` 行，ADC 3842–3855、中位数 **3848**，SHA256 `74620e8e29c1f533810f6955e335e387c8f2caad5e5877d75d6d64694512676e`。这是 **12V 关闭状态**，尚无同时段姿态激励，不能直接代替上电后的跟随验证。

静态审查已确认当前规则组连续采样配置与官方 SDK 调用一致，尚未证实触发错误。持续大阶跃会在最多 16 次主循环接受；这不是 16 个已确认的新转换。两字节来自同一 ADC 快照。`link=1` 只证明序号新鲜，固件没有显式暴露转换完成计数、校准超时或采样年龄，下一步需要运行态观察，不能靠盲调 offset 修复。

优先探针为 SWD attach 读取 ADC0 `STAT/CTL0/CTL1/SAMPT1/RSQ0/RSQ2/RDATA` 与 `g_adc`，先确认工具不自动解保护、擦写、复位或停机。相关地址已从本机官方头文件和匹配 Flash 的 ELF 核实，见独立追加记录。若无法建立无修改观察通道，如实记录限制，不把缺观测当作故障结论。

## 未完成

运行态 ADC 根因定位、真实角度变化验证、ANG_OFFSET 标定、用户启动后的起摆/平衡验证均未完成。不得宣称倒立验收通过。当前 12V 应保持关闭，等待运行态探针结果。
