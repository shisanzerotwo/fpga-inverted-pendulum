# 2026-10-23 独立只读验证结论（初始冻结快照）

验证者：`/root/offline_independent`。未编写/修改实现，未写文件，未操作 Git、串口、USB、JTAG 或烧录器；以下报告由编排者按该角色返回内容落盘。

## 被检快照

- `source_snapshot.json` SHA256：`f4dce2c62f21aac0e586d1cee5beb0049295612009297042ba6c53a6089a14cc`；验证者独立计算其中 23 项 SHA256，全部与现文件一致。
- `top.v`：`1818a6e3101de03fd264ea5e67fe0314c194ebe1143883bcb1fdee2bd7adcdae`。
- `pendulum_ctrl.v`：`61c228a4a37f162574c9d299d9af576532ef1d2d61e34a972686fb982d3159a0`。
- 本轮位流 UserCode `0xFD3D`，SHA256：`63cae0ec4fc8b4af6bb5c7f3dc1138d70bd7a411aa96de4b4275b38186eb6173`。
- 旧 UART 位流 UserCode `0x79B2`，SHA256：`11541223bfb04f2bd5b8748f524028efa25d797bb41406bca159ab692facbda9`。

## 独立执行与结果

```powershell
$src = Get-ChildItem -LiteralPath fpga_project/src -Filter '*.v'
& 'D:/GitHub/xiangmu/FPGA/iverilog/bin/iverilog.exe' -g2012 -tnull -s top @($src.FullName)
```

实际：16 个 RTL 文件，退出码 0，无编译输出。源码核查确认 `ANG_OFFSET=2040`、`PULSE_MS=90`、`CAPT_SPEED=3000 cdeg/s`。复位生效后 STOP、run_latch=0；`!run || !link_ok || STOP` 组合输出 duty=0、enable=0；电机前端禁用时短刹、PWM 复位低。电机前端/PWM 是寄存器逻辑，不能把物理 PWMA 宣称为同一组合周期清零；仍需板上 STOP 证据。

14 项现有 testbench：alpha_dot、arm_adc_link、ctrl、enc_decoder、loc_target、motor、pid_pipe、pid、pwm_gen、t_measure、telemetry、uart_link、uart_tx、zone，均有终态 PASS。验证者逐个读原始编译与运行日志，而非仅采信汇总 JSON；pid_pipe 为 4021 次比对、errors=0；uart_link 为 228 帧。扫描判据 `(?im)^PASS:` 与 `(?im)^\s*(?:FAIL\b|FATAL\b|ERROR\b)|\$fatal`，分别以 `FAIL: sentinel`、`PASS: sentinel errors=0` 作正负对照，均正确。

必须并存：首轮 **13/14**，loc_target 在 **90.091 秒超时**；其原二进制使用 `vvp <file> -none` 补验，**exit=0，45.913 秒，终态 PASS**，且输出 `VCD info: dumping is suppressed.`。只能证明关闭波形后通过，不能把首次超时改写为通过或宣称已完全定位超时原因。

补验证据：`loc_target_nodump.log` SHA256 `eed91af8b0e18eedc7c1ed4960799687025e6bc40283fec04591b4b7e15092f4`；`loc_target_retry.json` SHA256 `266319c8ad197f7ab2c948399900726888981eb4270c9d376fc59e3d218afd2b`。

## 本轮构建与时序

原始日志存在：`Compiling module 'pendulum_ctrl(ANG_OFFSET=2040,PUMP_DUTY=6000,PULSE_MS=90,POS_TRIM=1000)'`、`Placement and routing completed`、`Bitstream generation completed`、`BUILD END`。时间 2026-10-23 23:02:20；位流创建 23:02:18。

最新时序：3095 条路径、2876 个端点，Setup/Hold 违规端点均 **0**、TNS 均 **0.000**，sys_clk **50 MHz / 20 ns**，Fmax **53.911 MHz**。

- 时序报告 SHA256：`d7148330b01c559213e05d86a6c404dbef9c8c8420086aefc3a215353f3a6787`。
- 构建日志 SHA256：`b731a6cb0e5db7ba4a806fae1eea9a9e78b5069490061444ce120934df6e5f9c`。

