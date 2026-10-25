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

## 追加 R4：易失ADC对照与上电三姿态

独立首审曾阻塞`adc_runtime_control.py`旧版（SHA前缀e9042e）：恢复链中首个读写异常会跳过后续恢复，不能执行。此历史阻塞不覆盖，也不删除。新版`1b81379ffa520aa7f1e503f21f5d7f6b8ce2da6c89a38a4713d5b4564a1b1d06`改为最多3轮恢复，并分别尽力检查Flash后哈希和末态；独立角色实际执行8种内存故障注入，正常通过、7个异常/冻结场景均拒绝通过，永久恢复失败严格3轮停止，delta通过后才执行真实片内对照。

两个独立角色实际复算片内对照180点：CH8前/参考17/CH8后三阶段各60点，RDATA中位3829/1494/3828，g_adc中位3830/1494/3828.5；12位整数与严格递增时间均正确。三个保存/恢复寄存器逐值一致，记录无恢复/末态错误，Core末态Running。两份既有4096字节Flash原件均重算为ac8d72a…d1ae，与运行态前后记录一致；运行态前后没有另存新Flash原件，结论仅限前4KiB及所记录哈希。

`offline_independent`随后独立读取直接采集器和三姿态原件，不访问COM/SWD、不运行采集器、不写文件或Git。下垂492/朝上505/返回下垂491，共1488点，时长6.001646/6.008801/6.005255秒；RDATA中位3827/3828/3829，g_adc同值，范围与REPORT表格一致。三组时间有限、非负、严格递增并位于各次时长内；摘要全部正确，六配置快照/连接选项/采前Flash哈希一致。RDATA已被采集代码取低12位。

采集器显式操作仅read/get_state，无应用寄存器写、reset/halt/resume或Flash编程；attach自身仍有调试控制写。resolve位于连接前，独立路径对照与首轮FileNotFoundError一致。try内失败保存部分JSON并传播异常；参数或探针创建失败发生在try前可能无JSON，JSON不记异常原因，日志必须保留。运行状态只查起止、配置仅采前、Flash仅采前，不能据此声称全程不变。

本阶段只批准“ADC/滤波能响应受控通道变化，外部三姿态未辨识出响应”；不定位硬件故障，不批准标定/起摆。Frozen SHA256：

| 文件 | SHA256 |
|---|---|
| adc_runtime_control.json | `60794ed0d88b13d4efebcecc0310dd9d281d0f289ebeeecf08e1bab9f1c1f17b` |
| adc_runtime_control.log | `f0bb8a461bce20b1ccdd196ed5fdd024f5e8ec1d1a7e03c0a424166fe3b66be7` |
| read_adc_runtime.py | `7ef67b8c4362309691ccbccde36fb59dbc33b75e7fd85eecb3e9e742b4afa0f4` |
| runtime_hanging.json | `67cfc2015b57135e6708d6d44bc85b4c2ae91ecd58dae5161e6d9a2af0e3164a` |
| runtime_upright.json | `0fc1959792909d14e906396bc735bf4b0a14a1807a5ed426c016d704975efb8c` |
| runtime_hanging_return.json | `9f5ffc80fd48ef7809424b99372ab37a45f092aa0ef3d0871e1e282c72f826ce` |

另独立逐一读取c85c5f2的87路径原始blob：verification的81文件（含9bin/45log）均逐字节同磁盘，只有HANDOVER的LF/CRLF不同、归一化相同；无VCD/VVP/pyocd_lib误收。此项仅审既有提交，不替代本阶段新文件的复核。

## 追加R5（2026-10-24）：OUT定压配对与指定范围备份

offline_independent在临时副本实际执行回放，逐点核986点，JSON/日志解析/PNG均与保存产物一致，PNG逐字节同。0.5V组512点/6.012092s，RDATA3794–3807/中位3800、g_adc3793–3807/中位3799；2.0V组474点/6.009094s，二者3823–3837/中位3829。时间有限、非负、严格递增且在时长内，值均为12位整数；配置与采前哈希一致、末态Running。人工OUT测量不是PB0节点观测；存在29/30计数偏移，不能叫完全不变或认定硬件损坏。2.0V实报，2.5V仅请求；J1-2非J1-1。

两组原件SHA分别`8d8a5901d074f98c247db39c2c58326375e627cb42fa9ad3f64c224770f3ec16`、`e859fe761c1fba4423762505658f425e748774db81ff6ca1fb056c7ecba2f3df`。验证器`4b11057dfc8bca09892b25a2d297e7802c8e39aedf7c907ffbcc6fd0c23aed1d`；JSON`d8439e714afc856cc55f1ab8325174e19c0d776572ecb6bbdda20991b182a01e`；PNG`c4df5eaba643d47c9afc8a3c77a97bded70045d34ababb2274c011d4ecfff6cd`。

