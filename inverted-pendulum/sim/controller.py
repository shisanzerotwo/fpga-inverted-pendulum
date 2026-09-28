# -*- coding: utf-8 -*-
"""控制器：逐字复刻江协参考实现（16-倒立摆-自动启摆）的语义，外加可选 LQR。

复刻要点（与 STM32 源码逐条对应）：
  - 全部控制量在"传感器码值域"运算：摆角 = ADC 码值（垂直位≈2010），位置 = 编码器计数（408/圈）
  - 1kHz 节拍；摆角环每 5 拍、位置环每 50 拍、摆幅检测每 40 拍
  - PID 公式 Out = Kp·E0 + Ki·∑E + Kd·(E0−E1)，Ki=0 时积分强制清零，限幅 ±100
  - 起摆状态机 RunState：0 停 / 1 监测 / 21~24 正反甩 / 31~34 反正甩 / 4 平衡
  - 平衡中摆角出 ±RANGE 窗即退出到 0
"""
import numpy as np

# ---- 传感器尺度（与江协套件一致）----
CENTER = 2010.0                          # 垂直位 ADC 码值 [占位：实测校准]
RANGE = 500.0                            # 捕获/维持窗口（码值）≈ ±40.7°
ADC_PER_RAD = 4095.0 / (333.0 * np.pi / 180.0)   # ≈ 704.6 码值/rad
CNT_PER_RAD = 408.0 / (2.0 * np.pi)              # ≈ 64.9 计数/rad（输出轴）

START_PWM = 35.0     # 起摆激励占空比 %
START_TIME = 100     # 每段激励时长（控制拍 = ms）

# ---- 方向常数（安装自由度，实物 bring-up 时手拨摆杆实测标定）----
# 本仿真模型约定：α>0 = 摆杆向正方向倾倒；u>0 = 臂向正方向加速。
# 倒立摆负反馈要求：α>0（往正倒）→ 臂往正追 → u>0。
# 江协公式 u = Kp·(CENTER − adc) 在"传感器正装 + 电机正装"下给出 u<0 → 正反馈 → 必炸。
# MOTOR_SIGN 把复刻公式折算到本模型的执行方向；实物上对应"接反就换相线/改符号"这一个开关。
ANGLE_SIGN = +1.0    # 传感器方向：+1 = α 增大 → ADC 增大
MOTOR_SIGN = -1.0    # 电机方向：-1 = 复刻公式输出取反后才满足本模型的负反馈


class PID:
    """复刻 User/PID.c：位置式，Ki==0 时积分清零"""

    def __init__(self, Kp, Ki, Kd, OutMax=100.0, OutMin=-100.0):
        self.Kp, self.Ki, self.Kd = Kp, Ki, Kd
        self.OutMax, self.OutMin = OutMax, OutMin
        self.Target = 0.0
        self.Actual = 0.0
        self.Out = 0.0
        self.Error0 = self.Error1 = self.ErrorInt = 0.0

    def update(self) -> float:
        self.Error1 = self.Error0
        self.Error0 = self.Target - self.Actual
        if self.Ki != 0:
            self.ErrorInt += self.Error0
        else:
            self.ErrorInt = 0.0
        self.Out = (self.Kp * self.Error0
                    + self.Ki * self.ErrorInt
                    + self.Kd * (self.Error0 - self.Error1))
        self.Out = min(max(self.Out, self.OutMin), self.OutMax)
        return self.Out


