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
| 1.5 M1 工程骨架 | `fpga/pendulum/`（cst+sdc+顶层），`gw_sh build.tcl` 通过 | ✅ **已完成（2026-10-01，含实物丝印核对）** |
| 2 采集链 bring-up | 编码器/UART/摆角 ADC + 标定三个方向常数 | ⬜ 板卡/套件已到货（**无外购 ADC 芯片**）；摆角改走板载 GD32 ADC（见 §5.1） |
| 3 稳摆 | 复刻双环 PID（基础②③） | ⬜ |
| 4 自动起摆 | 能量起摆 + 捕获（基础①） | ⬜ |
| 5 拓展+超越 | 位置/轨迹 + LQR（拓展①②③ + 抖动 ≤±3°） | ⬜ |
| 6 演示与文档 | 视频 / 报告 / RTL 佐证 | ⬜ |

**截止日 2026-11-10**（2026-10-01 起剩 40 天）；倒排表已压缩，见发展规划 §五：稳摆硬线 10-20、起摆硬线 10-27，LQR 等 stretch 已砍。

### 5.1 进度快照（2026-10-01）

**最新快照（20:50，会话暂停）**
- 最新提交 `01bf92f`（adc_bridge 加 framing_err + 切片 6b）；本轮共 9 个提交（44ef2da → 01bf92f）。
- **M1 已闭环**（20:48 重建通过，详见下）。
- RTL：采集链 `uart_tx` / `quad_decoder` / `adc_bridge` 完成（3/4，`seg_display` 未做）；控制律 `pwm_gen` / `pid` / `balance_ctrl` 完成（`energy_swing` 起摆未做）。
- pi 侧独立验证（均已复现）：上述模块 TB 全 PASS；`pid` 逐位对拍向量经独立验算 9/9；adc_bridge 变异 A/B 均被新切片 6b 抓到；`f43f4b9` 曾是红 TB（已报 Claude，`9a77868` 修复后复现红转绿 + 阴性对照确认）。
- **未接入 `top.v`**：`pid` / `pwm_gen` / `balance_ctrl`（原先等 M1 丝印，现已解锁）。
- 未提交（pi 侧本轮产物）：`AGENTS.md` 纪律与事实修正、`.gitattributes`、`tools/progress-check.py`、3 份文档（丝印核对清单 / 规划修订 / 排针映射修正）、`.cst` 去 `[待丝印]`。
- 硬件：板子 USB 在线，`COM7`（ARM 通道身份）；上板验证 FPGA 侧需**按键切到 `COM9`**。
- **待办**：① `top.v` 整链集成（现可做）② **GD32 固件**（ADC 采样 + 原码转发，1 Mbaud 4 字节帧，`A5|{0,code[11:8]}|code[7:0]|A5^hi^lo`）③ `seg_display` / `energy_swing` ④ 上板验证 ⑤ **合规口径待组委确认**（感知物理层在 MCU）。

**已完成并已核实（早前记录）**
- 提交已推送 GitHub（`shisanzerotwo/fpga-inverted-pendulum`，master 到 `01b1f88`）。
- M1 软件侧：13 个拟用扩展脚均在原理图 66 个 `EX_` 网络内、与板内占用无交集（脚本核对）；`pendulum.pin.html` 抽查 19 个信号落位正确；逻辑占用 <1%。官方 `.cst`/分配表只含板载功能，**扩展脚无官方第二来源**，第二来源 = 实物丝印。
- **下载链路打通**：板上 GD32 在 Windows 里是 `DAPLink CMSIS-DAP` + `COM7`，但对 Gowin Programmer 表现为 **`Gowin USB Cable (FT2CH)`**，器件识别 `GW2A-18C (0x0000081B)`。`openFPGALoader` 与 `programmer_cli --scan-cables` 在本机都**扫不到/打不开**，别再走这条路。SRAM 下载断电即失效。
- **命令行下载可用**（2026-10-01 实测，**指定 cable 即可，不要 `--scan-cables`**）：
  ```bash
  P="/e/FBGA/Gowin/Gowin_V1.9.10.02_x64/Programmer/bin/programmer_cli.exe"
  # 注意：--run 0（读器件码）不是可靠探针——拔线状态下实测仍 exit 0 并打印 GW2A-18C(0x0000081B)
  # 判断板子在线：Get-PnpDevice -PresentOnly 能看到 VID_0D28 或 VID_0403；判断下载成功：见下方成功标志
  "$P" --device GW2A-18C --cable "Gowin USB Cable(FT2CH)" --run 2 \
       --fsFile "D:\\GitHub\\xiangmu\\fpga-inverted-pendulum\\inverted-pendulum\\fpga\\pendulum\\pendulum\\impl\\pnr\\pendulum.fs"   # SRAM 下载，约 5s
  ```
  成功标志：`Status Code is: 0x00006020` + `Finished.`（exit 0）；拔线时 `--run 2` 返回 exit 50 且无 `Finished`。图形界面仍可用作兜底。
