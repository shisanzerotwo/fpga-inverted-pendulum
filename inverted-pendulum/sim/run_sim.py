# -*- coding: utf-8 -*-
"""阶段 0 仿真场景：
  1) 稳摆（复刻 15-手动版：手动拨摆入窗 → 平衡）+ 抗扰
  2) 自动起摆全程（复刻 16-自动版）
  3) 位置阶跃（拓展①：目标 ±1 圈）
  4) LQR 对比稳摆（可选，scipy 缺失则跳过）

输出：sim_out/*.png 曲线 + 控制台摘要。
运行：py run_sim.py
"""
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
matplotlib.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei"]
matplotlib.rcParams["axes.unicode_minus"] = False
import matplotlib.pyplot as plt

from model import Params, rk4_step
from controller import (JXPendulumController, EnergySwingUp, lqr_gain,
                        CENTER, RANGE, ADC_PER_RAD, CNT_PER_RAD)

DT = 0.001          # 控制节拍 1kHz（与 STM32 TIM1 一致）
SUB = 4             # 每控制拍内动力学子步（RK4 @ 4kHz，控制量 ZOH）
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sim_out")


def adc2rad(adc: float) -> float:
    return (adc - CENTER) / ADC_PER_RAD


def simulate(p: Params, t_end: float, alpha0: float,
             disturbance=None, target_fn=None, lqr_K=None):
    """LQR 场景仿真骨架（连续反馈，每控制拍更新 u）。
    disturbance: list[(t0, alpha_impulse)] 在 t0 时刻给摆杆加冲击（速度突变）
    """
    n = int(t_end / DT)
    x = np.array([0.0, alpha0, 0.0, 0.0])
    log = {k: np.zeros(n) for k in ("t", "alpha", "theta", "u", "loc", "state")}

    for i in range(n):
        t = i * DT
        u = float(np.clip(-lqr_K @ x, -100, 100)[0])

        if disturbance:
            for t0, dv in disturbance:
                if abs(t - t0) < DT / 2:
                    x[3] += dv                 # 摆杆角速度冲击（模拟手指弹一下）

        for _ in range(SUB):
            x = rk4_step(x, u, DT / SUB, p)

        log["t"][i], log["alpha"][i] = t, x[1]
        log["theta"][i], log["u"][i] = x[0], u
        log["loc"][i] = x[0] * CNT_PER_RAD
        log["state"][i] = 4
    return log


def simulate_jx(p: Params, t_end: float, alpha0: float,
                disturbance=None, target_fn=None, start_state: int = 0,
                start_pwm: float = 35.0, start_time: int = 100):
    """江协调控制器的精确仿真：编码器增量在物理子步后统计并回传 step。"""
    n = int(t_end / DT)
    x = np.array([0.0, alpha0, 0.0, 0.0])
    ctrl = JXPendulumController(start_state=start_state,
                                start_pwm=start_pwm, start_time=start_time)
    log = {k: np.zeros(n) for k in ("t", "alpha", "theta", "u", "loc", "state")}
    theta_count_acc = 0.0

    for i in range(n):
        t = i * DT
        if target_fn is not None:
            ctrl.loc_pid.Target = target_fn(t)
        u = ctrl.step(x[1], theta_count_acc)   # 传入上一拍统计的编码器增量
        theta_count_acc = 0.0

        if disturbance:
            for t0, dv in disturbance:
                if abs(t - t0) < DT / 2:
                    x[3] += dv

        for _ in range(SUB):
            x_prev = x.copy()
            x = rk4_step(x, u, DT / SUB, p)
            theta_count_acc += (x[0] - x_prev[0]) * CNT_PER_RAD

        log["t"][i], log["alpha"][i] = t, x[1]
        log["theta"][i], log["u"][i] = x[0], u
        log["loc"][i] = ctrl.location
        log["state"][i] = ctrl.state
    return log


