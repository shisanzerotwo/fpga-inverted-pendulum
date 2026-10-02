# -*- coding: utf-8 -*-
"""导出 balance_ctrl 整链对拍向量（RTL TB 用 $fscanf 读入）。只读调用阶段 0 模块，不改它们。

做法：
  1) 用阶段 0 已验证的闭环稳摆轨迹（同 export_vectors.py）取得每个 1kHz 拍的 adc 码值与位置计数；
  2) 期望值用 Fraction 精确有理数复刻"双环级联 + 顺序"：
       每 5 拍：角度环 PID（30/1/40 ÷ 1000，输入 ×10）→ 输出即 PWM 整数（±100 限幅、向零截断）
       每 50 拍：位置环 PID（4/0/40 ÷ 1）算完后改写角度环目标 tgt = CENTER_X10 − loc_out
       同拍时先角度环、后位置环（与江协 TIM1 中断顺序一致）
  3) 每个角度环拍输出一行：adc_code loc tgt_x10 expected_u
       tgt_x10 = 该拍角度环使用的目标（位置环在之前的拍改写）
       出窗（|tgt − adc×10| >= WIN_X10）时 expected_u = 0（安全态），PID 仍更新（与 RTL 一致）

输出：fpga/pendulum/tb/vectors/bal_vec.txt
运行：cd inverted-pendulum/sim && py export_balance_vectors.py
"""
import os
import sys
from fractions import Fraction as F

import numpy as np

from model import Params
from controller import JXPendulumController
from run_sim import simulate_jx

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "fpga", "pendulum", "tb", "vectors")

CENTER_X10 = 20100
WIN_X10    = 5000
INT_LIM    = 100000
N_TICKS    = 2000          # 2 秒 @ 1kHz


class ExactPID:
    """精确有理数版位置式 PID，语义与 RTL pid 模块一致（含积分饱和与输出限幅）。"""

    def __init__(self, kp, ki, kd, div, out_max):
        self.kp, self.ki, self.kd = F(kp), F(ki), F(kd)
        self.div, self.out_max = F(div), F(out_max)
        self.e0 = self.e1 = self.ei = F(0)

    def update(self, target, actual):
        e0 = F(target) - F(actual)
        de = e0 - self.e0
        ei = self.ei + e0 if self.ki != 0 else F(0)
        if ei > INT_LIM:
            ei = F(INT_LIM)
        elif ei < -INT_LIM:
            ei = F(-INT_LIM)
        self.e1, self.e0, self.ei = self.e0, e0, ei
        s = self.kp * e0 + self.ki * ei + self.kd * de
        lim = self.out_max * self.div
        if s >= lim:
            return int(self.out_max)
        if s <= -lim:
            return -int(self.out_max)
        # 向零截断：对绝对值做整除再补符号（Fraction 的 int() 即向零截断）
        return int(s / self.div)


def main():
    p = Params()
    log = simulate_jx(p, t_end=N_TICKS / 1000.0, alpha0=np.deg2rad(5.0), start_state=1)
    n = min(len(log["t"]), N_TICKS)
    adc = [int(round(JXPendulumController.adc_of(a))) for a in log["alpha"]]
    loc = [int(round(v)) for v in log["loc"]]

    ang = ExactPID(30, 1, 40, 1000, 100)
    lop = ExactPID(4, 0, 40, 1, 1000)
    tgt = F(CENTER_X10)

    rows = []
    n_safe = 0
    u_lo, u_hi = 999, -999
    for k in range(1, n + 1):
        i = k - 1
        if k % 5 == 0:                               # 角度环拍（先）
            tgt_now = tgt
            out = ang.update(tgt_now, adc[i] * 10)   # 与 RTL 一致：PID 持续运行，安全态只清输出
            err = tgt_now - adc[i] * 10
            safe = (err >= WIN_X10) or (err <= -WIN_X10)
            u = 0 if safe else out
            if safe:
                n_safe += 1
            else:
                u_lo, u_hi = min(u_lo, u), max(u_hi, u)
            assert tgt_now.denominator == 1
            rows.append((adc[i], loc[i], int(tgt_now), u))
        if k % 50 == 0:                              # 位置环拍（后），改写角度环目标
            lo10 = int(lop.update(0, loc[i]))
            tgt = F(CENTER_X10) - lo10

    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, "bal_vec.txt")
    with open(path, "w", newline="\n") as f:
        for r in rows:
            f.write("%d %d %d %d\n" % r)

    ang_ticks = sum(1 for r in rows if r[2])
    print("balance_ctrl 向量: %d 拍（其中角度环 %d 拍）" % (len(rows), ang_ticks))
    print("  expected_u 范围 [%d, %d]，安全态拍数 %d" % (u_lo, u_hi, n_safe))
    print("  写出: %s" % os.path.normpath(path))


if __name__ == "__main__":
    main()
