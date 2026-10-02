# CLAUDE.md — fpga-inverted-pendulum（Claude 侧工作约定）

> **事实库是 `AGENTS.md`**（由 pi 维护，含硬件参数、工具链路径、纪律、进度快照）。
> 本文件只记录 Claude 侧的工作约定与阶段进度，**不重复、不覆盖 AGENTS.md 的事实**。
> 写入边界：Claude 不写 `AGENTS.md`（多 agent 同文件并发写会丢改动，见 AGENTS.md §六-9）。

---

## 一、提交纪律（用户要求，2026-10-02 起）

**每完成一个阶段任务，立即本地 git 提交**，不攒改动。一次提交 = 一个可复述的完成点。

具体要求：
- **验证通过才提交**：TB 全绿 / 综合通过 / 上板实测通过之后再 commit。红基线不提交
  （教训：`f43f4b9` 曾把 `balance_ctrl_tb` slice5 红的版本提交上去，后被 pi 复现出来）。
- **提交信息写清"做了什么 + 怎么验证的"**：包含实测数字（资源占用、Fmax、切片数、变异对照结果），
  以及**有意与参考实现不同的地方**。这些内容不进 AGENTS.md，就靠 commit message 留档。
- **提交前自查**：
  - `git status` 确认没有误带上未审查的文件（`.mcp.json`、截图等）；
  - 行尾：`git diff --ignore-all-space --stat` 若为空说明只是行尾差异，本机 `core.autocrlf=true`
    与其他环境不同，必要时把文件统一成 LF；
  - 不留无意义空提交。
- **推送**：默认只在本机提交，需要推送时由用户明确说。

## 二、开发纪律（本项目硬约束，与 AGENTS.md §六 一致）

实施时重点遵守：
- **TDD 节奏**：先写 TB 确认红 → 最小实现转绿 → 再补下一个切片；每个切片做**变异对照**
  （故意改坏 RTL，确认测试能抓出来），变异文件必须基于**当前版本**生成。
- **整数域模块要求逐位一致**：与精确有理数（`Fraction`）期望零分歧；只有和 float 参考对比时才容 ±1。
- **引脚结论双证**：原理图 + 实物丝印，之后才写进 `.cst`。
- **方向常数单点定义**：只在 `src/sign_map.v` 定义一次。
- **模型不能批准自己的完成**：RTL 正确性由独立期望值判定，不接受"整体差不多"。

## 三、阶段进度（Claude 侧，逐步更新）

| 阶段 | 内容 | 状态 |
|---|---|---|
| 0 建模仿真 | Python 建模 + 双环 PID/能量起摆/LQR | ✅ |
| 1 环境与骨架 | Gowin 全流程 + M1 工程骨架 | ✅ |
| 2 采集链 RTL | `uart_tx` / `quad_decoder` / `adc_bridge` | ✅ 均含 TB + 变异对照 + 上板验证 |
| 3 控制律 RTL | `pid` / `pwm_gen` / `balance_ctrl` / `sign_map` | ✅ 仿真通过 |
| 3.5 顶层集成 | `top.v` 全链 + 4 字节自检帧 | ✅ 可综合，8 个 TB 全绿 |
| 4 GD32 固件 | ADC 采样 + 原码转发源码 | ⚠️ **未编译**（本机无 ARM 工具链） |
| 5 稳摆上板 | 实物标定 + 稳摆 | ⬜ 待板子在线 |

当前阻塞：GD32 固件需装 Keil/IAR 才能编译烧录；板子不在线，无法上板验证。

## 四、可复用命令（Claude 侧）

```bash
# 仿真（Git Bash；oss-cad-suite 不进 PATH 时先导出）
export PATH="/e/FBGA/oss-cad-suite/bin:/e/FBGA/oss-cad-suite/lib:$PATH"
cd inverted-pendulum/fpga/pendulum/tb
iverilog -g2012 -o <t>_tb.vvp <t>_tb.v ../src/<t>.v && vvp <t>_tb.vvp     # 单模块
# 整链 top 冒烟需带全部源文件：top uart_tx quad_decoder adc_bridge sign_map pid pwm_gen balance_ctrl
# 对拍向量重新生成
cd inverted-pendulum/sim && PYTHONIOENCODING=utf-8 py export_vectors.py

# 构建（综合 + 布线 + 比特流）
cd inverted-pendulum/fpga/pendulum && "/e/FBGA/Gowin/Gowin_V1.9.10.02_x64/IDE/bin/gw_sh.exe" build.tcl
# 下载（板子在线时）
"/e/FBGA/Gowin/Gowin_V1.9.10.02_x64/Programmer/bin/programmer_cli.exe" \
  --device GW2A-18C --cable "Gowin USB Cable(FT2CH)" --run 2 --fsFile "<绝对路径>/pendulum.fs"
# 成功标志：Status Code 0x00006020 + Finished；拔线时返回 exit 50
# 读串口（FPGA 输出在 COM9，COM7 是 GD32 固件自己的文本）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/read_com.ps1 COM9 115200 6
```

## 五、与 pi 的分工

- **pi**：维护 `AGENTS.md`、文档、独立复现验证（会指出我的红基线提交这类问题）。
- **Claude**：RTL / TB / 固件源码 / commit；不写 `AGENTS.md`。
- 需要记录的事实、实测结果、协议约定 → 放 commit message、代码注释，或直接说明给用户/pi。