class JXPendulumController:
    """江协 16-倒立摆-自动启摆 的完整复刻（状态机 + 双环 PID）"""

    def __init__(self, start_state: int = 0, start_pwm: float = 35.0, start_time: int = 100):
        self.angle_pid = PID(Kp=0.3, Ki=0.01, Kd=0.4)      # 摆角环（码值域）
        self.loc_pid = PID(Kp=0.4, Ki=0.0, Kd=4.0)          # 位置环（计数域）
        self.angle_pid.Target = CENTER
        self.loc_pid.Target = 0.0
        self.state = start_state    # 0=完整自动流程；1=模拟人手已拨摆入窗（跳过激励）
        self.start_pwm = start_pwm  # 起摆激励占空比 [占位模型上需扫描，实物重标]
        self.start_time = start_time
        self.count0 = self.count1 = self.count2 = self.count_time = 0
        self.a0 = self.a1 = self.a2 = 0.0
        self.location = 0.0                                  # 编码器计数累加

    # ---- 传感器模型（含 ±4095 限幅，模拟真实 ADC）----
    @staticmethod
    def adc_of(alpha: float) -> float:
        return float(np.clip(CENTER + ANGLE_SIGN * alpha * ADC_PER_RAD, 0.0, 4095.0))

    def step(self, alpha: float, dtheta_counts: float) -> float:
        """每个 1kHz 控制拍调用一次；dtheta_counts = 本拍编码器增量（计数）"""
        self.location += MOTOR_SIGN * dtheta_counts   # 编码器计数方向与电机方向一致
        self.location += dtheta_counts
        Angle = self.adc_of(alpha)

        c = self.angle_pid
        lp = self.loc_pid
        st = self.state

        if st == 0:
            u = 0.0
        elif st == 1:
            # 每 40 拍采三次摆角，检测同侧摆幅极值 → 再激励一次
            self.count0 += 1
            u = 0.0
            if self.count0 >= 40:
                self.count0 = 0
                self.a2, self.a1, self.a0 = self.a1, self.a0, Angle
                if (self.a0 > CENTER + RANGE and self.a1 > CENTER + RANGE
                        and self.a2 > CENTER + RANGE
                        and self.a1 < self.a0 and self.a1 < self.a2):
                    st = 21
                if (self.a0 < CENTER - RANGE and self.a1 < CENTER - RANGE
                        and self.a2 < CENTER - RANGE
                        and self.a1 > self.a0 and self.a1 > self.a2):
                    st = 31
                if (CENTER - RANGE < self.a0 < CENTER + RANGE
                        and CENTER - RANGE < self.a1 < CENTER + RANGE):
                    self.location = 0.0
                    c.ErrorInt = 0.0
                    lp.ErrorInt = 0.0
                    st = 4
        elif st == 21:
            u, self.count_time, st = self.start_pwm, self.start_time, 22
        elif st == 22:
            u = self.start_pwm
            self.count_time -= 1
            if self.count_time == 0:
                st = 23
        elif st == 23:
            u, self.count_time, st = -self.start_pwm, self.start_time, 24
        elif st == 24:
            u = -self.start_pwm
            self.count_time -= 1
            if self.count_time == 0:
                u, st = 0.0, 1
        elif st == 31:
            u, self.count_time, st = -self.start_pwm, self.start_time, 32
        elif st == 32:
            u = -self.start_pwm
            self.count_time -= 1
            if self.count_time == 0:
                st = 33
        elif st == 33:
            u, self.count_time, st = self.start_pwm, self.start_time, 34
        elif st == 34:
            u = self.start_pwm
            self.count_time -= 1
            if self.count_time == 0:
                u, st = 0.0, 1
        elif st == 4:
            # 平衡：出窗即退；摆角环 200Hz；位置环 20Hz 修正摆角目标
            if not (CENTER - RANGE < Angle < CENTER + RANGE):
                st = 0
                u = 0.0
            else:
                u = 0.0
                self.count1 += 1
                if self.count1 >= 5:
                    self.count1 = 0
                    c.Actual = Angle
                    u = c.update()
                self.count2 += 1
                if self.count2 >= 50:
                    self.count2 = 0
                    lp.Actual = self.location
                    lp.update()
                    c.Target = CENTER - lp.Out
        else:
            u, st = 0.0, 0

        self.state = st
        return MOTOR_SIGN * u


