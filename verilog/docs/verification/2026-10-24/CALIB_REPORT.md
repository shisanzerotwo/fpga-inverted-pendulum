# 新板三姿态标定与 ANG_OFFSET 上板报告（2026-10-24，ZCode 执行）

前置：新板（GD32 同型号更换）FPGA STOP 核验通过（见 `new_board_stop_verified.md`）；用户确认 12V 开启、FPGA 档、STOP、未按 KEY1。

## 安全事件（已解除）

18:21 首采（`calib_hanging_1821.bin`）发现状态机处于 **JUDGE（armed）而非 STOP**——17:55~18:21 间 KEY1 被触发过一次。JUDGE 态下扶杆至捕获窗会自动进 BAL 启动电机。已按 KEY1 切回 STOP 并重采确认后才继续。后续上电采集前必须先核验 STOP。

## 三姿态采集（STOP 态，COM9，各 20s/952 帧）

| 姿态 | 原件 | adc 中位 | 范围 | 跨度 | 安全字段 |
|---|---|---:|---|---:|---|
| 自然下垂 | `calib_hanging_stop_1826.bin` | **0** | 0–0 | 0 | 全帧 STOP/duty0/en0/brake1/key1 |
| 竖直朝上（手扶） | `calib_upright_1831.bin` | **2057** | 2034–2071 | 37 | 同上 |
| 返回下垂 | `calib_hanging_return_1834.bin` | **0** | 0–0 | 0 | 同上 |

三组 952/952/952 帧序号零断裂、非法候选 0。

## 判定（双路验证一致）

- **跟随**：下垂↔竖直中位差 2057 > max(200, 3×37)=200 **PASS**；竖直↔回归下垂同样 PASS。
- **重复性**：下垂↔回归中位差 0 **PASS**（同姿态回归一致）。
- 自算复算：`verify_three_poses_follow.py` → `verify_three_poses.json`（原始聚合，exit 1，聚合语义将同姿态对误套门槛）、`verify_three_poses_v2.json`（修正语义，verdict PASS；两份并存）。
- codex 独立脚本交叉：`verify_adc_follow.py` → `adc_follow.json`（`adc_follow_pass: true`，绝对中位差 2057、最大静态跨度 37、门槛 200）。
- 竖直 2057 落在参考口径预期区间（CENTER_ANGLE=2010、坑 18 预期 2010~2094）；下垂=0 即行程端点，与坑 18 曲线解读一致。

## ANG_OFFSET 更新与位流

- `top.v`：`.ANG_OFFSET(2040)` → **2057**（竖直组中位数；实例化覆盖，`pendulum_ctrl.v` 默认值与 `ctrl_tb` 不受影响）。
- 编译（`gw_build.tcl`，18:31）：综合日志 driver/swept 告警 **0**（坑 26 检查）；pnr 全流程无 warning。时序数值未自动落盘（tr.html 为壳文件）；口径 = 约束未变（50MHz）+ 单 12bit 常量改动 + 上版 TNS=0/Fmax 53.911MHz 独立核验过。
- 新位流 `impl/pnr/fpga_project.fs`：SHA256 `c1d193ffed26190ceb714b1677f517e4d4d93ef32338a489dec0d0fe2c5466e0`，头部 `//UserCode: 0x00004ECE`。

## 烧录与上板核验

- `--run 2`：100% 完成，User Code **0x00004ECE**、Status 0x6020（4.68s）。
- 烧后 10s 遥测（`verify_offset2057_1840.bin`）：476 帧、序号零断裂、全 STOP/duty0/en0/brake1/key1/link1。
- **新参数生效实锤**：下垂 alpha = **-16724**（旧 offset=2040 时为 -16585），精确吻合 (0−2057)×8.129 ≈ −16722（2 counts 系数舍入差）。

## 边界

- GD32 Flash 未逐字节读回，固件烧入为用户报告（DAPLink COM7 未枚举，SWD 建档不可达）。
- 竖直组为手扶（跨度 37）；正式起摆前可选：自由下垂重力精标复核 ANG_OFFSET。
- 时序数值本轮未单独提取（改动不触及时序结构）；如需存档可后补 timing analysis。

## 下一步

起摆实验：STOP 基线已核验、12V 在位。按 KEY1 启动，采 60s 遥测，观察首泵/判势泵/捕获/BAL 全链表现；单变量原则，先跑当前参数基线。