两名独立角色核131072B备份SHA`8e4d6b716146250a260a004b9702edec727046e0302d38acb99ae3701717a824`，前4096B与本轮原件一致，前16384B与docs下10-21 UART原件一致，4096之后全FF。两读相同仅有哈希记录，保存第一遍原件，不能说独立比较了两份完整bin。起止Running不证明全程连续运行；脚本无halt/reset/resume或应用寄存器/Flash写，attach仍有必要调试控制。尚未读取容量寄存器，结论仅指定128KiB范围。

备份脚本SHA`96b0b51c7a092ea838b5330955b66581f483677a84fb44e2d938d89041406be7`；JSON`c72480db2a109cdda68a7b22d5f55a9a976ad85b2c3fccc6ce4e0348c4394087`；log`c45086fef938f549d37b5525a2ab4e285a17c1e08aa6d97a15e71ec2f0390fb6`。本阶段批准证据完整性/离线复算，不批准外部跟随或标定/起摆。

## 追加R6：候选B、编程边界与观察器旧快照阻塞

isp_documentation独立执行实际B ELF纯内存12项正常/延迟/边界/超时/旧EOC/滤波反例；另分别删除清EOC、触发、完成计数三个内存桩，均被阴性断言拒绝。初始化38→37调用，仅连续ENABLE→DISABLE与删除首次触发；其他GPIO/ADC/UART实参相同。HEX/ELF3408加载字节一致。源SHA`06314fc3f9c5bbd739297faba18c08953ed2e5a5f96720da5b2ea64e1513ed9a`，ELF`b3a09f5d943a873b960ab3ce1aecab1b1db6ac4a6c43989b5be6aa3063e4d951`，HEX`b11b9afdc5ae4803e2318cf62e2e806a1f17065c7f2e8c34b8e0e9bbb68d3a79`，清单`19185da9f47e10dc160316ce0c6b320107130e41eb27eb34fc9aae4bc9067e59`。仅批准STOP候选。超时会清滤波hold、首次超时0非有效转换、轮询次数非耗时保证，三项边界均保留。

官方Pack/FLM由adc_history离线实际解析：CB边界128KiB/RAM32KiB，sector0x800/page0x400；Pack SHA`4c9f8562bd7832941460386a93b57185476d3d2a773188c0308e00f2d7104de1`，HD.FLM`c8d2f112c594eda8c85d07c605eb1c7f56dd0e765d4bcffd9dbac0497422a18c`。FlashLoader只是MemoryLoader别名，sector显式走页擦；commit不自校验、不恢复原应用RAM/PC，必须全范围比对后fresh reset，不能直接resume旧现场。容量寄存器地址/编码来自手册PDF41页，尚未实读。旧ISP实际fake-serial及官方AN027对照证实写framing错误，历史也未成功，不批准其flash路径。

**观察器旧快照不通过，保留阻塞**：SHA`db72b4bf8066bccc8f363e1ed4c408908e4e2cdb08922830b5208e240da40b91`独立31场景29符合、2反例误判。completed1000→0被首尾模减当4294966296完成；timeout0→1→0被抵消，同样误判窗口可用。该快照不得用于上板判定。修后改逐步展开计数、拒绝倒退/重置并累计所有超时，新SHA`5b8945b446f15648e654958dcd9cfc29c684fb627b0c9d7731c1b12b028c442d`待独立delta；旧阻塞不覆盖。

### R6后续delta：修后观察器通过（不覆盖上述旧快照阻塞）

offline_independent独立重建旧完整文件并核旧SHA，实际看新旧diff，确认仅计数聚合/断续记录/门槛改变。新SHA`5b8945b446f15648e654958dcd9cfc29c684fb627b0c9d7731c1b12b028c442d`实际执行39个纯内存/临时目录场景均符合预期：两旧反例均usable=false、mock main返回1；completed1000→0记录断续，timeout0→1→0不再抵消。合法完成计数回绕总增239可用、超时回绕增1不可用；2^31边界、15/16次完成、99/100点、历史非零超时无新增、错误镜像/配置/运行态、异常保存和不覆盖输出均正确。严格mock无STAT/RDATA/IDATA读，没有接设备或改项目。

本次只批准冻结观察器的离线逻辑。断续后的模差大数不能解释成真实完成次数；离散计数及起止Running不证明全程未重启或捕获所有重启。镜像4096B SHA仍`74ab5ec6736f3b2ad3626f4e3f55328de1677bfb7458897a207427defbd999af`，RAM符号与B独立ELF一致；不批准姿态跟随或项目完成。

## 追加R7：编程器旧快照阻塞，修后待限定放行

