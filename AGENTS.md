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
  fpga/pendulum/           ← 正式工程：src/top.v + constraint/pendulum.{cst,sdc} + build.tcl（M1 骨架已建）
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
| 1.5 M1 工程骨架 | `fpga/pendulum/`（cst+sdc+安全态顶层），`gw_sh build.tcl` 通过 | ✅ 软件侧；⏳ 实物丝印核对（见下） |
| 2 采集链 bring-up | 编码器/ADC/UART + 标定三个方向常数 | ⬜ 板卡/套件/MCP3202 **已到货**；板子已能下载运行 |
| 3 稳摆 | 复刻双环 PID（基础②③） | ⬜ |
| 4 自动起摆 | 能量起摆 + 捕获（基础①） | ⬜ |
| 5 拓展+超越 | 位置/轨迹 + LQR（拓展①②③ + 抖动 ≤±3°） | ⬜ |
| 6 演示与文档 | 视频 / 报告 / RTL 佐证 | ⬜ |

**截止日 2026-11-10**（2026-10-01 起剩 40 天）；倒排表已压缩，见发展规划 §五：稳摆硬线 10-20、起摆硬线 10-27，LQR 等 stretch 已砍。

### 5.1 进度快照（2026-10-01 会话结束时）

**已完成并已核实**
- 提交已推送 GitHub（`shisanzerotwo/fpga-inverted-pendulum`，master 到 `01b1f88`）。
- M1 软件侧：13 个拟用扩展脚均在原理图 66 个 `EX_` 网络内、与板内占用无交集（脚本核对）；`pendulum.pin.html` 抽查 19 个信号落位正确；逻辑占用 <1%。官方 `.cst`/分配表只含板载功能，**扩展脚无官方第二来源**，第二来源 = 实物丝印。
- **下载链路打通**：板上 GD32 在 Windows 里是 `DAPLink CMSIS-DAP` + `COM7`，但对 Gowin Programmer 表现为 **`Gowin USB Cable (FT2CH)`**，器件识别 `GW2A-18C (0x0000081B)`。`openFPGALoader` 与 `programmer_cli --scan-cables` 在本机都**扫不到/打不开**，别再走这条路。SRAM 下载断电即失效。
- **命令行下载可用**（2026-10-01 实测，**指定 cable 即可，不要 `--scan-cables`**）：
  ```bash
  P="/e/FBGA/Gowin/Gowin_V1.9.10.02_x64/Programmer/bin/programmer_cli.exe"
  "$P" --device GW2A-18C --cable "Gowin USB Cable(FT2CH)" --run 0          # 读器件码，探针
  "$P" --device GW2A-18C --cable "Gowin USB Cable(FT2CH)" --run 2 \
       --fsFile "D:\\GitHub\\xiangmu\\fpga-inverted-pendulum\\inverted-pendulum\\fpga\\pendulum\\pendulum\\impl\\pnr\\pendulum.fs"   # SRAM 下载，约 5s
  ```
  成功标志：`Status Code is: 0x00006020` + `Finished.`。图形界面仍可用作兜底。
- **FPGA 串口（`uart_tx`=F12）读 COM9，不是 COM7**（2026-10-01 实测，只插逻辑派一根 Type-C、无其它下载器）：
  - COM9 = `FTDIBUS\VID_0403+PID_6010`（USB Serial Port）：收到 FPGA 每 0.671s 一个递增字节（与 2²⁵/50MHz 一致），重新下载后从 `01` 重新计数。
  - COM7 = `USB\VID_0D28&PID_0204&MI_01`（DAPLink CDC）：收到的是 **GD32 固件自己**周期发的 GBK 文本（"欢迎使用立创·逻辑派FPGA-G1开发板…GD32 内部温度：xx°C"），不是 FPGA 输出。
  - 两个 USB 身份同一时刻只有一个在线；`programmer_cli` 下载后切到 VID_0403/COM9。读串口用 `tools/read_com.ps1 COM9 115200 6`。
- 下载前要排障的事实：Type-C 线直连电脑 USB 口最稳；曾因线/转接器/口导致 `Device Descriptor Request Failed`（代码 43），换口后正常。
- 已烧过一版自检程序，板上 LED 有多色闪烁（程序确实在跑，时钟与配置正常）。

**未验证（不要当事实用）**
- LED 极性（共阳/低电平点亮）与 6 通道 ↔ 球号（R9/C10/R7/N6/T10/P7）对应关系：**未核实**。`top.v` 当前自检版按"低电平点亮"写，是假设。
- 数码管引脚映射：官方 cst 有 `seg[0..7]`=G13/H16/H12/H13/H14/G12/G11/L14，但未对原理图核对，未点亮过。
- 编码器 A/B、ADC、PWM 等 `.cst` 中 `[待丝印]` 的 13 个扩展脚：**未做实物丝印核对**，也未接外设。

- **`uart_tx` 已上板验证**（2026-10-01）：`src/uart_tx.v`（115200 8N1，valid/ready 握手，复位期间 `ready`=0）；`tb/uart_tx_tb.v` 6 个切片 + `tb/top_tb.v` 冒烟，iverilog 全 PASS，各切片均做过变异阴性对照；`top.v` 每次心跳上升沿发一个递增字节。综合：Logic 97/20736，Fmax 253MHz（约束 50MHz）。

**未跟踪（未审查，勿提交）**：`.mcp.json`、`tools/gowin-mcp/`、`docs/img/MCP3202_p*.png`。`D:\Gowin` 副本**仍在**（用户决定不删；注册表卸载项仍指向它）。

**下一步（按顺序）**
1. 用户重烧最新 `pendulum.fs`：不按键描述各色灯状态；按住 D11、F10 分别描述变化 → 裁决 LED 极性与颜色↔球号映射，必要时改 `top.v`。
2. 用户对照 `排针映射与IO分配.md` §六核对排针丝印（G15/J15/K16/T7 附近 GND）+ 万用表抽查 2~3 脚 → 通过后删 `.cst` 中 `[待丝印]`，M1 才算完成。
3. W2：~~`uart_tx`~~（已完成）→ `quad_decoder` / `mcp3202_spi` + iverilog TB（`seg_display` 可选）。MCP3202 数据手册在 `docs/img/`。
4. 稳摆硬线 **10-20**，起摆硬线 **10-27**（见发展规划 §五）。
5. 开发流程用 mattpocock skills（`/setup-matt-pocock-skills`、`/grill-with-docs`、`/tdd` 为 `disable-model-invocation`，**必须由用户在输入框触发**，agent 不能代调、也不得手工复刻其流程）。用户尚未触发过。若用户不用 skill，则按 TDD 节奏手写：先 TB 后 RTL。

**环境/权限提示**：自动模式分类器多次拦截 `sed -i`、批量 `rm -rf`、`cmd.exe /c`、`git push`，被拦后应让用户用 `! 命令` 自己执行，不要绕。

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
