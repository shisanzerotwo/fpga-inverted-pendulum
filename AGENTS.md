# AGENTS.md — fpga-inverted-pendulum 项目级 agent 说明

> 本文件是本仓库的 agent 入口：新会话/新 agent 先读这里。
> 只写**已验证的事实**与**可执行的纪律**；推断内容必须标注。事实变了就改本文件。
> 最近核实：2026-10-01（本机环境与工具链路径均实测）。

---

## 一、项目一句话

2026 嵌入式竞赛 · FPGA 赛道 选题一：**基于 FPGA 的实时姿态控制系统（旋转式倒立摆）**。
主控＝立创·逻辑派 FPGA-G1（高云 **GW2A-LV18PG256C8/I7**，自备板）；机构＝江协科技 PID 倒立摆套件。
**合规红线**：感知→滤波→控制律→PWM 全链路用 **RTL 实现于 FPGA 内部**，MCU（板载 GD32 / 套件 STM32）**不得承载控制算法**，最终作品保持空闲。

## 二、目录导航

```
docs/2026嵌赛选题一/
  备赛总结与规划.md        ← 事实库：赛题/硬件参数/接线表/技术方案/路线图/风险登记册
  发展规划-到货前RTL冲刺与完赛路线.md  ← W1~W4 周计划 + 里程碑 M1~M9 + 倒排表
  排针映射与IO分配.md      ← EX_ 网络清单（66 个）+ 拟用 IO 初选 + 实物核对步骤
inverted-pendulum/
  sim/                     ← 阶段 0：Python 非线性建模 + 双环 PID/能量起摆/LQR 仿真
    model.py  controller.py  run_sim.py  sim_out/*.png
  fpga/test_env/           ← 阶段 1：Gowin 环境验收工程（build.tcl 一键构建）
  fpga/pendulum/           ← 阶段 2+ 正式工程（待建，见 §五）
```
仓库外资料（**不入库**）：`D:\GitHub\xiangmu\FPGA\逻辑派FPGA-G1\`、`D:\GitHub\xiangmu\FPGA\江协PID倒立摆套件资料\`。

## 三、工具链与环境（2026-10-01 实测，路径以本节为准）

### 3.1 统一根目录：`E:\FBGA\`（本机 FPGA 工具链唯一存放处）

| 工具 | 路径 | 用途 |
|---|---|---|
| Gowin IDE V1.9.10.02 | `E:\FBGA\Gowin\Gowin_V1.9.10.02_x64\` | 综合/布线/比特流；`IDE\bin\gw_ide.exe` 图形界面 |
| gw_sh（Tcl 构建） | `…\IDE\bin\gw_sh.exe` | 命令行一键构建（本项目首选） |
| Gowin Programmer | `…\Programmer\bin\programmer.exe` / `programmer_cli.exe` | 下载比特流到板卡 |
| oss-cad-suite | `E:\FBGA\oss-cad-suite\`（iverilog 14.0 / yosys 0.69 / gtkwave 4.0 / openFPGALoader 1.1.1） | **RTL 功能仿真与 TB**，见 §四 |
| 安装包归档 | `E:\FBGA\downloads\`（Gowin 安装器 + oss-cad-suite tgz） | 重装/回滚来源 |

**授权**：Gowin 用立创浮动 license 服务器 `124.220.54.112:10559`，写在
`…\IDE\bin\gwlicense.ini`（注：界面显示的 14 天是刷新周期，不是过期）。备份变体见 `E:\FBGA\Gowin\gwlicense.ini.*`。

### 3.2 运行与调试

- **Python**：本机 `python`/`python3` **不可用**（分别指向 hermes venv 与 WindowsApps 占位程序）。
  `sim/` 一律用 **`py`**（→ `C:\Users\22421\AppData\Local\Programs\Python\Python314\python.exe`），已装 numpy 2.4.1 / scipy 1.17.0 / matplotlib 3.10.8。
  运行：`cd inverted-pendulum\sim && py run_sim.py`
- **Shell**：Windows 上的 **Git Bash**（路径形如 `/e/FBGA`、`/d/GitHub`）。GitHub 网络从 Windows 侧（PowerShell / curl.exe）可达，Git Bash 内置 curl 在本机连 GitHub 会失败。
- **WSL**：有 Ubuntu，但没有 iverilog/verilator —— 仿真统一走 §四 的 Windows 侧 oss-cad-suite。

### 3.3 已知可行/不可行（别重复踩）

- `verilator`（Perl 脚本）在本机**跑不起来**：oss-cad-suite 的 Windows 包不带 Perl，系统 Perl 缺 `Pod::Usage`。→ 用 `iverilog` + `vvp`，够本项目用。
- 中文控制台（cp936）会因个别非 GBK 字符（如 `✓`）抛 `UnicodeEncodeError` 崩掉脚本。
  → 脚本内不要用非 GBK 符号；跑 Python 时加 `PYTHONIOENCODING=utf-8`（或 `chcp 65001`）。

## 四、RTL 仿真用法（open-source 流程）

```bash
# 每次新开的 bash 会话需要先把这个加进 PATH（E:\FBGA\oss-cad-suite\environment.bat 是 CMD 版）
export PATH="/e/FBGA/oss-cad-suite/bin:/e/FBGA/oss-cad-suite/lib:$PATH"

