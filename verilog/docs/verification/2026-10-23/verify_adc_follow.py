"""Replay ADC feedback captures; plot sample indices, never SPI-derived time."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "_tools"))
from analyze_tlm import parse_capture


def summarize(path):
    raw = path.read_bytes()
    frames, meta = parse_capture(raw)
    adc = [frame["adc"] for frame in frames]
    metadata_path = Path(str(path) + ".meta.json")
    capture_metadata = json.loads(metadata_path.read_text(encoding="utf-8")) if metadata_path.exists() else {}
    contiguous = all(b["offset"] == a["offset"] + 15 for a, b in zip(frames, frames[1:]))
    return frames, dict(meta, file=path.name, sha256=hashlib.sha256(raw).hexdigest(),
        sequence_breaks=sum(b["seq"] != (a["seq"] + 1) % 256 for a, b in zip(frames, frames[1:])),
        stop_safe=bool(frames) and all(f["mode"] == 0 and f["duty"] == 0 and
            f["enable"] == 0 and f["braking"] == 1 and f["key"] == 1 for f in frames),
        key_released=bool(frames) and all(f["key"] == 1 for f in frames),
        contiguous_frames=contiguous,
        capture_completed=capture_metadata.get("status") == "completed",
        metadata_frame_count_matches=capture_metadata.get("valid_frames") == len(frames),
        link_good=bool(frames) and all(f["link"] == 1 for f in frames),
        adc_min=min(adc) if adc else None, adc_max=max(adc) if adc else None,
        adc_median=statistics.median(adc) if adc else None,
        capture_metadata=capture_metadata)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hanging", type=Path)
    parser.add_argument("upright", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    output_paths = [args.output / "adc_follow.json", args.output / "adc_follow.png"]
    existing = [str(path) for path in output_paths if path.exists()]
    if existing:
        raise SystemExit("Refusing to overwrite evidence: " + ", ".join(existing))
    groups = [summarize(args.hanging), summarize(args.upright)]
    summaries = [meta for _, meta in groups]
    usable = all(s["valid_frames"] >= 100 and s["sequence_breaks"] == 0 and
                 s["rejected_candidates"] == 0 and s["contiguous_frames"] and
                 s["capture_completed"] and s["metadata_frame_count_matches"] and
                 s["stop_safe"] and s["key_released"] and s["link_good"] for s in summaries)
    delta = abs(summaries[1]["adc_median"] - summaries[0]["adc_median"]) if usable else None
    noise = max(s["adc_max"] - s["adc_min"] for s in summaries) if usable else None
    # Diagnostic gate only; this is not an angle or offset calibration.
    threshold = max(200, 3 * noise) if usable else None
    passed = bool(usable and delta > threshold)
    result = dict(captures=summaries, absolute_median_delta=delta, max_static_span=noise,
        diagnostic_threshold=threshold, criterion="usable STOP/link captures, >=100 frames each, delta > max(200, 3*static_span)",
        usable=usable, adc_follow_pass=passed, time_axis="sample index; no transport clock assumed",
        parser_sha256=hashlib.sha256((ROOT / "_tools/analyze_tlm.py").read_bytes()).hexdigest())
    (args.output / "adc_follow.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.5), gridspec_kw={"width_ratios": [2, 1]})
    labels = ["自然下垂", "竖直朝上"]
    for (frames, meta), label in zip(groups, labels):
        values = [f["adc"] for f in frames]
        axes[0].plot(values, label=f"{label}：中位数 {meta['adc_median']:g}", alpha=.85, linewidth=1)
        axes[1].scatter([label] * len(values), values, alpha=.1, s=14)
        axes[1].scatter(label, meta["adc_median"], color="black", marker="_", s=400)
    axes[0].set(xlabel="有效帧样本序号（非时间）", ylabel="ADC 原始计数", title="自然下垂与竖直朝上姿态的 ADC 样本")
    axes[0].legend(loc="lower right")
    axes[1].set(ylabel="ADC 原始计数", title=f"中位差 {delta:g}；组内跨度 {noise:g}" if usable else "采集不可用于比较")
    for ax in axes:
        ax.grid(alpha=.2)
    fig.suptitle("ADC 跟随验证：" + ("通过" if passed else "未通过") + "（STOP / duty=0 / brake=1）", color="#238636" if passed else "#b42318", fontsize=14)
    fig.tight_layout()
    fig.savefig(args.output / "adc_follow.png", dpi=160)
    plt.close(fig)
    print(json.dumps(result, indent=2), flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