def simulate_energy(p: Params, t_end: float, alpha0: float, ke_gain: float = 60.0,
                    disturbance=None, target_fn=None):
    """能量起摆 + 双环平衡的仿真（dalpha 由模型真值给出，实物为差分估计）。"""
    n = int(t_end / DT)
    x = np.array([0.0, alpha0, 0.0, 0.0])
    ctrl = EnergySwingUp(ke_gain=ke_gain)
    log = {k: np.zeros(n) for k in ("t", "alpha", "theta", "u", "loc", "state")}
    theta_count_acc = 0.0
    for i in range(n):
        t = i * DT
        if target_fn is not None:
            ctrl.loc_pid.Target = target_fn(t)
        u = ctrl.step(x[1], x[3], theta_count_acc, p)
        theta_count_acc = 0.0
        if disturbance:
            for t0, dv in disturbance:
                if abs(t - t0) < DT / 2:
                    x[3] += dv
        for _ in range(SUB):
            x_prev = x.copy()
            x = rk4_step(x, u, DT / SUB, p)
            theta_count_acc += (x[0] - x_prev[0]) * CNT_PER_RAD
        log["t"][i], log["alpha"][i] = t, x[1]
        log["theta"][i], log["u"][i] = x[0], u
        log["loc"][i] = ctrl.location
        log["state"][i] = ctrl.state
    return log


def plot(logs, title, fname, alpha_deg=True):
    fig, axes = plt.subplots(4, 1, figsize=(10, 9), sharex=True)
    k = 180 / np.pi if alpha_deg else 1.0
    for name, log in logs.items():
        axes[0].plot(log["t"], log["alpha"] * k, label=name, lw=0.8)
        axes[1].plot(log["t"], (log["theta"] % (2 * np.pi)) * k * (1 if alpha_deg else 1), lw=0.8)
        axes[2].plot(log["t"], log["u"], lw=0.8)
        axes[3].plot(log["t"], log["loc"] / 408.0, lw=0.8)   # 圈数
    axes[0].set_ylabel("摆角 α (deg)" if alpha_deg else "α")
    axes[0].axhline(0, color="gray", ls=":", lw=0.6)
    axes[0].legend(fontsize=8)
    axes[1].set_ylabel("臂角 θ (deg)" if alpha_deg else "θ")
    axes[2].set_ylabel("PWM u (%)")
    axes[3].set_ylabel("位置 (圈)")
    axes[3].set_xlabel("t (s)")
    fig.suptitle(title)
    fig.tight_layout()
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, fname)
    fig.savefig(path, dpi=130)
    plt.close(fig)
    return path