- **FPGA 串口（`uart_tx`=F12）读 COM9，不是 COM7**（2026-10-01 实测，只插逻辑派一根 Type-C、无其它下载器）：
  - COM9 = `FTDIBUS\VID_0403+PID_6010`（USB Serial Port）：收到 FPGA 每 0.671s 一个递增字节（与 2²⁵/50MHz 一致），重新下载后从 `01` 重新计数。
  - COM7 = `USB\VID_0D28&PID_0204&MI_01`（DAPLink CDC）：收到的是 **GD32 固件自己**周期发的 GBK 文本（"欢迎使用立创·逻辑派FPGA-G1开发板…GD32 内部温度：xx°C"），不是 FPGA 输出。
  - 两个 USB 身份同一时刻只有一个在线；`programmer_cli` 下载后切到 VID_0403/COM9。读串口用 `tools/read_com.ps1 COM9 115200 6`。
- 下载前要排障的事实：Type-C 线直连电脑 USB 口最稳；曾因线/转接器/口导致 `Device Descriptor Request Failed`（代码 43），换口后正常。
- 已烧过一版自检程序，板上 LED 有多色闪烁（程序确实在跑，时钟与配置正常）。

**M1 已闭环（2026-10-01 20:48，pi 侧执行）**
- `.cst` 中 `[待丝印]` 已全部清除（0 残留）；实物丝印由**用户确认通过**（证据形式：口头确认，未逐脚记录实读值）。
- 重建 `gw_sh build.tcl` 一次通过（Routing → Timing → Bitstream → Power 全跑完）；Logic **270/20736**（235 LUT + 35 ALU）、Register 186/16173、BSRAM 0%；时序约束 50 MHz / **实际 Fmax 210.716 MHz**。
- `pendulum.pin.html` 含 `adc_rx`/`pwma`/`ain1`/`ain2`/`enc_a`/`enc_b` 全部落位；顶层 12 端口 ↔ 21 条约束，无漏约束/无重复占用/无未用约束。

**摆角采集路径定案（2026-10-01，用户要求「只用这块开发板」）**
- **FPGA 侧没有 ADC**：高云 ADC 手册 UG299E 的支持器件表只含 Arora 系列（GW5A/5AR/5AS/5AT、GW3A）；GW2A 数据手册（DS102）功能列表无 ADC；`GW2A-LV18PG256C8/I7` 不在支持列表内。
- **排针上的 ARM 6 脚**（原理图 `2.esch` 网络名）：`EX_PA11 / EX_PA12 / EX_PB0 / EX_PB9 / EX_PB10 / EX_PB11`。其中 **`EX_PB0` = GD32 的 `ADC01_IN8`**（GD32F303 数据手册 Rev1.9，PB0 = 引脚 46），且官方引脚分配表 ARM 段**未占用 PB0**（PB1 才是 LCD 背光）。
- **`PA0~PA7` 是 FPGA↔GD32 板内直连**（不引排针）：官方引脚表 `PA0~PA3`=USART1（球号 `J12/J11/K11/D14`）、`PA4~PA7`=SPI0（球号 `E15/L12/L13/L16`）。
- **官方 wiki 独立印证**（`https://wiki.lckfb.com/zh-hans/fpga-ljpi/communication/io.html` 「I/O 交互」页的 I/O 约束表：`PA0→J12`、`PA1→J11`、`PA2→K11`；官方示例注释 `// 将输入 C 连接到FPGA的k11引脚`）→ `K11 = PA2` 已达**三源**（官方引脚表 + wiki 官方表 + 原理图 `2.esch`），且方向确认（ARM 输出 → FPGA 输入）。
- **定案链路**：摆角电位器 → 排针 `EX_PB0` → GD32 ADC 采样 → `PA0~PA7` 直连 → FPGA。**GD32 只做「采样 + 原码转发」，不得滤波/换算/判断；滤波、角度换算、双环 PID、能量起摆、PWM 全在 FPGA 内。**
- **取代关系**：原计划的 `mcp3202_spi.v` → 改为 `adc_bridge.v`（从 GD32 收 12bit 码值，含帧同步/校验/超时）；`.cst` 移除 SPI ADC 四脚（`J16/J14/H15/F14`）、启用 PA 组四脚；`seg_display` 由可选转正式项。
- **新增工作项**：GD32 固件（ADC 采样 + 原码转发，Keil 工程，下载走 6P/`COM7`）。
- 完整证据链与合规论证见 `docs/2026嵌赛选题一/规划修订-基于逻辑派FPGA-G1实测资源.md`。
- ⚠️ **合规风险（中高）**：本方案把「感知」的物理层放在 MCU 上；项目文档中「MCU 纯采集转发不违规」的口径**来源未注明**，标为待核实 → 应对：报告主动声明 + 附 GD32 源码佐证算法全在 FPGA。

