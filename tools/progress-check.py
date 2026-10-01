#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""阶段进度快照 + 一致性检测（只读，不修改任何项目文件）。

用途：每个阶段（W1~W4 / M1~M9）完成后跑一次，产出可粘贴进汇报的事实清单。
纪律对齐：本文件只报告"实际读到的值"，不猜、不估算；无法核实的显式标注。

用法（路径相对本脚本自身解析，搬家不废）：
    Linux/WSL : python3 tools/progress-check.py
    Windows   : py tools\\progress-check.py
"""
import re
import subprocess
import sys
import time
from pathlib import Path

try:                                    # 中文控制台（cp936）防护，见项目踩坑记录
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = Path(__file__).resolve().parent.parent
FPGA = ROOT / "inverted-pendulum" / "fpga" / "pendulum"
SRC = FPGA / "src"
TB = FPGA / "tb"
CST = FPGA / "constraint" / "pendulum.cst"
BUILD_TCL = FPGA / "build.tcl"
FS = FPGA / "pendulum" / "impl" / "pnr" / "pendulum.fs"

# W2 目标模块（发展规划 §二；seg_display 已转正式项；mcp3202_spi 因无外购 ADC 芯片取消，改为 adc_bridge）
W2_MODULES = ["quad_decoder", "adc_bridge", "uart_tx", "seg_display"]


def run(args):
    try:
        p = subprocess.run(args, cwd=str(ROOT), capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        return p.stdout.strip()
    except Exception as exc:                       # noqa: BLE001
        return "ERR: %s" % exc


def read(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""


def mtime(path):
    try:
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(Path(path).stat().st_mtime))
    except Exception:
        return "-"


def h(title):
    print("\n## " + title)


def main():
    print("# FPGA 倒立摆 · 阶段进度快照")
    print("\n> 快照时间：%s（只读检测，未改动任何文件）" % time.strftime("%Y-%m-%d %H:%M:%S"))

    h("一、仓库状态")
    print("- HEAD: `%s`" % run(["git", "log", "-1", "--format=%h %ad %s",
                               "--date=format:%Y-%m-%d %H:%M"]))
    status = run(["git", "status", "--short"]).splitlines()
    if not status:
        print("- 工作树：干净")
    else:
        mod = [l for l in status if not l.startswith("??")]
        unt = [l for l in status if l.startswith("??")]
        print("- 已跟踪改动 %d 项、未跟踪 %d 项：" % (len(mod), len(unt)))
        for line in status[:25]:
            print("  - `%s`" % line.strip())
        if len(status) > 25:
            print("  - …（共 %d 项，仅列前 25）" % len(status))

    h("二、W2 采集链模块矩阵（模块 + 配对 TB）")
    vfiles = sorted(SRC.glob("*.v")) if SRC.is_dir() else []
    tbfiles = sorted(TB.glob("*_tb.v")) if TB.is_dir() else []
    tb_stems = set(p.stem.replace("_tb", "") for p in tbfiles)
    print("| 目标模块 | RTL | TB | 状态 |")
    print("|---|---|---|---|")
    for name in W2_MODULES:
        rtl = SRC / (name + ".v")
        has_rtl = "有" if rtl.is_file() else "—"
        has_tb = "有" if name in tb_stems else "—"
        state = "完成" if (rtl.is_file() and name in tb_stems) else ("RTL 待 TB" if rtl.is_file() else "未开始")
        print("| `%s.v` | %s | %s | %s |" % (name, has_rtl, has_tb, state))
    others = [p.name for p in vfiles if p.stem not in W2_MODULES]
    print("\n- src/ 实际文件：%s" % (", ".join(p.name for p in vfiles) or "无"))
    print("- tb/ 实际文件：%s" % (", ".join(p.name for p in tbfiles) or "无"))
    print("- 非 W2 目标的其他源文件：%s" % (", ".join(others) or "无"))

    h("三、顶层端口 ↔ 引脚约束一致性")
    top = read(SRC / "top.v") if (SRC / "top.v").is_file() else ""
    head = top.split(");", 1)[0]
    ports = set()
    for line in head.splitlines():
        line = line.split("//")[0].strip()        # 先去掉行尾注释，否则带注释的端口会被漏掉
        if not line or line.startswith("module"):
            continue
        m = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*[,)]?\s*$", line)
        if m:
            ports.add(m.group(1))
    cst = read(CST)
    locs = set(re.findall(r'IO_LOC\s+"([^"]+)"', cst))
    base = set(re.sub(r"\[.*\]", "", x) for x in locs)
    pins = re.findall(r'IO_LOC\s+"([^"]+)"\s+([A-Za-z0-9_]+);', cst)
    bypin = {}
    for name, pin in pins:
        bypin.setdefault(pin, []).append(name)
    conflict = {p: v for p, v in bypin.items() if len(v) > 1}
    mark = cst.count("[待丝印]")
    print("- top.v 端口 %d 个；cst 约束 %d 条" % (len(ports), len(locs)))
    print("- 端口未约束（危险）：%s" % (sorted(ports - base) or "无"))
    print("- 约束未用（无害）：%s" % (sorted(base - ports) or "无"))
    print("- 同一引脚多信号占用（危险）：%s" % (conflict or "无"))
    print("- `[待丝印]` 标记 %d 处 → 引脚定稿状态：%s"
          % (mark, "已定稿" if mark == 0 else "**未定稿**（M1 未闭环）"))

    h("四、build.tcl 覆盖检查")
    tcl = read(BUILD_TCL)
    listed = set(re.findall(r"add_file\s+\S*?([A-Za-z0-9_./]+\.(?:v|cst|sdc))", tcl))
    listed_names = set(Path(x).name for x in listed)
    actual = [p for p in vfiles] + sorted((FPGA / "constraint").glob("*"))
    missing = [p.name for p in actual if p.name not in listed_names]
    print("- 已加入构建：%s" % (", ".join(sorted(listed_names)) or "无"))
    print("- 磁盘存在但未加入构建：%s" % (", ".join(missing) if missing else "无"))
    print("  说明：未接入 top 的新模块不会导致构建失败，但会静默漏模块。")

    h("五、构建产物新鲜度")
    if FS.is_file():
        print("- `pendulum.fs`：%s（%d B）" % (mtime(FS), FS.stat().st_size))
        topold = top and top.strip() == read(SRC / "top.v").strip()
        print("- top.v 修改时间：%s" % mtime(SRC / "top.v"))
        print("- cst 修改时间：%s" % mtime(CST))
        stale = Path(CST).stat().st_mtime > FS.stat().st_mtime or \
            (SRC / "top.v").stat().st_mtime > FS.stat().st_mtime
        print("- 判定：%s" % ("**产物已过期，需重建**" if stale else "产物覆盖当前 top.v 与 cst（有效）"))
    else:
        print("- **未找到 pendulum.fs**，尚未成功构建过")

    h("六、TB 产物与忽略规则")
    ign = read(ROOT / ".gitignore")
    for pat in ("*.vvp", "*.vcd"):
        print("- `.gitignore` 含 `%s`：%s" % (pat, "是" if pat in ign else "**否**"))
    stray = []
    for p in FPGA.rglob("*"):
        if p.suffix in (".vvp", ".vcd") and p.is_file():
            stray.append(str(p.relative_to(ROOT)))
    print("- 工作树中的仿真产物 %d 个：%s" % (len(stray), ", ".join(stray[:8]) or "无"))

    h("七、固定红线提醒（每次汇报都过一遍）")
    for line in [
        "引脚结论需“原理图 + 实物丝印”双证，单源不得写入 .cst",
        "ANGLE_SIGN / MOTOR_SIGN / ENC_SIGN 只在安装↔物理坐标边界定义一次",
        "泵能方向必须开环 bang-bang 实测裁决，不盲抄公式约定",
        "控制律用整数码值域实现，必须带积分限幅",
        "改 sim/ 后重跑 run_sim.py 并用 git diff 比对 sim_out/*.png",
        "RTL 正确性由 Python 已验证向量逐拍对拍（±2 LSB）判定，不接受“整体差不多”",
    ]:
        print("- [ ] " + line)


if __name__ == "__main__":
    main()
