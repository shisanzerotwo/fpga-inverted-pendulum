# 2026-10-23 独立只读验证任务卡

## 角色与边界

你是独立验证者，不是实现者。只读当前工作副本和证据；禁止修改任何文件、禁止访问串口/USB/JTAG、禁止烧录，不操作 Git。结果通过消息返回，由编排者落盘，保证只有一个写者。

## 必读

- `docs/tasks/2026-10-23-preflight.md`
- `docs/verification/2026-10-23/source_snapshot.json`
- `fpga_project/src/top.v`、`pendulum_ctrl.v`、`arm_adc_uart.v`、`telemetry.v`、`motor_driver.v`
- `docs/verification/2026-10-23/offline_results.json` 与 `sim_results.json`（稍后生成；缺少时只报告待检查）

## 必须自行执行的验证

1. 使用 Icarus `-g2012 -tnull -s top` 编译当前全部 RTL，核对实际退出码与警告。程序在 `D:/GitHub/xiangmu/FPGA/iverilog/bin/iverilog.exe`。
2. 使用自写只读命令核对源码快照、当前源文件 SHA256、位流 UserCode/SHA256；核对实际控制参数 PULSE_MS=90、ANG_OFFSET=2040、CAPT_SPEED=3000，以及上电复位后的 STOP / duty=0 联锁。
3. 核对现有 tb 日志确有终态 PASS 且没有 FAIL/FATAL/ERROR，不能只采信汇总 JSON；当前期望 14 个 *_tb.v。
4. 核对本轮 Gowin 构建输出位流生成完成，并直接解析最新时序报告确认 Setup/Hold 违规端点、TNS。若仅看到旧报告必须判未知。
5. 对结论边界提出反例：仿真或构建成功不能证明板上加载了该位流，更不能证明 ADC 跟随或持续倒立。旧板 UserCode=0x0A37，旧文件=0x79B2。

## 输出格式

逐项提供通过/不通过/未知、实际命令及关键输出、被检源码/位流哈希。列出阻塞项与可允许的下一步。不要批准实物验收；证据不足明确写未知。