**未验证（不要当事实用）**
- LED 极性（共阳/低电平点亮）与 6 通道 ↔ 球号（R9/C10/R7/N6/T10/P7）对应关系：**未核实**。`top.v` 当前自检版按"低电平点亮"写，是假设。
- 数码管引脚映射：官方 cst 有 `seg[0..7]`=G13/H16/H12/H13/H14/G12/G11/L14，但未对原理图核对，未点亮过。
- 编码器 A/B、ADC、PWM 等 `.cst` 中 `[待丝印]` 的 13 个扩展脚：**未做实物丝印核对**，也未接外设。

- **`uart_tx` 已上板验证**（2026-10-01）：`src/uart_tx.v`（115200 8N1，valid/ready 握手，复位期间 `ready`=0）；`tb/uart_tx_tb.v` 6 个切片 + `tb/top_tb.v` 冒烟，iverilog 全 PASS，各切片均做过变异阴性对照；`top.v` 每次心跳上升沿发一个递增字节。综合：Logic 97/20736，Fmax 253MHz（约束 50MHz）。

**未跟踪（未审查，勿提交）**：`.mcp.json`、`tools/gowin-mcp/`、`docs/img/MCP3202_p*.png`（**该组截图已随方案变更作废**）、`tools/progress-check.py`（pi 侧只读进度检测脚本）、`docs/2026嵌赛选题一/规划修订-基于逻辑派FPGA-G1实测资源.md`。`D:\Gowin` 副本**仍在**（用户决定不删；注册表卸载项仍指向它）。

**下一步（按顺序）**
1. 用户重烧最新 `pendulum.fs`：不按键描述各色灯状态；按住 D11、F10 分别描述变化 → 裁决 LED 极性与颜色↔球号映射，必要时改 `top.v`。
2. 用户对照 `排针映射与IO分配.md` §六核对排针丝印（G15/J15/K16/T7 附近 GND）+ 万用表抽查 2~3 脚 → 通过后删 `.cst` 中 `[待丝印]`，M1 才算完成。
3. W2：~~`uart_tx`~~ / ~~`quad_decoder`~~（均已完成，含上板）→ `adc_bridge`（从 GD32 收 12bit 码值）+ **GD32 固件（ADC 采样 + 原码转发）** + iverilog TB；`seg_display` 转正式项。**`mcp3202_spi` 已取消**（无外购 ADC 芯片）。
4. 稳摆硬线 **10-20**，起摆硬线 **10-27**（见发展规划 §五）。
5. 开发流程用 mattpocock skills（`/setup-matt-pocock-skills`、`/grill-with-docs`、`/tdd` 为 `disable-model-invocation`，**必须由用户在输入框触发**，agent 不能代调、也不得手工复刻其流程）。用户尚未触发过。若用户不用 skill，则按 TDD 节奏手写：先 TB 后 RTL。

**环境/权限提示**：自动模式分类器多次拦截 `sed -i`、批量 `rm -rf`、`cmd.exe /c`、`git push`，被拦后应让用户用 `! 命令` 自己执行，不要绕。

