# -*- coding: utf-8 -*-
"""旋转式倒立摆动力学模型（QUBE-Servo 形式的非线性方程 + RK4 积分）

状态 x = [theta, alpha, dtheta, dalpha]
    theta : 旋转臂角度（rad）
    alpha : 摆杆角度（rad），0 = 垂直向上，正方向与 theta 正方向处摆杆前倾为正
执行链：占空比 u∈[-100,100]（%，与江协 Motor_SetPWM 同尺度）
        → V = u/100 * 12V
        → tau = Km*(V − Ke*dtheta)（输出轴折算的一阶电机模型）

⚠️ 参数来源标注：
    Ke   由手册"12V → 620RPM 空载"反推（12/(620*2π/60)）
    其余几何/惯量/摩擦参数为占位估计（江协手册未给出），实物阶段必须实测替换。
    哪些参数敏感 → 见 run_sim.py 的敏感性场景，这是阶段 0 的核心产出之一。
"""
import numpy as np
from dataclasses import dataclass


@dataclass
class Params:
    Lr: float = 0.10      # 臂长 m（电机轴→摆轴距离）        [占位：按套件照片估计，实测替换]
    Lp: float = 0.20      # 摆杆长 m                          [占位]
    mp: float = 0.030     # 摆杆质量 kg                       [占位]
    Ja: float = 1.0e-4    # 臂+转盘+联轴器绕电机轴惯量 kg·m²  [占位]
    beq: float = 2.0e-3   # 臂侧等效粘性摩擦 N·m·s/rad        [占位]
    Km: float = 0.05      # 电机力矩常数 N·m/V（输出轴折算，堵转≈0.6N·m@12V）[占位]
    Ke: float = 0.185     # 反电动势常数 V·s/rad（12V→620RPM 反推）[手册推算]
    Vmax: float = 12.0
    g: float = 9.81

    @property
    def lc(self) -> float:            # 摆杆质心距摆轴
        return self.Lp / 2.0

    @property
    def Jp(self) -> float:            # 细杆绕质心横轴惯量
        return self.mp * self.Lp**2 / 12.0


def derivs(x: np.ndarray, tau: float, p: Params) -> np.ndarray:
    """非线性动力学：解开 2×2 质量矩阵，返回 [dtheta, dalpha, ddtheta, ddalpha]

    拉格朗日方程（q1=theta 臂角，q2=alpha 摆角，摆杆质心在杆中点）：
      (Ja + mp·Lr²)·θ̈ + mp·Lr·lc·cosα·α̈ = τ − beq·θ̇ + mp·Lr·lc·sinα·α̇²
      mp·Lr·lc·cosα·θ̈ + (Jp + mp·lc²)·α̈ = mp·g·lc·sinα
    （θ 与 α 的离心项在第二式中相消，故右边只剩重力项）
    """
    th, al, dth, dal = x
    A11 = p.Ja + p.mp * p.Lr**2
    A12 = p.mp * p.Lr * p.lc * np.cos(al)
    A22 = p.Jp + p.mp * p.lc**2
    b = np.array([
        tau - p.beq * dth + p.mp * p.Lr * p.lc * np.sin(al) * dal**2,
        p.mp * p.g * p.lc * np.sin(al),
    ])
    dd = np.linalg.solve(np.array([[A11, A12], [A12, A22]]), b)
    return np.array([dth, dal, dd[0], dd[1]])


def motor_tau(u: float, dtheta: float, p: Params) -> float:
    """占空比(%) → 输出轴力矩（含反电动势）"""
    V = np.clip(u, -100.0, 100.0) / 100.0 * p.Vmax
    return p.Km * (V - p.Ke * dtheta)


def rk4_step(x: np.ndarray, u: float, dt: float, p: Params) -> np.ndarray:
    """一步 RK4（控制量 u 在步内零阶保持，对应 FPGA 的 1kHz 节拍）"""
    k1 = derivs(x, motor_tau(u, x[2], p), p)
    k2 = derivs(x + 0.5 * dt * k1, motor_tau(u, x[2] + 0.5 * dt * k1[2], p), p)
    k3 = derivs(x + 0.5 * dt * k2, motor_tau(u, x[2] + 0.5 * dt * k2[2], p), p)
    k4 = derivs(x + dt * k3, motor_tau(u, x[2] + dt * k3[2], p), p)
    return x + dt / 6.0 * (k1 + 2 * k2 + 2 * k3 + k4)


def sanity_check(p: Params) -> None:
    """数量级自检：电机能力 vs 摆杆重力矩 / 起摆可行性"""
    tau_stall = p.Km * p.Vmax
    tau_grav = p.mp * p.g * p.lc
    print(f"[sanity] 电机堵转力矩 {tau_stall:.3f} N·m | 摆杆最大重力矩 {tau_grav:.3f} N·m "
          f"| 比值 {tau_stall/tau_grav:.1f}× （>5× 起摆才可行）")
    w_nl = p.Vmax / p.Ke
    print(f"[sanity] 空载输出轴转速 {w_nl:.1f} rad/s = {w_nl*60/2/np.pi:.0f} RPM（手册标称 620）")
    assert tau_stall > 5 * tau_grav, "电机力矩不足以起摆，检查参数"
    assert abs(w_nl - 620 * 2 * np.pi / 60) / w_nl < 0.15, "Ke 与手册空载转速不符"


if __name__ == "__main__":
    p = Params()
    sanity_check(p)