cd <TB 所在目录>
iverilog -g2012 -o tb.vvp xxx_tb.v ../src/xxx.v
vvp tb.vvp                       # 断言/TEXT 输出
gtkwave dump.vcd &               # 看波形（可选）
```
- TB 里 `$dumpfile/$dumpvars` 出 VCD；本项目对拍框架见 `sim/run_sim.py` 的 `export_vectors()`（W3 任务）。
- 无 iverilog/verilator 时兜底：**Gowin 内置仿真器**（未验证，W2 前先试）。

## 五、开发节奏与当前进度

按 `发展规划-到货前RTL冲刺与完赛路线.md` 推进（W1~W4 周计划 + M1~M9 里程碑 + T-相对倒排）。

| 阶段 | 内容 | 状态（2026-10-01） |
|---|---|---|
| 0 建模仿真 | Python 建模 + 双环 PID/能量起摆/LQR | ✅ |
| 1 环境与骨架 | Gowin 全流程通过；工具链统一到 `E:\FBGA` | ✅（本机验收已重跑） |
| 2 采集链 bring-up | 编码器/ADC/UART + 标定三个方向常数 | ⬜ 板卡/套件**已到货** |
| 3 稳摆 | 复刻双环 PID（基础②③） | ⬜ |
| 4 自动起摆 | 能量起摆 + 捕获（基础①） | ⬜ |
| 5 拓展+超越 | 位置/轨迹 + LQR（拓展①②③ + 抖动 ≤±3°） | ⬜ |
| 6 演示与文档 | 视频 / 报告 / RTL 佐证 | ⬜ |

**下一步（阶段 2 开工）**：实物排针丝印核对（`docs/…/排针映射与IO分配.md` §六）→ 定稿 `pendulum.cst`（M1）→ 采集链 RTL + 单元 TB（M2）。

## 六、工作纪律（本项目硬约束）

1. **引脚结论必须"原理图 + 实物丝印"双证**，之后才能写进 `.cst`。单源采信已踩过坑（PDF 标签错位）。
2. **方向常数单点定义**：`ANGLE_SIGN`（传感器）/ `MOTOR_SIGN`（电机）/ `ENC_SIGN`（编码器）只在"安装坐标↔物理坐标"边界模块定义一次；能量起摆在物理坐标直接算力矩，**不经过方向映射**（重复应用会把泵能变耗能，已复现）。
3. **泵能方向必须实验裁决**，公式坐标约定不可盲抄；bring-up 时开环 bang-bang 实测。
4. **模型不能批准自己的完成**：RTL 的正确性由"Python 已验证向量 → TB 逐拍对拍（±2 LSB）"判定，不接受"整体差不多"。
5. **整数域实现**：控制律照搬参考答案的码值域运算（非"浮点算法再定点化"），并加**积分限幅**（阶段 0 已实测积分失控）。
6. **改动前先跑基线**：改 `sim/` 后重跑 `run_sim.py`，用 `git diff` 比对 `sim_out/*.png` 判断影响面（不依赖位置的场景应逐字节不变）。
7. **提交纪律**：不留无意义空提交；推送前扫敏感信息（公开资料链接不落密码）。

## 七、已知坑与教训

- `test_env` 工程的 `led[4]=T10`、`led[1]=C10` 是 **SSPI 专用脚**，工程必须 `set_option -use_sspi_as_gpio 1`，否则引脚不可用。
- `build.tcl` / `.gprj` 里的路径**必须相对脚本/工程解析**（`[file dirname [info script]]`、`../src/...`），写绝对路径一搬家就废（已修，2026-10-01）。
- 场景 3 位置阶跃的**位置环**依赖 `controller.py` 的 `location` 累加；该处曾有重复累加抵消 bug（已修，见 git 历史）——若位置曲线恒为 0，先查这里。
- 竞赛要求数字须带口径：写文档用"快照 + 取值命令"，不写裸数字。
- 装配与上电：PH2.0-6P 接口两份文档引脚序号矛盾（公/母镜像），**以控制板丝印为准**，先万用表核位再插电机；法兰联轴器切面朝上、顶丝对准轴切面。

## 八、关联知识库

- [[嵌入式竞赛 FPGA 倒立摆实战]]（`D:\ObsidianChanku\ai学习\research\FPGA学习\`）——外部记忆，随本项目更新。
- [[本地项目索引]]——项目登记行。