既有警告仍有：ctrl_en 隐式声明、edge_strobe 未接、PID 截断、未使用输入，以及开头无法打开 cache/sh.log 的环境提示。不能称为零警告构建。

## 独立发现的既有缺口（本轮未修改）

`loc_target_gen.v` 的 STEP_HZ=2，DIV=500，但 ramp_div 只有 8 位且比较 DIV[7:0]=244。目标尚未到达、run=1、1 kHz tick 时每 **244 ms** 步进 408 counts，约 **4.098 圈/s**，与 2 圈/s 契约不一致。现有 tb 在 500 tick 后断言 816，同样不符合一圈 500 ms 的契约。测试 PASS 不等于此功能正确。应在位置/速度拓展功能验收前单独修复；本轮禁止扩大范围修改。

## 结论边界

离线结果支持在用户已确认 **12V 关闭、USB 保留** 条件下，按冻结哈希加载 SRAM 并核对 UserCode、首次 STOP 遥测。离线验证者没有批准实物 ADC 跟随、标定或持续倒立；必须另有现场原件。源码/位流变化后，本结论仅保留其历史效力，须追加 delta 复核。

## 追加 R2：当前 Flash 身份与 ADC 红灯重放

同一独立角色再次只读执行，未写文件、未访问设备或 Git。此追加不覆盖上一轮的离线快照结论。结论：**当前 Flash 与正式 UART 加载字节一致；ADC 跟随仍未通过；没有证据确认软件根因。**

验证者独立编写内存中的 HEX 解析器（含长度/校验和正负对照）和 ELF32 取值器，未导入主执行者的比较器：`gd32_current_flash.bin` 与 `_repeat.bin` 各4096字节完全相同，SHA256均为 `ac8d72a7021c2186e41af56eed80b9d181a6ca4943dd206d61b17de33952d1ae`。SP=`0x20008000`，Reset=`0x08000131`。UART HEX和ELF共3300个Flash加载字节diff0；scan的3524个地址diff2730；SPI固件3636字节diff3095，其余诊断候选均不匹配。前4KB覆盖所有候选，但不代表整片Flash相等。10月21日历史dump匹配scan的事实独立复核一致，不能当成当前状态。

ADC独立直接解包15字节原件，未调用项目解析器。已知signed duty=-1234/ADC321阳性对照、非零duty安全断言阴性对照均正确。hanging_fixed/upright_fixed各286帧、序号连续、全部STOP/link1/duty0/enable0/brake1；范围3839..3859与3846..3859、中位3852与3853。delta1/span20，`verify_adc_follow.py`所明示的诊断阈值200，独立结果false与JSON一致。图片经目视核对，横轴为样本序号、两组均在同一噪声带。

真实`ReadOnlyBL`类在无设备MockBL上执行：00/02/11允许，21/31/43/44/73/92拒绝；继承read路径未绕过白名单。RTS/DTR改变启动/复位状态，因此只批准“不写Flash”，不批准“不扰动运行”。

逐项核对本机官方SDK和轮询例程：正式main_uart开启RCU_ADC0，PB0模拟输入，规则组长度1/rank0通道8，239.5周期，软件触发source7+ETERC，CTN连续，RDATA读取。未找到已确认的初始化缺陷。固件没有转换计数/采样年龄/校准超时状态，是观测缺口；seq新鲜不能证明ADC新鲜。持续大阶跃模型6例均在1或16次循环接受；4096×16个ADC/seq表达式组合的装/解帧恒等。模型不能代替外设实测，16次循环也不是16次新转换。

扫描源码另有旧问题（不是当前根因）：头注释8通道而实际10；dwell索引使marker保持1000ms、最后通道200ms；其他外部通道未逐一配置模拟模式；EOIC等待无上界。本轮实际跑UART，不能据此推断当前芯片或接线故障。

独立核实的下一观察地址：ADC0 STAT=0x40012400，CTL0=0x40012404，CTL1=0x40012408，SAMPT1=0x40012410，RSQ0=0x4001242C，RSQ2=0x40012434，RDATA=0x4001244C；ELF `g_seq=0x20000014`、`g_adc=0x20000016`，均2字节。源码期望RSQ2&31=8，RSQ0[23:20]=0，SAMPT1[26:24]=7，CTL1 ADCON/CTN/ETERC=1、ETSRC=7、DAL=0。SWRCST可硬件自清，单次EOC=0不能判停转。

