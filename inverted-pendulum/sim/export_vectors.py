# -*- coding: utf-8 -*-
"""导出 PID 对拍向量（RTL TB 用 $fscanf 读入）。只读调用 model/controller/run_sim，不改它们。

做法：
  1) 用阶段 0 已验证的闭环仿真（场景 3 位置阶跃，同 run_sim.main）得到真实的摆角/位置轨迹；
  2) 量化成整数码值（模拟实物 ADC / 编码器读数）；
  3) 按参考节拍回放级联：摆角环每 5 拍、位置环每 50 拍；同一拍先跑摆角环、后跑位置环
     并改写摆角环 Target（与江协 TIM1_UP_IRQHandler 的顺序一致）；
  4) 期望值用 Fraction 精确有理数计算（不复刻 RTL 的整数缩放写法），float→int8 向零截断、限幅 ±100；
  5) 交叉核对：同一输入序列再喂给阶段 0 的 controller.PID（float64），报告与精确模型的分歧拍数。

输出（写到 fpga/pendulum/tb/vectors/）：
  pid_ang.txt：每行 "target_x10 actual_x10 out"     （0.1 码值单位输入，输出 = PWM 整数）
  pid_loc.txt：每行 "target actual out_x10"         （计数输入，输出 = 0.1 码值单位）
运行：cd inverted-pendulum/sim && py export_vectors.py
"""
import os
import sys
from fractions import Fraction as F

import numpy as np

from model import Params
from controller import PID, JXPendulumController, CENTER
from run_sim import simulate_jx

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "fpga", "pendulum", "tb", "vectors")
INT_LIM_X10 = 100000          # 与 pid_tb.v 中 u_vec_ang 的 INT_LIM 一致（x10 单位）


class FracPID:
    """精确有理数版 PID_Update（江协 User/PID.c 语义，无积分限幅）。"""

    def __init__(self, kp, ki, kd, out_max):
        self.kp, self.ki, self.kd = F(kp), F(ki), F(kd)
        self.out_max = F(out_max)
        self.e0 = self.e1 = self.ei = F(0)
        self.max_abs_ei = F(0)

    def update(self, target, actual):
        self.e1 = self.e0
        self.e0 = F(target) - F(actual)
        self.ei = self.ei + self.e0 if self.ki != 0 else F(0)
        self.max_abs_ei = max(self.max_abs_ei, abs(self.ei))
        out = self.kp * self.e0 + self.ki * self.ei + self.kd * (self.e0 - self.e1)
        return min(max(out, -self.out_max), self.out_max)


def trunc0(x):
    """向零截断（= C 的 float→int 转换）。Fraction 的 int() 即向零截断。"""
    return int(x)


def main():
    # 稳摆轨迹：5° 初扰、位置目标 0，10s 全程处于平衡态（实测 9921/10000 拍 state=4，摆角 ±6.9°）。
    # 注：场景 3（+1 圈位置阶跃）在本模型下 t≈0.76s 即倒摆，饱和拍占 94%，不适合做算术对拍。
    p = Params()
    log = simulate_jx(p, t_end=10.0, alpha0=np.deg2rad(5.0), start_state=1)
    n = len(log["t"])
    adc = [int(round(JXPendulumController.adc_of(a))) for a in log["alpha"]]
    loc = [int(round(v)) for v in log["loc"]]
    loc_tgt = [0] * n

    # 精确模型（期望值来源）
    ang = FracPID("0.3", "0.01", "0.4", 100)
    lop = FracPID("0.4", "0", "4", 100)
    ang_target = F(int(CENTER))
    # 阶段 0 float 参考（交叉核对）
    ang_f = PID(Kp=0.3, Ki=0.01, Kd=0.4)
    lop_f = PID(Kp=0.4, Ki=0.0, Kd=4.0)
    ang_f.Target = CENTER

    rows_ang, rows_loc = [], []
    xchk_ang = xchk_loc = 0
    xchk_max = 0
    for k in range(1, n + 1):
        i = k - 1
        if k % 5 == 0:                                  # 摆角环（先）
            t10 = ang_target * 10
            a10 = F(adc[i]) * 10
            assert t10.denominator == 1 and a10.denominator == 1
            out = trunc0(ang.update(ang_target, adc[i]))
            rows_ang.append((int(t10), int(a10), out))
            ang_f.Actual = adc[i]
            out_f = int(ang_f.update())                 # float→int 向零截断
            if out_f != out:
                xchk_ang += 1
                xchk_max = max(xchk_max, abs(out_f - out))
        if k % 50 == 0:                                 # 位置环（后），改写摆角环 Target
            lo = lop.update(loc_tgt[i], loc[i])
            lo10 = lo * 10
            assert lo10.denominator == 1, "位置环输出不是 0.1 的整数倍"
            rows_loc.append((loc_tgt[i], loc[i], int(lo10)))
            ang_target = F(int(CENTER)) - lo
            lop_f.Target = loc_tgt[i]
            lop_f.Actual = loc[i]
            lo_f = lop_f.update()
            if round(lo_f * 10) != int(lo10):
                xchk_loc += 1
            ang_f.Target = CENTER - lo_f

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "pid_ang.txt"), "w", newline="\n") as f:
        for r in rows_ang:
            f.write("%d %d %d\n" % r)
    with open(os.path.join(OUT_DIR, "pid_loc.txt"), "w", newline="\n") as f:
        for r in rows_loc:
            f.write("%d %d %d\n" % r)

    outs = [r[2] for r in rows_ang]
    print("角度环向量: %d 拍  out 范围 [%d, %d]  饱和拍数 %d" % (
        len(rows_ang), min(outs), max(outs), sum(1 for o in outs if abs(o) == 100)))
    print("位置环向量: %d 拍  out_x10 范围 [%d, %d]" % (
        len(rows_loc), min(r[2] for r in rows_loc), max(r[2] for r in rows_loc)))
    print("角度环 max|sumE| = %s 码值（x10 = %s；RTL INT_LIM = %d）" % (
        ang.max_abs_ei, ang.max_abs_ei * 10, INT_LIM_X10))
    if ang.max_abs_ei * 10 >= INT_LIM_X10:
        print("WARN: 轨迹触及 RTL 积分限幅，对拍将因抗饱和而合理偏离")
    print("交叉核对（float64 controller.PID vs 精确模型）：角度环分歧 %d 拍（最大差 %d），位置环分歧 %d 拍" % (
        xchk_ang, xchk_max, xchk_loc))


if __name__ == "__main__":
    main()
