# 自摆进场平衡验收：与手动上摆同级平稳（无需改码）

日期：2026-10-24 19:28–19:32 ｜ 位流 0x74A8（江协 V1.1 出厂等效五参数）｜ 执行：ZCode，用户按 KEY1

## 结论

**自动启摆进入的 BAL 与手动上摆进入的 BAL 平稳度同级（数值上略优），用户要求"自摆上去后和手摆上去一样平稳静止"达成，零代码改动。** 昨晚观察到的自摆后 ±18° 大摆（`swingup_run1_1850.bin` 尾段）是**旧刚性增益下的外环饱和弛张振荡**，出厂参数组已将其消除。

## 实验设计

- 单变量：直接用当前 0x74A8 位流（出厂等效参数）做自摆首测，不重编译。依据：`pendulum_ctrl.v` 的 BAL 进场清零机制本就齐备（`enc_base <= enc_pos` 位置清零 `fpga_project/src/pendulum_ctrl.v:302-310`、两 PID `bal_clr` 擦除、D 项 `d_seed` ≤30°/s 种子），自摆与手动进场的初始状态一致；差异只可能来自增益本身。
- 旧参数机理复核：旧 KP_POS=40 cdeg/cnt 时位置误差 ~50 counts 即把角目标顶满 ±POS_TRIM（±10°），外环 20Hz bang-bang → alpha ±18°、enc ±50 counts 来回摆（与 `swingup_run1_1850.bin` 尾段逐帧吻合）。出厂等效 KP_POS=4.228 软 9.5×，同误差只产生 ~2° 角目标偏置。

## 过程（`swingup_factory_run1.bin`，240s/11429 帧零断裂）

- 19:27 预检 STOP（duty0/en0/brk1/lk1，`pre_swingup2_stop.bin`）→ 用户按 KEY1。
- 起摆 50.3s→62.2s：**11.9s / 5 泵**，PUMP↔JUDGE 交替后干净捕获进 BAL，无假捕获。
- **BAL 连续 178.0s**（62.2s→240.1s 窗口尽头仍健活）。

## 平稳度对比（同一脚本、同口径：BAL 段剔除前 30s 进场瞬态）

| 指标 | **自摆（本轮）** | 手动上摆基线（jitter_factory_run1） |
|---|---|---|
| alpha std | **191 cdeg（±1.9°）** | 225 cdeg（±2.3°） |
| alpha mean | −99 cdeg | −86 cdeg |
| alpha p95 \|a\| | 399 cdeg | 423 cdeg |
| alpha max \|a\| | 2204 cdeg（孤立马刺） | 2438 cdeg |
| duty \|中位\| | 471 | 538 |
| duty 饱和帧 | 16（0.19%） | 35（0.45%） |
| 看门狗触发帧 | 0 | 0 |
| enc 位置极差（停驻） | **36 counts**（−968~−932，横杆停驻不动） | 557 counts（跨两个 BAL 段，段内各自停驻） |

自摆轮横杆进场后停驻在 −952 附近不再游走——与手动轮"停驻"形态相同，无转圈、无位置弛张。

## 证据

| 文件 | SHA256 |
|---|---|
| `swingup_factory_run1.bin` | `92022db6e0721cb3fb0262f4d4952a5807cabb2f4aaf4d70dcd5b57a104a35dc` |
| `jitter_factory_run1.bin`（基线，同口径复算） | `acbd649de6ca5b11ce5b9883177383cc636ab08cafe5dc078f3d3e3bfd37a42b` |

配套：`swingup_factory_run1.log`（逐帧实时输出）、`swingup_factory_run1.bin.meta.json`、`pre_swingup2_stop.bin(.meta.json)`（实验前 STOP 预检）。

## 边界

- 单轮证据（一次自摆、一次捕获）；平稳度结论与手动基线同置信级别。可重复性可加测。
- BAL 自然寿命仍未测到（本轮 178s 窗口尽头仍活；历史区间 [95.7s, ~4min] 待 600s 长窗口判定）。
- 旧参数 ±18° 机理结论基于数值复核（增益×误差 vs 限幅），未做旧位流复现实验（无必要，单变量已隔离）。