R2冻结哈希：

| 文件 | SHA256 |
|---|---|
| verify_adc_follow.py | `5c7d1005eed8514b10297d0a87b63ce219365262f622f89f4f4548e770576d34` |
| adc_follow.json | `1a9fb4ecd0fff6c700bbd8cbdd6e954f92a7459169dd9cb533711344dac04b0a` |
| adc_follow.png | `0fafce5d6c4c38423d2dfd0bab39e82503ed112522ce7a0888c67c8a3d92d403` |
| read_current_flash.py | `61235f4575a411008e5f359415a205b84840d9490c98a1d77077226f13bc3fc4` |
| gd32_current_flash.json | `eb9e0caffd556164f7ed4bb1dd7b90a3e38abed2a58d2c78477fb1dd298b9378` |
| main_uart.c | `ffdcdb9513cc889a2909d477ed3ccbbfa910c15d87a6fb1206d794f80d8a1ecc` |
| diag_scan.c | `8ae68a528614da035e13c96348b65e15c0cad834d4e316f83413a932ea24b677` |

不得通过修改offset掩盖红灯，不批准启动电机或平衡验收。

## 追加 R3：记录口径与忽略规则 delta

独立角色完整读取REPORT、HANDOVER顶部、R2及两个CN1采集脚本，用difflib自行对比attempt1和当前实现，并独立解析CN1原件。400条有效Axxxx、3842..3855、中位3848、SHA256 `74620e8e29c1f533810f6955e335e387c8f2caad5e5877d75d6d64694512676e`均与元数据一致，尾部`A3844\r`不计有效行。解析器接受A0000/A4095，拒绝A4096/B3848/A38x8。当前采集脚本AST仅port.read/close，不含BL/GO/Flash操作；原始字节含等待首行阶段，elapsed_s仅正式采集阶段，不能写成完整原件精确跨度。

首轮delta发现`.gitignore`忽略整个sim目录，会连compile.log/run.log证据一起排除，旧hash `41e79cc0f905e5b8c2c70bea9cc84f83b10cd5623d89fa12d41834729f010aa6`的忽略规则不通过。收窄到sim/**/*.vcd、sim/**/*.vvp后，独立再次执行7项check-ignore正反例：依赖、VCD、VVP被忽略；run.log、compile.log、ADC JSON、Flash原件不被忽略，**delta通过**，新hash `0c05039630fa227206be93510306ca17e08a88e5dd187e6ad898a0a79a020caa`。两条结论并存，不覆盖原发现。

REPORT hash `27135de24a190fadc3672437428e5d64274d7449e78f0321a1f6f0df967f7427`、HANDOVER hash `325429b0e0d8b76e2c1cba8de2f43535869ee836d0821edff95e496b736429af`、当前CN1脚本hash `1542f3ebc5770b612ce02d1a4eb2d28395948e4293d8b89fa9e6d6b181c3cd01`已核实；均没有把ADC红灯写成项目完成。该独立阶段仅批准“当前Flash身份核实和可复跑ADC红灯证据”，不批准标定/起摆/平衡。

SWD只读日志独立核对：首轮参数错误保留在`swd_attach.log`（SHA256 `57048bf83562e41ceb58e479166d92cf1d9c380f2cb31d26e15cd267db03fadf`）；更正多个-c参数后`swd_attach_read.log`（SHA256 `0d981d0336647d5e87f1b557cd3aa8613e08978176c66dcf0549ae43296fc2e3`）显示Core Running。CTL1=001e0003、SAMPT1=07000000、规则组长度1/通道8、PB0模拟模式、ADC0时钟开启均符合源码/SDK。RDATA=3847、g_adc=3840不同时采，差7不能当滤波故障；单次STAT=0x10无EOC不能判ADC停止。板号/CoreSight警告仍保留。此追加不覆盖后续临时ADC写探针，后者须另行独立审查。