## 六、工作纪律（本项目硬约束）

1. **引脚结论必须"原理图 + 实物丝印"双证**，之后才能写进 `.cst`。单源采信已踩过坑（PDF 标签错位）。
2. **方向常数单点定义**：`ANGLE_SIGN`（传感器）/ `MOTOR_SIGN`（电机）/ `ENC_SIGN`（编码器）只在"安装坐标↔物理坐标"边界模块定义一次；能量起摆在物理坐标直接算力矩，**不经过方向映射**（重复应用会把泵能变耗能，已复现）。
3. **泵能方向必须实验裁决**，公式坐标约定不可盲抄；bring-up 时开环 bang-bang 实测。
4. **模型不能批准自己的完成**：RTL 的正确性由"Python 已验证向量 → TB 逐拍对拍"判定，不接受"整体差不多"。
   - **整数域模块**（照搬码值域参考实现者）必须与**精确有理数期望（Fraction）逐位一致**，**零容差**。实测教训（2026-10-01，`pid.v`）：只有"逐位一致"断言才抓到 5 拍边界差异；原先写的「±2 LSB」容差会让它逃逸。
   - 与**浮点参考实现**对比时，偶发 ±1（截断边界）可接受，但须定位到具体拍并说明原因（例：向零截断 vs floor / 算术右移）。
   - **期望值必须来自独立实现**（如 `sim/export_vectors.py` 用 Fraction 精确计算，不复刻 RTL 的整数缩放写法），不得拿 RTL 自身的中间量当期望值。
5. **整数域实现**：控制律照搬参考答案的码值域运算（非"浮点算法再定点化"），并加**积分限幅**（阶段 0 已实测积分失控）。
6. **改动前先跑基线**：改 `sim/` 后重跑 `run_sim.py`，用 `git diff` 比对 `sim_out/*.png` 判断影响面（不依赖位置的场景应逐字节不变）。
7. **提交纪律**：不留无意义空提交；推送前扫敏感信息（公开资料链接不落密码）。
8. **变异测试纪律**：变异文件必须**基于当前版本**生成；用过期变异文件得出的结论无效（实测教训 2026-10-01）。
9. **多 agent 同文件并发写会丢改动**（实测 2026-10-01）：`AGENTS.md` 曾发生 pi 的修改被另一 agent 的写回覆盖。规范：同一文件同一时间只允许一个 agent 写；pi 改 `AGENTS.md` 前先确认 Claude 处于 `idle`，改完后立即 `grep` 回查关键字段确认写入生效。

## 七、已知坑与教训

- **TB 写法三坑**（2026-10-01，`balance_ctrl` 一轮内连踩）：① TB 的时钟周期必须与 RTL 参数 `CLK_HZ` 对齐，否则仿真时长按比例错（实测差 25 倍，一度被误判成 RTL bug）；② 等**单拍脉冲**（如 `ang_tick`）**不能用 `while` 轮询**——会漏掉，应当用 `always` 块计数；③ 看门狗时限必须**长于**预期仿真时长，否则报假超时。
- `test_env` 工程的 `led[4]=T10`、`led[1]=C10` 是 **SSPI 专用脚**，工程必须 `set_option -use_sspi_as_gpio 1`，否则引脚不可用。
- `build.tcl` / `.gprj` 里的路径**必须相对脚本/工程解析**（`[file dirname [info script]]`、`../src/...`），写绝对路径一搬家就废（已修，2026-10-01）。
- 场景 3 位置阶跃的**位置环**依赖 `controller.py` 的 `location` 累加；该处曾有重复累加抵消 bug（已修，见 git 历史）——若位置曲线恒为 0，先查这里。
- 竞赛要求数字须带口径：写文档用"快照 + 取值命令"，不写裸数字。
- 装配与上电：PH2.0-6P 接口两份文档引脚序号矛盾（公/母镜像），**以控制板丝印为准**，先万用表核位再插电机；法兰联轴器切面朝上、顶丝对准轴切面。

## 八、关联知识库

- [[嵌入式竞赛 FPGA 倒立摆实战]]（`D:\ObsidianChanku\ai学习\research\FPGA学习\`）——外部记忆，随本项目更新。
- [[本地项目索引]]——项目登记行。
