# 下次从这里继续：2026-10-24 新板角度重标定与起摆验收

## 当前现场与已完成事项（2026-10-24）

- 用户确认：ADC修复已通过；原板更换为相同型号新板。GD32固件和FPGA位流已由用户报告烧入。现场最后一次明确确认是ARM/STOP、未按KEY1、配件板12V关闭、USB保留；测试FPGA控制前先在12V关闭时切到FPGA档。
- FPGA只读设备码：器件ID `0x0000081B`、UserCode `0x0000FD3D`、Status `0x00006020`；当前工程位流UserCode同为`0x0000FD3D`，详见[`new_board_device_codes.log`](../2026-10-24/new_board_device_codes.log)。
- COM9停止态遥测原件[`new_board_stop.bin`](../2026-10-24/new_board_stop.bin)，SHA256 `1cffd0c4f05e4c4080faf4e4f77976df81d3e28330f94bc90f1d62aa3ecfb74f`：381帧/8.120秒，序号连续，381帧全为STOP、duty=0、enable=0、braking=1、link=1、key=1。定稿：[报告](../2026-10-24/new_board_stop_verified.md)、[图](../2026-10-24/new_board_stop_verified.png)。原始分析的SPI周期时间检查不适用于UART，初次报告保留作追溯，复核报告已取代该项。
- 这次采集时配件板12V关闭；ADC范围0–2844、中位数219不代表摆角，不用于跟随判定或标定。GD32 Flash未读回逐字节比对；按用户确认继续，不把这项读回当作当前校准前置条件。
- **当前工作入口：角度重标定。** 保持FPGA档、STOP、不按KEY1；配件板12V上电后继续监视COM9安全标志，依次采集自然下垂、竖直朝上、返回下垂。每组至少100帧；确认每段仍为STOP/duty0/enable0/braking1/link1/key1后，用[既有ADC跟随复核器](verify_adc_follow.py)复算两姿态中位差与组内跨度。通过后将竖直组ADC中位数填入`fpga_project/src/top.v`的`.ANG_OFFSET()`，重新构建/加载并复核FPGA身份与STOP状态，再进入起摆实物验收。任何电机动作立即断开配件板12V。
- 当前`_tools/gravity_calib.py`是CN1 ASCII `Axxxx`/旧COM7流程，不用于本轮FPGA档COM9二进制遥测。COM9只读采集工具为`_tools/tlm_live.py`；每次使用全新输出文件名，工具拒绝覆盖已有原件。

## 旧板最后已确认的现场（仅历史记录）

- 以下都是**旧板退场前**最后一次确认，不代表新换板的状态：配件板12V关闭、USB保留、ARM档、STOP、不按KEY1；之后旧板也未确认恢复12V。
- 旧板上最后核实的是**单次CH8诊断B**，不是生产UART A。新板当前固件未知，不能假设其运行A或B，也不能把旧板Flash哈希/UID当作新板身份。
- B在旧板编程后正常复位Running；旧板断电采集后仍Running。旧板没有启动电机，也没有采到B的上电姿态跟随数据。
- 本机对当前USB设备的只读枚举只看到FTDI双通道及COM9；蓝牙串口COM3/4/5/6与GD32无关。没有识别到DAPLink/CMSIS-DAP或COM7，不能把COM9当作GD32编程口。

## 旧板排查记录（保留追溯，不作为新板状态）

1. 已查版本链：10-16 UART改写漏ADC时钟，17日补回，当前已正确；17日18:21最终原件没有找到。旧SPI与当前SDK/SystemInit相关机器码一致。软件追查作为历史保留，用户确认引脚损坏后不再继续A/B，不重复查接线/电压。
2. A在用户OUT=0.5/2.0V下RDATA中位3800/3829、g_adc3799/3829；986点独立复算通过。不是完全不变；这组原件本身未定位损坏，引脚损坏结论另来自用户后续现场确认。
3. 128KiB原A备份完整保留；容量寄存器已读`0x00200080`，对应Flash128KiB/SRAM32KiB。DBG_ID=`0x21040414`。
4. B仅把规则连续改为逐次清EOC→触发→有界等待→RDATA，GPIO/CH8/239.5周期/时钟/UART/滤波保持。ELF实际机器码12场景+3阴性对照通过；只具STOP诊断资格。
5. 官方CB Pack/HD.FLM首两2KiB扇区编程，**全128KiB逐字节比较记录通过**，fresh reset Running，无回退。实际结果`adc_trial_install.json/log`。
6. 12V关闭B采集`adc_trial_12v_off.json/log`：320点，6.009931秒，g_adc3835–3855/中位3849.5；完成增量430791、超时0、无计数断续。只证明转换在推进，**无激励数据不用于角度跟随判定**。

## 旧板固定身份（仅历史证据，不适用于新板）

| 项 | SHA256 |
|---|---|
| 原A指定128KiB备份gd32_full_flash_128k.bin | `8e4d6b716146250a260a004b9702edec727046e0302d38acb99ae3701717a824` |
| B的首4KiB期望 | `74ab5ec6736f3b2ad3626f4e3f55328de1677bfb7458897a207427defbd999af` |
| B全128KiB（B前4KiB+原A尾部） | `2859b0fd70dd40b9ee2fb7227d87cab4b56b1dd6272421d0da73422b732b0115` |
| B ELF | `b3a09f5d943a873b960ab3ce1aecab1b1db6ac4a6c43989b5be6aa3063e4d951` |
| B HEX | `b11b9afdc5ae4803e2318cf62e2e806a1f17065c7f2e8c34b8e0e9bbb68d3a79` |
| 修后B观察器 | `5b8945b446f15648e654958dcd9cfc29c684fb627b0c9d7731c1b12b028c442d` |
| 修后编程器 | `b585f5103f2b78cf1c95be953d2e4c4b7c78dfd704cc75be27aa715a85d74e76` |