旧编程器SHA`d54f7a983e93a4fdb6e5bec890be826a668184b671d4187de4b387c27756c471`被isp_documentation独立真实API内存测试阻塞：Target.ResetType没有SW_SYSRESETREQ，正确名称是SYSRESETREQ；此外失败后原Session/Flash对象可残留_did_prepare_target/_active_operation，单纯reset后再Loader不保证重新Init。独立真实Flash.init反例显示erase第二扇区失败后原对象prepared=true/active=ERASE，reset+新Loader的additional_Init_calls=0。这两项旧阻塞保留，不得用于设备写入。

新SHA`b585f5103f2b78cf1c95be953d2e4c4b7c78dfd704cc75be27aa715a85d74e76`改用真实枚举，失败后先退出旧Session、全新Session/target/Flash对象回退一次，恢复不递归。原A已完整只halt核实、不重复写。全范围核验后才fresh reset启动；Session退出异常也纳入失败路径。主代理纯离线plan()实际得到B全范围SHA`2859b0fd70dd40b9ee2fb7227d87cab4b56b1dd6272421d0da73422b732b0115`。

主代理现场预检1MHz在DP power-up阶段ACK0失败，未擦写；100kHz attach成功，capacity_word=0x00200080（Flash128KiB/SRAM32KiB），DBG_ID=0x21040414，全范围哈希仍原A，起止Running。两次日志并存，降速成功不抹去首轮失败。后续调用显式在导入后设置OPTIONS频率100000，运行JSON记录真实配置，不改冻结脚本逻辑。新编程器须收到独立限定通过后才执行。

### R7后续delta：修后编程器限定通过（不覆盖旧阻塞）

isp_documentation独立执行真实bundled `MemoryLoader + FlashBuilder + Flash`，只模拟底层内存与会话；冻结SHA256为`b585f5103f2b78cf1c95be953d2e4c4b7c78dfd704cc75be27aa715a85d74e76`。27场景全部符合预期，另两条内存消融反例（删除容量闸门、删除全范围比较）均被拒绝。主/回退会话均实测接收内存覆盖的100000Hz，结果options记录该频率。

成功B仅擦首两个2KiB扇区、编程四个1KiB页，全128KiB比较通过后才fresh reset启动。错误容量、映射、几何、前镜像和原始尾部均在编程前拒绝；擦写/读回异常先退出原会话，再用独立Target/Flash的新会话恢复A。覆盖退出异常、启动失败及A已完整时只halt不重复擦写；尾部损坏不被前4KiB回退掩盖，回退失败不递归且终态HALTED。未触发mass erase或尾部写入。

本结论只放行该冻结编程器在12V关闭、ARM/STOP及100kHz下的限定试验，不批准ADC恢复。旧SHA`d54f7a98…`的枚举与stale Flash阻塞仍有效于其旧快照。

## 追加R8：B实际安装记录与12V关闭采集独立核算

offline_independent未访问设备、未修改文件或Git；自行从实际B ELF构造4096B前缀，并拼接原A备份后126976B，重算全128KiB SHA256为`2859b0fd70dd40b9ee2fb7227d87cab4b56b1dd6272421d0da73422b732b0115`，与实际安装记录一致。源码限定首4KiB编程并逐字节比较全范围，记录为校验后HALTED、`SYSRESETREQ → halt → resume`后Running，无回退。未另存完整B读回bin，不能称已独立比较两份完整原始B镜像。

后续320点独立逐点复算：时长6.0099308秒，g_adc3835–3855、中位3849.5，completed增430791，timeout增0，无计数断续。时间全部有限、非负、严格递增且不超过时长，字段类型/范围合法。负时间、无穷时间、ADC4096、序号16的阴性对照均拒绝；计数清零可检出，合法回绕阳性对照正确。采前/采后首4KiB均匹配B，静态配置相同且符合单次CH8/PB0，起止Running，频率100kHz。离散快照不证明全程未重启。

最新用户明确确认仍是12V关闭；请求恢复供电后收到“明天继续，写状态和交接”，**未收到恢复12V确认**。该无激励采样只证明转换推进，不具外部角度跟随判别力，不批准标定、起摆或问题修复。SVD线程XML异常、BoardID/CoreSight告警保留；1MHz失败与100kHz成功记录并存。

| 冻结原件 | SHA256 |
|---|---|
| adc_trial_install.json | `03920f19b7becd3ac38a2658ef246a9b9e715bd40487fdf171ed9efe8773cdc0` |
| adc_trial_install.log | `4f7ce1203c744673058ff45eff612aa14c1470686a7986aa707aca37421a88aa` |
| adc_trial_12v_off.json | `c92b2a42f739f533c88e2d87d37ad1974efff25a503aebde21288163c0f71226` |
| adc_trial_12v_off.log | `7620b93a5d3594f06064c3cdc769fc656507e574da42d992cdcc58614d8c3675` |