def lqr_gain(p, Q=None, R=None):
    """线性化 LQR（α 小角度）。返回 K（1×4），u = -K·[θ, α, θ̇, α̇]

    线性化（τ 直达，忽略电机动态）：
      M·[θ̈;α̈] = [τ − beq·θ̇; mp·g·lc·α]，M = [[Ja+mp·Lr², a],[a, Jp+mp·lc²]]，a = mp·Lr·lc
      θ̈ = (A22·τ − A22·beq·θ̇ − a·mp·g·lc·α)/den
      α̈ = (−a·τ + a·beq·θ̇ + A11·mp·g·lc·α)/den，den = A11·A22 − a²
    """
    from scipy.linalg import solve_continuous_are
    g, mp, Lr, lc = p.g, p.mp, p.Lr, p.lc
    A11 = p.Ja + mp * Lr**2
    A22 = p.Jp + mp * lc**2
    a = mp * Lr * lc
    den = A11 * A22 - a * a
    A = np.array([
        [0.0, 0.0, 1.0, 0.0],
        [0.0, 0.0, 0.0, 1.0],
        [0.0, -a * mp * g * lc / den, -A22 * p.beq / den, 0.0],
        [0.0, A11 * mp * g * lc / den, a * p.beq / den, 0.0],
    ])
    B = np.array([[0.0], [0.0], [A22 / den], [-a / den]])
    Q = np.diag([1.0, 50.0, 1.0, 5.0]) if Q is None else Q
    R = np.array([[0.05]]) if R is None else R
    S = solve_continuous_are(A, B, Q, R)
    return np.linalg.solve(R, B.T @ S)


class EnergySwingUp:
    """能量控制起摆 + 江协双环平衡（阶段 B 候选方案：对物理参数漂移免疫）

    原理：以"摆轴能量误差 × 摆速方向"注入力矩（泵能），每摆一周注入一次；
    江协的固定往复甩摆要求激励节奏匹配摆的自然周期（本占位模型下 12 组参数扫描全败，
    见 run_sim 场景2），能量控制不做此假设。
    实物注意：dalpha 由摆角差分估计（FPGA 中 1kHz 差分 + 低通）。
    """
    def __init__(self, ke_gain: float = 60.0):
        self.angle_pid = PID(Kp=0.3, Ki=0.01, Kd=0.4)
        self.loc_pid = PID(Kp=0.4, Ki=0.0, Kd=4.0)
        self.angle_pid.Target = CENTER
        self.loc_pid.Target = 0.0
        self.state = 1                      # 1=能量起摆 4=平衡（出窗回起摆）
        self.ke_gain = ke_gain
        self.location = 0.0
        self.count1 = self.count2 = 0

    def step(self, alpha: float, dalpha: float, dtheta_counts: float, p) -> float:
        """⚠️ 方向常数只在安装坐标边界应用一次：
        能量起摆在物理坐标系直接算力矩（不乘 MOTOR_SIGN）；
        平衡环复刻江协安装坐标公式（输出乘 MOTOR_SIGN）。"""
        self.location += MOTOR_SIGN * dtheta_counts
        u = 0.0
        if self.state == 1:
            J = p.Jp + p.mp * p.lc**2
            E = 0.5 * J * dalpha**2 + p.mp * p.g * p.lc * (np.cos(alpha) - 1.0)
            # 泵能方向经开环 bang-bang 对照实验裁决（见会话记录）：
            # 本模型/坐标系下 τ = +(E−E_ref)·sign(α̇·cosα) 为泵能方向
            u = self.ke_gain * (E - 0.0) * np.sign(dalpha * np.cos(alpha) + 1e-12)
            u = float(np.clip(u, -70.0, 70.0))
            if abs(alpha) < np.deg2rad(35.0) and abs(dalpha) < 4.0:
                self.angle_pid.ErrorInt = 0.0
                self.loc_pid.ErrorInt = 0.0
                self.location = 0.0
                self.state = 4
        elif self.state == 4:
            Angle = JXPendulumController.adc_of(alpha)
            if not (CENTER - RANGE < Angle < CENTER + RANGE):
                self.state = 1
            else:
                u = 0.0
                self.count1 += 1
                if self.count1 >= 5:
                    self.count1 = 0
                    self.angle_pid.Actual = Angle
                    u = self.angle_pid.update()
                self.count2 += 1
                if self.count2 >= 50:
                    self.count2 = 0
                    self.loc_pid.Actual = self.location
                    self.loc_pid.update()
                    self.angle_pid.Target = CENTER - self.loc_pid.Out
            u = MOTOR_SIGN * u
        return u
