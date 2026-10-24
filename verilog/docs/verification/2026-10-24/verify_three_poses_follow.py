#!/usr/bin/env python3
"""三姿态 ADC 跟随独立复算（新板标定采集，2026-10-24）。

判据（NEXT_SESSION.md 第 4 步，原文）：
  每组至少 100 个连续 STOP/link 帧；姿态中位差 > max(200, 3×组内最大跨度)。
解析器复用 _tools/analyze_tlm.parse_capture（与 new_board_stop 复核同一口径）。
"""
import hashlib
import json
import statistics
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "_tools"))
from analyze_tlm import parse_capture

BASE = Path(__file__).resolve().parent
POSES = {
    "hanging": BASE / "calib_hanging_stop_1826.bin",
    "upright": BASE / "calib_upright_1831.bin",
    "hanging_return": BASE / "calib_hanging_return_1834.bin",
}
OUT = BASE / "verify_three_poses.json"
if OUT.exists():
    raise SystemExit("refusing to overwrite evidence: " + str(OUT))


def load(path):
    raw = path.read_bytes()
    frames, parsed = parse_capture(raw)
    stop_frames = [f for f in frames if f["mode"] == 0 and f["link"] == 1]
    return {
        "file": path.name,
        "sha256": hashlib.sha256(raw).hexdigest(),
        "valid_frames": len(frames),
        "stop_link_frames": len(stop_frames),
        "sequence_breaks": parsed["sequence_breaks"] if "sequence_breaks" in parsed else None,
        "rejected_candidates": parsed["rejected_candidates"],
        "adc": [f["adc"] for f in stop_frames],
        "all_stop": all(f["mode"] == 0 for f in frames),
        "all_link": all(f["link"] == 1 for f in frames),
        "all_duty_zero": all(f["duty"] == 0 for f in frames),
        "all_braking": all(f["braking"] == 1 for f in frames),
        "all_key_released": all(f["key"] == 1 for f in frames),
    }


results = {name: load(path) for name, path in POSES.items()}
for name, r in results.items():
    adc = r["adc"]
    r["adc_median"] = statistics.median(adc)
    r["adc_min"] = min(adc)
    r["adc_max"] = max(adc)
    r["span"] = r["adc_max"] - r["adc_min"]
    r["enough_stop_frames"] = r["stop_link_frames"] >= 100
    r["safety_clean"] = (r["all_stop"] and r["all_link"] and r["all_duty_zero"]
                         and r["all_braking"] and r["all_key_released"])

pairs = {}
for a, b in [("hanging", "upright"), ("upright", "hanging_return"),
             ("hanging", "hanging_return")]:
    ra, rb = results[a], results[b]
    diff = abs(ra["adc_median"] - rb["adc_median"])
    gate = max(200, 3 * max(ra["span"], rb["span"]))
    pairs[f"{a}_vs_{b}"] = {
        "median_diff": diff,
        "gate": gate,
        "pass": diff > gate,
    }

upright_median = results["upright"]["adc_median"]
summary = {
    "captures": {k: {kk: vv for kk, vv in v.items() if kk != "adc"}
                 for k, v in results.items()},
    "pairs": pairs,
    "ang_offset_suggestion": upright_median,
    "all_pass": all(p["pass"] for p in pairs.values())
                and all(r["enough_stop_frames"] and r["safety_clean"]
                        for r in results.values()),
}
OUT.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
               encoding="utf-8")
print(json.dumps(summary, ensure_ascii=False, indent=2))
sys.exit(0 if summary["all_pass"] else 1)