Python：`C:/Users/22421/AppData/Local/Programs/Python/Python314/python.exe`。SWD固定UID`012345ABCDEF`，**100000Hz**。1MHz本轮曾ACK0失败；100k成功，失败记录保留。保持attach、auto_unlock=false、resume_on_disconnect=false、禁缓存/no_config；不得自动解保护。

## 新板下一步最短路径：角度重标定

1. 新板最后确认保持ARM/STOP、不按KEY1、配件板12V关闭。先在12V关闭时切到FPGA档，重新确认STOP遥测仍为duty=0、enable=0、braking=1、link=1、key=1；之后才打开配件板12V，保持STOP并继续只读监视COM9。若电机有任何动作，立即断开12V。
2. 在供电稳定后采自然下垂、竖直朝上、返回下垂各一组，每组建议8秒。当前COM9遥测采集器会保存原始bin和meta，输出名必须唯一，例如`new_board_hanging_12v.bin`、`new_board_upright_12v.bin`、`new_board_hanging_return_12v.bin`；不使用旧板CN1/COM7的ASCII标定脚本。
3. 用`verify_adc_follow.py`对下垂与竖直原件独立复算：每组至少100帧、序号连续、STOP安全字段有效，且两组ADC中位差大于`max(200, 3×最大组内跨度)`。返回下垂组用于检查回差/重复性。该步骤是为新板求角度基线，不重新打开已由用户确认通过的维修排查。
4. 将竖直朝上ADC中位数写入`fpga_project/src/top.v`的`.ANG_OFFSET(...)`，记录原件路径/哈希/统计值，然后重新构建并加载FPGA位流。核对UserCode与STOP/duty0/enable0/braking1后，才进入起摆实物验收；标定前不按KEY1。

### 旧板 B 只读采集命令（归档；不适用于新板，除非先确认其已运行 B；输出必须是新文件）

不要直接运行`read_current_flash.py`：它固定使用COM7，自动尝试RTS/DTR组合（可能复位/改变启动状态），并会覆盖旧文件名`gd32_current_flash.bin`。当前也没有COM7。须先让调试器正确枚举，再准备新文件名且禁用自动复位副作用的限定只读读取方式；旧脚本不适用于当前新板现场。

```powershell
$adcResumeJson = Join-Path (Get-Location).Path 'docs/verification/2026-10-23/adc_trial_resume_check.json'
$adcResumeLog = Join-Path (Get-Location).Path 'docs/verification/2026-10-23/adc_trial_resume_check.log'
if ((Test-Path -LiteralPath $adcResumeJson) -or (Test-Path -LiteralPath $adcResumeLog)) {
    throw '输出已存在：请给JSON和log同时换新文件名，不能覆盖旧证据。'
}
@'
import sys
from pathlib import Path
p = Path('docs/verification/2026-10-23').resolve()
sys.path.insert(0, str(p))
import read_adc_single_trial as m
m.OPTIONS['frequency'] = 100000
sys.argv = [str(p / 'read_adc_single_trial.py'), str(p / 'adc_trial_resume_check.json'), '--seconds', '6']
raise SystemExit(m.main())
'@ | & 'C:\Users\22421\AppData\Local\Programs\Python\Python314\python.exe' - 2>&1 | Tee-Object -FilePath $adcResumeLog
```

上电第一/二组将两个PowerShell路径及Python中的JSON输出名同步改为`adc_trial_hanging.json/.log`、`adc_trial_upright.json/.log`；保留存在检查及`2>&1`，同时保存stdout/stderr，避免漏掉pyOCD警告/异常栈。旧文件不得覆盖；失败保存的部分JSON也保留。上述命令不会恢复12V，只在用户完成对应步骤后调用。

### 旧板回 A 命令（历史归档，不是新板的默认操作）

以下恢复命令针对旧板上已核实的 B→A 状态。新板必须先完成身份/Flash只读建档、重新确认容量和编程范围，并核对生产 A 镜像与新板兼容后，才可制定新的写入命令；不得直接照抄旧板命令。

调用同一冻结`program_adc_trial.py`，导入后设`OPTIONS['frequency']=100000`，参数为`restore --execute --12v-off --arm-stop --start --output <新JSON路径>`。它只写原备份首4KiB并全128KiB比较。失败后的回退使用全新Session/Flash对象，最多一次，失败保持停止；禁止旧`_tools/gd32_isp.py flash`及mass/unprotect。

## 保留的限制与告警

- 本次编程全范围比较仅保存结果/hash，未另存B全范围读回bin；原A完整备份存在，不称有两份B原始bin。
- Pack SVD加载线程报XML声明不在首位，Board ID未知及CoreSight cidr0告警均保留在log；实际FLM写入/全范围比较、后续B身份与计数已通过。未修改官方Pack来消告警。
- 用户已确认ADC修复通过并要求继续；本轮12V关闭的STOP遥测只验证FPGA身份和安全输出，不包含角度标定数据。当前标定待补的新板数据是自然下垂/竖直朝上/返回下垂三组COM9遥测。
- 旧板A/B会话收尾时记录HEAD=`cdedbe9c0cae9706eb4e7d726d26b1b7da948021`及其工作区快照；该计数不是本轮新板状态。开始提交本轮文件前须重新核对HEAD与显式暂存路径，不触碰其他既存改动。

详细证据：[REPORT](REPORT.md)、[INDEPENDENT](INDEPENDENT.md)、[版本链](ADC_REGRESSION.md)、[任务卡](../../tasks/2026-10-24-adc-ab.md)。