def main():
    p = Params()
    results = []

    # ---- 场景 1：稳摆 + 抗扰（工作点内：5° 入窗起稳，中途两次 ±15° 轻推）----
    log = simulate_jx(p, t_end=8.0, alpha0=np.deg2rad(5.0), start_state=1,
                      disturbance=[(4.0, np.deg2rad(15.0)), (6.0, -np.deg2rad(15.0))])
    idx4 = np.argwhere(log["state"] == 4).ravel()
    a = np.abs(np.rad2deg(log["alpha"][idx4]))
    settle = a[len(a) // 2:] if a.size else a
    results.append(("场景1 稳摆+抗扰", log,
                    f"平衡段 {log['t'][idx4[0]] if idx4.size else float('nan'):.2f}s 起，"
                    f"扰动后峰值 {a.max():.1f}° 末段 {settle.max():.1f}°"))

    # ---- 场景 2：自动起摆 —— 起摆激励参数扫描（占位模型下的可行域）----
    print("[场景2] 起摆参数扫描（占位模型，初始 179°）：")
    best = None
    rows = []
    for pwm in (35.0, 50.0, 70.0, 100.0):
        row = []
        for tms in (100, 200, 300):
            lg = simulate_jx(p, t_end=15.0, alpha0=np.deg2rad(179.0),
                             start_state=21, start_pwm=pwm, start_time=tms)
            i4 = np.argwhere(lg["state"] == 4).ravel()
            ok = i4.size and (lg["state"][-2000:] == 4).all()   # 进平衡且末 2s 保持
            t_in = lg["t"][i4[0]] if i4.size else float("nan")
            row.append(f"{t_in:5.2f}" if ok else "  ×  ")
            if ok and best is None:
                best = (pwm, tms, t_in, lg)
        rows.append(row)
        print(f"  PWM={pwm:5.1f}%  100ms:{row[0]}  200ms:{row[1]}  300ms:{row[2]}  (成功→进入平衡时刻 s)")
    if best:
        pwm, tms, t_in, log2 = best
        results.append(("场景2 自动起摆", log2,
                        f"扫描最优 start_pwm={pwm:.0f}%/start_time={tms}ms，t={t_in:.2f}s 入稳"))
    else:
        # 江协固定往复甩摆全部失败 → 能量控制起摆（阶段 B 候选）
        print("[场景2] 江协固定甩摆全败 → 切换能量控制起摆：")
        best_kg, best_log, best_t = None, None, None
        for kg in (3000.0, 5000.0, 8000.0):
            lg = simulate_energy(p, t_end=15.0, alpha0=np.deg2rad(179.0), ke_gain=kg)
            i4 = np.argwhere(lg["state"] == 4).ravel()
            ok = i4.size and (lg["state"][-2000:] == 4).all()
            print(f"  ke_gain={kg:6.1f} → {'✓ t=%.2fs 入稳' % lg['t'][i4[0]] if ok else '×'}")
            if ok and best_log is None:
                best_kg, best_log, best_t = kg, lg, lg["t"][i4[0]]
        if best_log is not None:
            results.append(("场景2 能量起摆", best_log,
                            f"ke_gain={best_kg:.0f}：t={best_t:.2f}s 入稳（能量控制可行，甩摆参数敏感）"))
        else:
            results.append(("场景2 能量起摆", simulate_energy(p, t_end=15.0, alpha0=np.deg2rad(179.0)),
                            "能量起摆亦失败，需实物参数"))

    # ---- 场景 2b：大扰动积分失控敏感性（20° 出工作点 → 预期失败 → 论证 FPGA 版需抗饱和）----
    log2b = simulate_jx(p, t_end=8.0, alpha0=np.deg2rad(20.0), start_state=1)
    idx42b = np.argwhere(log2b["state"] == 4).ravel()
    t_exit = log2b["t"][idx42b[-1]] if idx42b.size else float("nan")
    results.append(("场景2b 大扰动(20°)敏感性", log2b,
                    f"平衡维持至 t={t_exit:.2f}s 后出窗停机（预期：积分失控）" if idx42b.size
                    else "从未进入平衡"))

    # ---- 场景 3：位置阶跃（平衡中目标 +1 圈，5s 后 −2 圈）----
    def tgt(t):
        return 408.0 if t < 5.0 else -816.0
    log3 = simulate_jx(p, t_end=10.0, alpha0=np.deg2rad(5.0), target_fn=tgt, start_state=1)
    results.append(("场景3 位置阶跃", log3, "目标 +1→−2 圈，观察位置跟随与摆角保持"))

    # ---- 场景 4：LQR 对比（同扰动）----
    try:
        K = lqr_gain(p)
        log4 = simulate(p, t_end=8.0, alpha0=np.deg2rad(20.0),
                        disturbance=[(4.0, np.deg2rad(30.0))], lqr_K=K)
        results.append(("场景4 LQR 对比", log4, f"K={np.array2string(K, precision=2)}"))
    except ImportError:
        print("[warn] 未装 scipy，跳过 LQR 场景")

    paths = []
    for name, log, note in results:
        fname = f"sc{results.index((name, log, note)) + 1}.png"
        paths.append(plot({name: log}, f"{name} — {note}", fname))
        print(f"[{name}] {note} → {fname}")

    print("\n=== 曲线输出目录：", OUT_DIR)


if __name__ == "__main__":
    main()
